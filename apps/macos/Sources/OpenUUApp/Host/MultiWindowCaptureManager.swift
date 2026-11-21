import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

struct WindowTopologyItem: Codable, Sendable, Equatable {
    let window_id: UInt32
    let parent_window_id: UInt32
    let kind: Int32
    let rel_x: Float
    let rel_y: Float
    let width: Float
    let height: Float
    let title: String
    let icon_png_b64: String?
}

/// Tracks ALL normal windows and floating popovers across one or more shared apps (e.g., WeChat + Safari + Finder),
/// plus optional Full Remote Desktop mode (`__openuu_full_desktop__`).
/// Automatically starts a ScreenCaptureEngine for each newly opened child window and stops it when closed.
@MainActor
final class MultiWindowCaptureManager {
    nonisolated static let fullDesktopBundleID = "__openuu_full_desktop__"
    nonisolated static let fullDesktopWindowID: UInt32 = 0x7FFF_FF00

    private struct SuppressedWindowState {
        let bundleID: String
        var seenBehindActiveWindow: Bool
        var lastFrame: CGRect
        var lastTitle: String
    }

    private var sharedBundleIDs: Set<String> = []
    private var primaryWindowByBundle: [String: UInt32] = [:]
    private var suppressedWindows: [UInt32: SuppressedWindowState] = [:]
    private var engines: [UInt32: ScreenCaptureEngine] = [:]
    private var isSharingFullDesktop = false
    private var fullDesktopSize = CGSize(width: 1920, height: 1080)
    private var pidIconCache: [pid_t: (b64: String, fetchedAt: CFAbsoluteTime, refreshCount: Int)] = [:]
    private var windowContentInsets: [UInt32: CGPoint] = [:]
    private var windowCroppedSizes: [UInt32: CGSize] = [:]
    private var lastAppWindows: [SCWindow] = []
    private var lastCGWindowSignature: [Int] = []
    private var pollTask: Task<Void, Never>?
    private var interactionSyncTask: Task<Void, Never>?
    private var lastTopology: [WindowTopologyItem] = []

    var onEncodedFrame: ((_ codec: UInt8, _ flags: UInt8, _ windowID: UInt32, _ ptsUS: UInt64, _ width: UInt16, _ height: UInt16, _ data: Data) -> Void)?
    var onTopologyChanged: (([WindowTopologyItem]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onWindowContentInset: ((UInt32, CGPoint) -> Void)?
    var virtualDisplayManager: VirtualDisplayManager?
    var useVirtualDisplayMode: Bool = false
    var isRelocationPaused: Bool = false
    var lastInteractedWindowID: UInt32 = 0
    var dynamicResolutionEnabled: Bool = true {
        didSet {
            for engine in engines.values {
                engine.setDynamicResolutionEnabled(dynamicResolutionEnabled)
            }
        }
    }
    var targetFPS: Int = 45 {
        didSet {
            for engine in engines.values {
                engine.setTargetFPS(targetFPS)
            }
        }
    }
    var networkTier: StreamNetworkTier = .lan {
        didSet {
            guard networkTier != oldValue else { return }
            for engine in engines.values {
                engine.setNetworkTier(networkTier)
            }
        }
    }

    /// Start (or add) sharing an app by its bundle ID (requested by Client or selected on Host).
    func addSharedApp(bundleID: String) async {
        guard !bundleID.isEmpty else { return }
        if bundleID == Self.fullDesktopBundleID {
            await startFullDesktopSharing()
            return
        }
        isRelocationPaused = false
        suppressedWindows = suppressedWindows.filter { $0.value.bundleID != bundleID }
        sharedBundleIDs.insert(bundleID)
        // Ensure the shared app is unhidden and foreground-active on the Host so macOS WindowServer / App Nap
        // never throttles its video playback compositor or backing-store frame updates while behind other windows.
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if app.isHidden {
                app.unhide()
            }
            app.activate()
            // If the app has no on-screen normal window (e.g. its main window was closed with ⌘W), send a
            // "reopen" via NSWorkspace so apps like WeChat bring their main window back.
            let pid = app.processIdentifier
            let hasWindow = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []).contains { info in
                (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                ((info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 1) == 0
            }
            if !hasWindow, let url = app.bundleURL {
                OpenUULogger.shared.warn("CAPTURE", "app has no on-screen window, sending reopen bundle_id=\(bundleID) pid=\(pid)")
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: cfg)
                try? await Task.sleep(for: .milliseconds(450))
            }
        } else {
            OpenUULogger.shared.warn("CAPTURE", "addSharedApp: app not running bundle_id=\(bundleID)")
        }
        await syncAppWindows(forcePublish: true)
        ensurePolling()
    }

    private func startFullDesktopSharing() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
                onStatus?("未找到可共享的主显示器")
                return
            }
            if let existing = engines.removeValue(forKey: Self.fullDesktopWindowID) {
                await existing.stopCapture()
            }
            let engine = ScreenCaptureEngine()
            engine.dynamicResolutionEnabled = dynamicResolutionEnabled
            engine.networkTier = networkTier
            engine.onEncodedFrame = { [weak self] codec, flags, winID, pts, w, h, data in
                self?.onEncodedFrame?(codec, flags, winID, pts, w, h, data)
            }
            fullDesktopSize = CGSize(width: CGFloat(display.width), height: CGFloat(display.height))
            isSharingFullDesktop = true
            engines[Self.fullDesktopWindowID] = engine
            publishTopology(from: lastAppWindows, force: true)
            try await engine.startDesktopCapture(display: display, windowID: Self.fullDesktopWindowID, fps: targetFPS)
            OpenUULogger.shared.info("CAPTURE", "started full_desktop display=\(display.displayID) res=\(display.width)x\(display.height) fps=\(targetFPS)")
            onStatus?("开始传输整台电脑桌面 (\(display.width)×\(display.height))")
        } catch {
            isSharingFullDesktop = false
            engines.removeValue(forKey: Self.fullDesktopWindowID)
            OpenUULogger.shared.error("CAPTURE", "startFullDesktopSharing failed error=\(error.localizedDescription)")
            onStatus?("启动整屏桌面传输失败: \(error.localizedDescription)")
        }
    }

    /// Start sharing a specific window (and its owning app's child windows).
    func startSharing(primaryWindow: SCWindow) async throws {
        isRelocationPaused = false
        if let bid = primaryWindow.owningApplication?.bundleIdentifier, !bid.isEmpty {
            sharedBundleIDs.insert(bid)
            primaryWindowByBundle[bid] = primaryWindow.windowID
        }
        await syncAppWindows(forcePublish: true)
        ensurePolling()
    }

    func syncNow() async {
        await syncAppWindows(forcePublish: true)
    }

    private func canonicalSharedBundleID(for rawBundleID: String?) -> String? {
        guard let bid = rawBundleID, !bid.isEmpty else { return nil }
        if sharedBundleIDs.contains(bid) { return bid }
        // Match helper / extension child processes (e.g. `com.tencent.xinWeChat.WeChatAppEx`)
        return sharedBundleIDs.first { shared in
            !shared.isEmpty && bid.hasPrefix(shared + ".")
        }
    }

    func stopWindow(windowID: UInt32) async {
        if windowID == Self.fullDesktopWindowID {
            isSharingFullDesktop = false
            if let engine = engines.removeValue(forKey: Self.fullDesktopWindowID) {
                await engine.stopCapture()
            }
            publishTopology(from: lastAppWindows, force: true)
            onStatus?("已停止整台电脑桌面传输")
            return
        }
        let stoppedWin = lastAppWindows.first(where: { $0.windowID == windowID })
        let stoppedBundle = canonicalSharedBundleID(for: stoppedWin?.owningApplication?.bundleIdentifier) ?? ""
        suppressedWindows[windowID] = SuppressedWindowState(
            bundleID: stoppedBundle,
            seenBehindActiveWindow: false,
            lastFrame: stoppedWin?.frame ?? .zero,
            lastTitle: stoppedWin?.title ?? ""
        )
        if let engine = engines.removeValue(forKey: windowID) {
            await engine.stopCapture()
        }
        windowContentInsets.removeValue(forKey: windowID)
        windowCroppedSizes.removeValue(forKey: windowID)

        // Identify the owning bundle of `windowID`. Only remove the bundle from `sharedBundleIDs` if `windowID`
        // is its primary window OR if no other normal (`windowLayer == 0`) windows remain for that bundle.
        var stoppedBundles: Set<String> = []
        for (bid, primaryID) in primaryWindowByBundle where primaryID == windowID {
            stoppedBundles.insert(bid)
        }
        if let win = stoppedWin, win.windowLayer == 0, !stoppedBundle.isEmpty {
            let hasOtherNormalWindow = lastAppWindows.contains {
                $0.windowID != windowID &&
                $0.windowLayer == 0 &&
                canonicalSharedBundleID(for: $0.owningApplication?.bundleIdentifier) == stoppedBundle
            }
            if !hasOtherNormalWindow {
                stoppedBundles.insert(stoppedBundle)
            }
        }
        for bid in stoppedBundles {
            primaryWindowByBundle.removeValue(forKey: bid)
            sharedBundleIDs.remove(bid)
            suppressedWindows = suppressedWindows.filter { $0.value.bundleID != bid }
            for win in lastAppWindows where canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) == bid {
                if let eng = engines.removeValue(forKey: win.windowID) {
                    await eng.stopCapture()
                }
                windowContentInsets.removeValue(forKey: win.windowID)
                windowCroppedSizes.removeValue(forKey: win.windowID)
            }
        }

        // If the user stopped streaming a secondary window (e.g. WeChat image viewer via 「关投屏」) while the app
        // still has an active window, raise that remaining window in front of the suppressed window without activating
        // the app. That way, if the user later clicks an image again and the app re-presents the same reused window
        // to the front, we can detect the Z-order jump and immediately resume streaming it.
        if !stoppedBundle.isEmpty && !stoppedBundles.contains(stoppedBundle) {
            let siblingCandidates = lastAppWindows.filter {
                $0.windowID != windowID &&
                $0.windowLayer == 0 &&
                suppressedWindows[$0.windowID] == nil &&
                canonicalSharedBundleID(for: $0.owningApplication?.bundleIdentifier) == stoppedBundle
            }
            let fallbackWin =
                siblingCandidates.first(where: { $0.windowID == lastInteractedWindowID }) ??
                siblingCandidates.first(where: { $0.windowID == primaryWindowByBundle[stoppedBundle] }) ??
                siblingCandidates.first
            if let fallbackWin, let pid = fallbackWin.owningApplication?.processID,
               let axWin = AXWindowLookup.find(pid: pid, windowID: fallbackWin.windowID, frame: fallbackWin.frame) {
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        if sharedBundleIDs.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            lastAppWindows.removeAll()
            // Keep the Full Remote Desktop entry alive if it is still being shared.
            publishTopology(from: [], force: false)
            virtualDisplayManager?.returnAllWindowsToMainDisplay()
        } else {
            await syncAppWindows(forcePublish: true)
        }
    }

    func requestAllKeyframes() {
        for engine in engines.values {
            engine.requestKeyframe()
        }
        if !lastTopology.isEmpty {
            onTopologyChanged?(lastTopology)
        }
    }

    func notifyWindowResized(windowID: UInt32) {
        engines[windowID]?.checkWindowSizeNow()
    }

    func notifyNormalWindowInteracted(windowID: UInt32) {
        lastInteractedWindowID = windowID
        guard !suppressedWindows.isEmpty || lastAppWindows.contains(where: { $0.windowLayer > 0 }) else { return }
        interactionSyncTask?.cancel()
        interactionSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let self else { return }
            await self.syncAppWindows(forcePublish: false)
        }
    }

    func stopAll() async {
        pollTask?.cancel()
        pollTask = nil
        interactionSyncTask?.cancel()
        interactionSyncTask = nil
        for engine in engines.values {
            await engine.stopCapture()
        }
        engines.removeAll()
        windowContentInsets.removeAll()
        windowCroppedSizes.removeAll()
        lastAppWindows.removeAll()
        sharedBundleIDs.removeAll()
        primaryWindowByBundle.removeAll()
        suppressedWindows.removeAll()
        isSharingFullDesktop = false
        pidIconCache.removeAll()
        lastTopology = []
    }

    private func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard !Task.isCancelled, let self else { break }
                await self.syncAppWindows(forcePublish: false)
            }
        }
    }

    private func startEngine(for window: SCWindow) async throws {
        let engine = ScreenCaptureEngine()
        engine.dynamicResolutionEnabled = dynamicResolutionEnabled
        engine.networkTier = networkTier
        let frameHandler = self.onEncodedFrame
        engine.onEncodedFrame = { codec, flags, winID, pts, w, h, data in
            frameHandler?(codec, flags, winID, pts, w, h, data)
        }
        engine.onContentInsetDetected = { [weak self] winID, inset, croppedSize in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.windowContentInsets[winID] = inset
                self.windowCroppedSizes[winID] = croppedSize
                self.onWindowContentInset?(winID, inset)
                if !self.lastAppWindows.isEmpty {
                    self.publishTopology(from: self.lastAppWindows, force: true)
                }
            }
        }
        try await engine.startCapture(window: window, fps: targetFPS)
        engines[window.windowID] = engine
    }

    /// Filters out tiny transient system overlays owned by the app process, such as macOS 14+
    /// input-source / Caps Lock indicator pills (~84x77) that appear next to text fields.
    private static func isCapturablePopoverFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 44, frame.height >= 28 else { return false }
        return frame.width >= 110 || frame.height >= 95
    }

    private func currentOnScreenWindowSnapshot() -> (signature: [Int], visibleIDs: Set<UInt32>) {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return ([], [])
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var sig: [Int] = []
        var visibleIDs: Set<UInt32> = []
        sig.reserveCapacity(list.count * 6)
        visibleIDs.reserveCapacity(list.count)
        for info in list {
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if pid == myPID { continue }
            // Skip invisible windows kept on-screen with alpha == 0 (e.g. WeChat hidden floating panels/toasts
            // that otherwise encode as solid black rectangles because H.264 has no alpha channel).
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
                continue
            }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer >= 0 && layer <= 500 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }
            if layer == 0 {
                guard rect.width >= 140, rect.height >= 120 else { continue }
            } else {
                guard Self.isCapturablePopoverFrame(rect) else { continue }
            }
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard wid != 0 else { continue }
            visibleIDs.insert(wid)
            sig.append(Int(wid))
            sig.append(layer)
            sig.append(Int(rect.origin.x))
            sig.append(Int(rect.origin.y))
            sig.append(Int(rect.size.width))
            sig.append(Int(rect.size.height))
        }
        return (sig, visibleIDs)
    }

    private func syncAppWindows(forcePublish: Bool) async {
        guard !sharedBundleIDs.isEmpty else {
            publishTopology(from: [], force: false)
            return
        }

        // Fast-path check: avoid heavy XPC calls to `replayd` (`SCShareableContent.excludingDesktopWindows`)
        // during steady-state 60fps video playback when no window has opened, closed, moved, or resized!
        let cgSnap = currentOnScreenWindowSnapshot()
        if !forcePublish && !lastAppWindows.isEmpty && !cgSnap.signature.isEmpty && cgSnap.signature == lastCGWindowSignature {
            return
        }

        guard var content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return
        }
        var postSnap = currentOnScreenWindowSnapshot()
        lastCGWindowSignature = postSnap.signature

        // In Virtual Display mode (Scheme C), ensure the virtual display is online with a valid mode and relocate
        // any normal window (both newly discovered and already tracked) that is not yet on the virtual display.
        if useVirtualDisplayMode,
           !isRelocationPaused,
           let vdm = virtualDisplayManager,
           await vdm.ensureVirtualDisplayReady() {
            var movedAny = false
            for win in content.windows where win.windowLayer == 0 && win.frame.width >= 140 && win.frame.height >= 120 {
                guard canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) != nil,
                      let pid = win.owningApplication?.processID else { continue }
                if !vdm.isWindowOnVirtualDisplay(win.frame) {
                    if vdm.moveWindowToVirtualDisplay(pid: pid, windowID: win.windowID, currentFrame: win.frame) {
                        movedAny = true
                    }
                }
            }
            if movedAny {
                try? await Task.sleep(for: .milliseconds(150))
                if let refreshed = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) {
                    content = refreshed
                    postSnap = currentOnScreenWindowSnapshot()
                    lastCGWindowSignature = postSnap.signature
                }
            }
        }
        let visibleOnScreenIDs = postSnap.visibleIDs

        // Include all normal windows (layer == 0) PLUS all floating popovers / emoji pickers / animated sticker
        // hover previews / context menus (layer 1..500, >= 60x60).
        // Always capturing floating popovers as child windows ensures that:
        // 1) An emoji picker (W_emoji) is never clipped and always interactive;
        // 2) A secondary hover preview (W_preview, e.g. WeChat's animated sticker hover preview) that opens on top
        //    of W_emoji inside the main window's bounds is NEVER hidden behind W_emoji's floating proxy window.
        let existingIDsOnHost = Set(content.windows.map(\.windowID))
        suppressedWindows = suppressedWindows.filter { existingIDsOnHost.contains($0.key) }

        if !suppressedWindows.isEmpty {
            let zOrderRank = currentNormalWindowZOrder()
            var minActiveRankByBundle: [String: Int] = [:]
            for win in content.windows where win.windowLayer == 0 && win.frame.width >= 140 && win.frame.height >= 120 {
                guard suppressedWindows[win.windowID] == nil,
                      let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier),
                      let rank = zOrderRank[win.windowID] else { continue }
                if let cur = minActiveRankByBundle[bid] {
                    if rank < cur { minActiveRankByBundle[bid] = rank }
                } else {
                    minActiveRankByBundle[bid] = rank
                }
            }

            var unsuppressedIDs: [UInt32] = []
            for win in content.windows {
                guard var state = suppressedWindows[win.windowID] else { continue }
                let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) ?? state.bundleID
                let curTitle = win.title ?? ""
                let frameChanged = !state.lastFrame.isEmpty && (
                    abs(win.frame.width - state.lastFrame.width) > 2 ||
                    abs(win.frame.height - state.lastFrame.height) > 2
                )
                let titleChanged = !curTitle.isEmpty && curTitle != state.lastTitle

                if win.windowLayer == 0,
                   let myRank = zOrderRank[win.windowID],
                   let activeRank = minActiveRankByBundle[bid] {
                    if myRank > activeRank {
                        state.seenBehindActiveWindow = true
                        state.lastFrame = win.frame
                        state.lastTitle = curTitle
                        suppressedWindows[win.windowID] = state
                    } else if state.seenBehindActiveWindow || frameChanged || titleChanged {
                        unsuppressedIDs.append(win.windowID)
                    }
                } else if frameChanged || titleChanged {
                    unsuppressedIDs.append(win.windowID)
                }
            }
            for id in unsuppressedIDs {
                suppressedWindows.removeValue(forKey: id)
                OpenUULogger.shared.info("CAPTURE", "unsuppressed re-presented win=\(id)")
            }
        }

        let appWindows = content.windows.filter { win in
            guard suppressedWindows[win.windowID] == nil else { return false }
            guard visibleOnScreenIDs.isEmpty || visibleOnScreenIDs.contains(win.windowID) else { return false }
            guard canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) != nil else { return false }
            if win.windowLayer == 0 {
                return win.frame.width >= 140 && win.frame.height >= 120
            }
            if win.windowLayer > 0 && win.windowLayer <= 500 {
                return Self.isCapturablePopoverFrame(win.frame)
            }
            return false
        }

        for win in appWindows where win.windowLayer == 0 {
            let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) ?? (win.owningApplication?.bundleIdentifier ?? "")
            if primaryWindowByBundle[bid] == nil {
                primaryWindowByBundle[bid] = win.windowID
            }
        }

        let currentIDs = Set(appWindows.map(\.windowID))
        let trackedIDs = Set(engines.keys).subtracting([Self.fullDesktopWindowID])

        // 1. Stop engines for closed windows
        for id in trackedIDs.subtracting(currentIDs) {
            if let engine = engines.removeValue(forKey: id) {
                await engine.stopCapture()
            }
            windowContentInsets.removeValue(forKey: id)
            windowCroppedSizes.removeValue(forKey: id)
        }

        let prevSizesByID: [UInt32: CGSize] = Dictionary(uniqueKeysWithValues: lastAppWindows.map { ($0.windowID, $0.frame.size) })
        for win in appWindows where win.windowLayer > 0 && trackedIDs.contains(win.windowID) {
            if let prevSize = prevSizesByID[win.windowID],
               (abs(win.frame.width - prevSize.width) > 2 || abs(win.frame.height - prevSize.height) > 2) {
                windowCroppedSizes.removeValue(forKey: win.windowID)
                windowContentInsets.removeValue(forKey: win.windowID)
            }
        }

        lastAppWindows = appWindows
        // Publish topology BEFORE starting new engines so the Client knows each window's `kind` (floating popover vs
        // normal window) and relative offset `(rel_x, rel_y)` before its first video frame arrives.
        publishTopology(from: appWindows, force: forcePublish)

        // 2. Start engines for newly opened windows across all shared apps, and sync size for existing windows
        //    (including floating popovers such as WeChat's search dropdown, which expands dynamically while typing).
        var startedAny = false
        for win in appWindows {
            if trackedIDs.contains(win.windowID) {
                engines[win.windowID]?.updateWindowLogicalSize(win.frame.size)
                continue
            }
            let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) ?? (win.owningApplication?.bundleIdentifier ?? "")
            if primaryWindowByBundle[bid] == nil {
                primaryWindowByBundle[bid] = win.windowID
            }
            do {
                try await startEngine(for: win)
                startedAny = true
                let appName = win.owningApplication?.applicationName ?? "App"
                OpenUULogger.shared.info("CAPTURE", "started win=\(win.windowID) app=\(appName) layer=\(win.windowLayer) frame=\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) \(Int(win.frame.width))x\(Int(win.frame.height))")
                onStatus?("开始传输窗口: \(appName) - \(win.title ?? appName)")
            } catch {
                OpenUULogger.shared.warn("CAPTURE", "startEngine failed win=\(win.windowID) error=\(error.localizedDescription)")
            }
        }

        // Re-request keyframes when newly added so Client renders immediately
        if forcePublish {
            for engine in engines.values {
                engine.requestKeyframe()
            }
        }

        if startedAny || forcePublish {
            publishTopology(from: appWindows, force: forcePublish)
        }
    }

    private func publishTopology(from windows: [SCWindow], force: Bool) {
        let frameByID: [UInt32: CGRect] = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.frame) })
        let pidByID: [UInt32: pid_t] = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.owningApplication?.processID ?? 0) })
        let normalWindowsByBundle = Dictionary(grouping: windows.filter { $0.windowLayer == 0 }) { win in
            canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) ?? (win.owningApplication?.bundleIdentifier ?? "")
        }
        let hasPopover = windows.contains { $0.windowLayer > 0 }
        let zOrderRank = hasPopover ? currentNormalWindowZOrder() : [:]

        var items: [WindowTopologyItem] = windows.map { win in
            let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) ?? (win.owningApplication?.bundleIdentifier ?? "")
            let appName = win.owningApplication?.applicationName ?? "App"
            let primaryID = primaryWindowByBundle[bid] ?? win.windowID
            let isMain = win.windowID == primaryID
            let isPopover = win.windowLayer > 0
            let anchorID: UInt32
            if isMain {
                anchorID = 0
            } else if isPopover {
                anchorID = resolvePopoverAnchorID(
                    popover: win,
                    candidates: normalWindowsByBundle[bid] ?? [],
                    fallbackPrimaryID: primaryID,
                    zOrderRank: zOrderRank
                )
            } else {
                anchorID = primaryID
            }
            let anchorFrame = frameByID[anchorID] ?? frameByID[primaryID] ?? win.frame
            let inset = windowContentInsets[win.windowID] ?? .zero
            let size = windowCroppedSizes[win.windowID] ?? win.frame.size
            let relX = isMain ? Float(0) : Float((win.frame.origin.x + inset.x) - anchorFrame.origin.x)
            let relY = isMain ? Float(0) : Float((win.frame.origin.y + inset.y) - anchorFrame.origin.y)
            let rawTitle = (win.title ?? "").isEmpty ? appName : "\(appName) - \(win.title ?? "")"
            // Extract dedicated per-process icon for secondary normal windows owned by a different PID
            // (e.g. WeChat Mini Programs `WeChatAppEx` / separate webview helpers that set their own Dock icon!).
            var windowIconB64: String? = nil
            if !isMain && !isPopover {
                let winPID = win.owningApplication?.processID ?? 0
                let primaryPID = pidByID[primaryID] ?? 0
                if winPID != 0 && winPID != primaryPID {
                    windowIconB64 = resolveIconBase64(for: winPID)
                }
            }
            return WindowTopologyItem(
                window_id: win.windowID,
                parent_window_id: anchorID,
                kind: isMain ? 0 : (isPopover ? 2 : 1),
                rel_x: relX,
                rel_y: relY,
                width: Float(size.width),
                height: Float(size.height),
                title: rawTitle,
                icon_png_b64: windowIconB64
            )
        }

        if isSharingFullDesktop {
            let hostName = Host.current().localizedName ?? "Mac"
            items.append(
                WindowTopologyItem(
                    window_id: Self.fullDesktopWindowID,
                    parent_window_id: 0,
                    kind: 0,
                    rel_x: 0,
                    rel_y: 0,
                    width: Float(fullDesktopSize.width),
                    height: Float(fullDesktopSize.height),
                    title: "远程桌面 - \(hostName)",
                    icon_png_b64: nil
                )
            )
        }

        items.sort { $0.window_id < $1.window_id }

        if force || items != lastTopology {
            lastTopology = items
            onTopologyChanged?(items)
        }
    }

    private func resolveIconBase64(for pid: pid_t) -> String? {
        let now = CFAbsoluteTimeGetCurrent()
        // Re-sample once after 2.0s because Mini Programs often load their real logo asynchronously after launch.
        if let cached = pidIconCache[pid], (cached.refreshCount >= 1 || now - cached.fetchedAt < 2.0) {
            return cached.b64.isEmpty ? nil : cached.b64
        }
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return nil }
        let b64 = IconCompositor.encodeIconToBase64PNG(icon, size: 128)
        let prevCount = pidIconCache[pid]?.refreshCount ?? -1
        pidIconCache[pid] = (b64: b64, fetchedAt: now, refreshCount: prevCount + 1)
        return b64.isEmpty ? nil : b64
    }

    private func currentNormalWindowZOrder() -> [UInt32: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var rank: [UInt32: Int] = [:]
        for (idx, info) in list.enumerated() {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0,
                  let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value else {
                continue
            }
            rank[wid] = idx
        }
        return rank
    }

    private func resolvePopoverAnchorID(
        popover: SCWindow,
        candidates: [SCWindow],
        fallbackPrimaryID: UInt32,
        zOrderRank: [UInt32: Int]
    ) -> UInt32 {
        guard !candidates.isEmpty else { return fallbackPrimaryID }
        let popOrigin = popover.frame.origin
        let popCenter = CGPoint(x: popover.frame.midX, y: popover.frame.midY)

        // 1. Prefer the exact normal window the user most recently clicked/right-clicked,
        //    as long as the popover spawned within or near its bounds.
        if lastInteractedWindowID != 0,
           let interacted = candidates.first(where: { $0.windowID == lastInteractedWindowID }) {
            let expanded = interacted.frame.insetBy(dx: -140, dy: -140)
            if expanded.contains(popOrigin) || expanded.contains(popCenter) {
                return interacted.windowID
            }
        }

        // 2. Otherwise pick the frontmost (lowest zOrderRank) normal window containing the popover.
        let sortedByZ = candidates.sorted { (zOrderRank[$0.windowID] ?? Int.max) < (zOrderRank[$1.windowID] ?? Int.max) }
        if let containing = sortedByZ.first(where: {
            let expanded = $0.frame.insetBy(dx: -80, dy: -80)
            return expanded.contains(popOrigin) || expanded.contains(popCenter)
        }) {
            return containing.windowID
        }

        // 3. Fallback to lastInteractedWindowID if still open, else primary window.
        if lastInteractedWindowID != 0, candidates.contains(where: { $0.windowID == lastInteractedWindowID }) {
            return lastInteractedWindowID
        }
        return fallbackPrimaryID
    }
}

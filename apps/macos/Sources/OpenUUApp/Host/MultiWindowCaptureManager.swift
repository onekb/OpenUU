import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
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
        let suppressedAtInteractionSeq: UInt64
    }

    private struct WindowIconState {
        var iconB64: String?
        var dockTitle: String?
        var lastTitle: String
        var attempts: Int
        var nextRetryAt: CFAbsoluteTime
    }

    private var sharedBundleIDs: Set<String> = []
    private var primaryWindowByBundle: [String: UInt32] = [:]
    private var suppressedWindows: [UInt32: SuppressedWindowState] = [:]
    private var engines: [UInt32: ScreenCaptureEngine] = [:]
    private var isSharingFullDesktop = false
    private var fullDesktopSize = CGSize(width: 1920, height: 1080)
    private var windowIconStates: [UInt32: WindowIconState] = [:]
    private var windowContentInsets: [UInt32: CGPoint] = [:]
    private var windowCroppedSizes: [UInt32: CGSize] = [:]
    private var lastAppWindows: [SCWindow] = []
    private var lastCGWindowSignature: [Int] = []
    private var knownOpenAXWindowIDs: Set<UInt32> = []
    private var knownStandardAXWindowIDs: Set<UInt32> = []
    private var interactionSeq: UInt64 = 0
    private var pollTask: Task<Void, Never>?
    private var interactionSyncTask: Task<Void, Never>?
    private var lastTopology: [WindowTopologyItem] = []

    var onEncodedFrame: ((_ codec: UInt8, _ flags: UInt8, _ windowID: UInt32, _ ptsUS: UInt64, _ width: UInt16, _ height: UInt16, _ data: Data) -> Void)?
    var onEncodedAudio: ((_ codec: UInt8, _ flags: UInt8, _ channels: UInt8, _ sampleRate: UInt32, _ ptsUS: UInt64, _ data: Data) -> Void)?
    var onTopologyChanged: (([WindowTopologyItem]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onWindowContentInset: ((UInt32, CGPoint) -> Void)?
    let audioStreamer = HostAudioStreamer()
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
            audioStreamer.setNetworkTier(networkTier)
        }
    }

    init() {
        audioStreamer.onEncodedAudio = { [weak self] codec, flags, channels, sampleRate, ptsUS, data in
            self?.onEncodedAudio?(codec, flags, channels, sampleRate, ptsUS, data)
        }
    }

    func setAudioPreferences(enabled: Bool, muteHost: Bool) {
        audioStreamer.updatePreferences(enabled: enabled, muteHost: muteHost)
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
            AXWindowLookup.activateProcess(app.processIdentifier)
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
        if bid.localizedCaseInsensitiveContains(".inputmethod.") { return nil }
        if sharedBundleIDs.contains(bid) { return bid }
        if sharedBundleIDs.contains(WindowCatalog.weChatBundleID) {
            let lower = bid.lowercased()
            if lower.contains("wechatappex") ||
               lower.contains("weixinappex") ||
               lower.contains("wechatplayer") ||
               lower.contains("radiumwmpf") ||
               lower.hasPrefix("com.tencent.weixin") {
                return WindowCatalog.weChatBundleID
            }
        }
        // Match helper / extension child processes (e.g. `com.tencent.xinWeChat.WeChatAppEx`)
        return sharedBundleIDs.first { shared in
            !shared.isEmpty && bid.hasPrefix(shared + ".")
        }
    }

    /// Returns `true` if `win` is a genuine primary/secondary application window rather than a transient menu/emoji popover.
    /// Includes pinned Always-on-Top windows at `0 < windowLayer <= 25` (e.g. WeChat 4.0's pinned Image Viewer or Browser
    /// running at `kCGFloatingWindowLevel == 3` or `kCGModalPanelWindowLevel == 8`) when verified as an AX standard/dialog window.
    private func isNormalAppWindow(_ win: SCWindow, standardAXIDs: Set<UInt32>? = nil) -> Bool {
        guard win.frame.width >= 140, win.frame.height >= 120 else { return false }
        if win.windowLayer == 0 { return true }
        if win.windowLayer > 0 && win.windowLayer <= 25 {
            let axSet = standardAXIDs ?? knownStandardAXWindowIDs
            return axSet.contains(win.windowID)
        }
        return false
    }

    private func resolvedSharedBundleID(for win: SCWindow, pidToSharedBundle: [pid_t: String] = [:]) -> String? {
        if let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) {
            return bid
        }
        if let pid = win.owningApplication?.processID {
            return pidToSharedBundle[pid]
        }
        return nil
    }

    private func isMainBundleProcessWindow(_ win: SCWindow, canonicalBundleID: String) -> Bool {
        let rawBid = win.owningApplication?.bundleIdentifier ?? ""
        guard !rawBid.isEmpty, !rawBid.localizedCaseInsensitiveContains("AppEx") else {
            return false
        }
        return rawBid == canonicalBundleID
    }

    private func pickPreferredPrimaryWindow(candidates: [SCWindow], canonicalBundleID: String) -> SCWindow? {
        guard !candidates.isEmpty else { return nil }
        let appName = NSRunningApplication.runningApplications(withBundleIdentifier: canonicalBundleID).first?.localizedName ?? ""
        return candidates.max { a, b in
            let aMainProc = isMainBundleProcessWindow(a, canonicalBundleID: canonicalBundleID)
            let bMainProc = isMainBundleProcessWindow(b, canonicalBundleID: canonicalBundleID)
            if aMainProc != bMainProc { return !aMainProc && bMainProc }

            if !appName.isEmpty {
                let aTitle = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let bTitle = (b.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let aExact = aTitle == appName
                let bExact = bTitle == appName
                if aExact != bExact { return !aExact && bExact }
                let aPrefix = aTitle.hasPrefix(appName)
                let bPrefix = bTitle.hasPrefix(appName)
                if aPrefix != bPrefix { return !aPrefix && bPrefix }
            }

            let aArea = a.frame.width * a.frame.height
            let bArea = b.frame.width * b.frame.height
            return aArea < bArea
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
        let pidMapSnapshot = resolveSharedPIDToBundleMap()
        let stoppedWin = lastAppWindows.first(where: { $0.windowID == windowID })
        let stoppedBundle = stoppedWin.flatMap { resolvedSharedBundleID(for: $0, pidToSharedBundle: pidMapSnapshot) } ?? ""
        suppressedWindows[windowID] = SuppressedWindowState(
            bundleID: stoppedBundle,
            seenBehindActiveWindow: false,
            lastFrame: stoppedWin?.frame ?? .zero,
            lastTitle: stoppedWin?.title ?? "",
            suppressedAtInteractionSeq: interactionSeq
        )
        if let engine = engines.removeValue(forKey: windowID) {
            await engine.stopCapture()
        }
        windowContentInsets.removeValue(forKey: windowID)
        windowCroppedSizes.removeValue(forKey: windowID)
        windowIconStates.removeValue(forKey: windowID)

        // Identify the owning bundle of `windowID`. Only remove the bundle from `sharedBundleIDs` if `windowID`
        // is its primary window OR if no other normal windows remain for that bundle.
        var stoppedBundles: Set<String> = []
        for (bid, primaryID) in primaryWindowByBundle where primaryID == windowID {
            stoppedBundles.insert(bid)
        }
        if let win = stoppedWin, isNormalAppWindow(win), !stoppedBundle.isEmpty {
            let hasOtherNormalWindow = lastAppWindows.contains {
                $0.windowID != windowID &&
                isNormalAppWindow($0) &&
                resolvedSharedBundleID(for: $0, pidToSharedBundle: pidMapSnapshot) == stoppedBundle
            }
            if !hasOtherNormalWindow {
                stoppedBundles.insert(stoppedBundle)
            }
        }
        for bid in stoppedBundles {
            primaryWindowByBundle.removeValue(forKey: bid)
            sharedBundleIDs.remove(bid)
            suppressedWindows = suppressedWindows.filter { $0.value.bundleID != bid }
            for win in lastAppWindows where resolvedSharedBundleID(for: win, pidToSharedBundle: pidMapSnapshot) == bid {
                if let eng = engines.removeValue(forKey: win.windowID) {
                    await eng.stopCapture()
                }
                windowContentInsets.removeValue(forKey: win.windowID)
                windowCroppedSizes.removeValue(forKey: win.windowID)
                windowIconStates.removeValue(forKey: win.windowID)
            }
        }

        // If the user stopped streaming a secondary window (e.g. WeChat image viewer or WeChatAppEx browser via 「关投屏」)
        // while the app still has an active window, raise that remaining window in front of the suppressed window.
        // Ensure the fallback window's process is frontmost when needed so WindowServer actually updates global Z-order.
        if !stoppedBundle.isEmpty && !stoppedBundles.contains(stoppedBundle) {
            let siblingCandidates = lastAppWindows.filter {
                $0.windowID != windowID &&
                isNormalAppWindow($0) &&
                suppressedWindows[$0.windowID] == nil &&
                resolvedSharedBundleID(for: $0, pidToSharedBundle: pidMapSnapshot) == stoppedBundle
            }
            let fallbackWin =
                siblingCandidates.first(where: { $0.windowID == lastInteractedWindowID }) ??
                siblingCandidates.first(where: { $0.windowID == primaryWindowByBundle[stoppedBundle] }) ??
                siblingCandidates.first
            if let fallbackWin, let pid = fallbackWin.owningApplication?.processID,
               let axWin = AXWindowLookup.find(pid: pid, windowID: fallbackWin.windowID, frame: fallbackWin.frame) {
                let stoppedPID = stoppedWin?.owningApplication?.processID ?? pid
                let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                if stoppedPID != pid || frontPID == stoppedPID {
                    AXWindowLookup.activateProcess(pid)
                }
                AXWindowLookup.raise(axWin)
                try? await Task.sleep(for: .milliseconds(40))
            }
        }

        if sharedBundleIDs.isEmpty {
            pollTask?.cancel()
            pollTask = nil
            lastAppWindows.removeAll()
            knownOpenAXWindowIDs.removeAll()
            knownStandardAXWindowIDs.removeAll()
            // Keep the Full Remote Desktop entry alive if it is still being shared.
            publishTopology(from: [], force: false)
            virtualDisplayManager?.destroyVirtualDisplay()
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

    func requestKeyframe(windowID: UInt32) {
        if windowID != 0, let engine = engines[windowID] {
            engine.requestKeyframe()
        } else {
            requestAllKeyframes()
        }
    }

    func notifyWindowResized(windowID: UInt32) {
        engines[windowID]?.checkWindowSizeNow()
    }

    func notifyNormalWindowInteracted(windowID: UInt32) {
        if windowID != 0 {
            lastInteractedWindowID = windowID
            interactionSeq &+= 1
        }
        interactionSyncTask?.cancel()
        interactionSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(45))
            guard !Task.isCancelled, let self else { return }
            await self.syncAppWindows(forcePublish: false)
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await self.syncAppWindows(forcePublish: false)
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            await self.syncAppWindows(forcePublish: false)
        }
    }

    func stopAll() async {
        pollTask?.cancel()
        pollTask = nil
        interactionSyncTask?.cancel()
        interactionSyncTask = nil
        audioStreamer.stop()
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
        knownOpenAXWindowIDs.removeAll()
        knownStandardAXWindowIDs.removeAll()
        isSharingFullDesktop = false
        windowIconStates.removeAll()
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

    private func startEngine(for window: SCWindow, isNormalWindow: Bool) async throws {
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
        try await engine.startCapture(
            window: window,
            fps: targetFPS,
            treatAsFloatingPopover: !isNormalWindow
        )
        engines[window.windowID] = engine
    }

    /// Maximum `windowLayer` captured as an interactive popover/menu (`NSMenu` is `101`); excludes macOS
    /// `kCGDraggingWindowLevel` (`500`) drag-preview overlays that would otherwise render as opaque white boxes.
    private static let maxCapturablePopoverLayer: Int = min(400, Int(CGWindowLevelForKey(.draggingWindow)))

    /// Filters out tiny transient system overlays while always capturing compact context menus (including single-item Copy/Paste ~52x26pt).
    private static func isCapturablePopoverFrame(_ frame: CGRect) -> Bool {
        frame.width >= 42 && frame.height >= 22 && (frame.width >= 50 || frame.height >= 36)
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
            guard layer >= 0 && layer < Self.maxCapturablePopoverLayer else { continue }
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
            let winName = (info[kCGWindowName as String] as? String) ?? ""
            visibleIDs.insert(wid)
            sig.append(Int(wid))
            sig.append(layer)
            sig.append(Int(rect.origin.x))
            sig.append(Int(rect.origin.y))
            sig.append(Int(rect.size.width))
            sig.append(Int(rect.size.height))
            sig.append(winName.hashValue)
        }
        return (sig, visibleIDs)
    }

    private struct OpenAXWindowItem {
        let windowID: UInt32
        let pid: pid_t
        let bundleID: String
        let element: AXUIElement
        let frame: CGRect
        let isStandardWindow: Bool
    }

    private static func executablePath(for pid: pid_t) -> String? {
        guard pid > 1 else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard len > 0 else { return nil }
        return String(decoding: buf.prefix(Int(len)), as: UTF8.self)
    }

    /// Maps all running processes (including up to 8 levels of descendant child helper processes via `sysctl KERN_PROC_ALL`
    /// AND `launchd`-spawned `ppid == 1` helpers residing inside a shared `.app` bundle via `proc_pidpath`) back to their
    /// canonical shared bundle ID so helper windows (such as WeChat's `WeChatAppEx`, `WeixinAppEx`, `RadiumWMPF`,
    /// `WeChatPlayer`, Channels 视频号, Mini Programs, and WebView helpers) are never missed.
    private func resolveSharedPIDToBundleMap() -> [pid_t: String] {
        guard !sharedBundleIDs.isEmpty else { return [:] }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var rootMap: [pid_t: String] = [:]
        var sharedBundlePaths: [(prefix: String, bundleID: String)] = []
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 1, pid != myPID,
                  let bid = canonicalSharedBundleID(for: app.bundleIdentifier) else {
                continue
            }
            rootMap[pid] = bid
            if app.bundleIdentifier == bid, let path = app.bundleURL?.standardizedFileURL.path, path.hasSuffix(".app") {
                let prefix = path + "/"
                if !sharedBundlePaths.contains(where: { $0.prefix == prefix }) {
                    sharedBundlePaths.append((prefix, bid))
                }
            }
        }
        guard !rootMap.isEmpty else { return [:] }

        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return rootMap }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (size / stride) + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualSize = capacity * stride
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else { return rootMap }
        let count = actualSize / stride
        var ppidMap: [pid_t: pid_t] = [:]
        ppidMap.reserveCapacity(count)
        for i in 0..<count {
            let p = procs[i].kp_proc.p_pid
            let pp = procs[i].kp_eproc.e_ppid
            if p > 0 {
                ppidMap[p] = pp
            }
        }

        var fullMap = rootMap
        let sharesWeChat = sharedBundleIDs.contains(WindowCatalog.weChatBundleID)
        for candidatePID in ppidMap.keys where candidatePID > 1 && candidatePID != myPID && fullMap[candidatePID] == nil {
            var cur = candidatePID
            var matched = false
            for _ in 0..<8 {
                if let matchedBid = fullMap[cur] {
                    fullMap[candidatePID] = matchedBid
                    matched = true
                    break
                }
                guard let parent = ppidMap[cur], parent > 1, parent != cur else { break }
                cur = parent
            }
            if !matched, (!sharedBundlePaths.isEmpty || sharesWeChat),
               let execPath = Self.executablePath(for: candidatePID) {
                if let hit = sharedBundlePaths.first(where: { execPath.hasPrefix($0.prefix) }) {
                    fullMap[candidatePID] = hit.bundleID
                } else if sharesWeChat {
                    let lower = execPath.lowercased()
                    if lower.contains("/wechat.app/") ||
                       lower.contains("wechatappex") ||
                       lower.contains("weixinappex") ||
                       lower.contains("radiumwmpf") ||
                       lower.contains("wechatplayer") {
                        fullMap[candidatePID] = WindowCatalog.weChatBundleID
                    }
                }
            }
        }
        return fullMap
    }

    /// Queries Accessibility windows (`kAXWindows` + `kAXMainWindow` + `kAXFocusedWindow`) across all shared PIDs
    /// (and their child helpers) so we can detect genuinely open, non-minimized windows EVEN when they spawn off-screen
    /// (e.g. at stale Virtual Display coordinates), run as floating `NSPanel`s (`windowLayer == 3`), or open on an
    /// inactive macOS Space (e.g. Desktop 1 while WeChat's main window is in Full Screen).
    private func snapshotOpenSharedAXWindows(pidToSharedBundle: [pid_t: String]) -> (items: [OpenAXWindowItem], openIDs: Set<UInt32>, standardIDs: Set<UInt32>, signature: [Int]) {
        guard AXIsProcessTrusted(), !pidToSharedBundle.isEmpty else {
            return ([], [], [], [])
        }
        var items: [OpenAXWindowItem] = []
        var openIDs: Set<UInt32> = []
        var standardIDs: Set<UInt32> = []
        var sig: [Int] = []
        for pid in pidToSharedBundle.keys.sorted() {
            guard let bid = pidToSharedBundle[pid] else { continue }
            if NSRunningApplication(processIdentifier: pid)?.isHidden == true {
                continue
            }
            for axWin in AXWindowLookup.allWindows(pid: pid) {
                if AXWindowLookup.isMinimized(axWin) {
                    continue
                }
                guard let wid = AXWindowLookup.windowID(of: axWin), wid != 0,
                      let frame = AXWindowLookup.frame(of: axWin),
                      frame.width >= 140, frame.height >= 120 else {
                    continue
                }
                let isStd = AXWindowLookup.isStandardOrDialogWindow(axWin)
                if isStd {
                    standardIDs.insert(wid)
                }
                if openIDs.insert(wid).inserted {
                    items.append(OpenAXWindowItem(
                        windowID: wid,
                        pid: pid,
                        bundleID: bid,
                        element: axWin,
                        frame: frame,
                        isStandardWindow: isStd
                    ))
                    sig.append(Int(wid))
                    sig.append(Int(frame.origin.x))
                    sig.append(Int(frame.origin.y))
                    sig.append(Int(frame.size.width))
                    sig.append(Int(frame.size.height))
                    sig.append(isStd ? 1 : 0)
                }
            }
        }
        return (items, openIDs, standardIDs, sig)
    }

    private func nonZeroAlphaWindowIDsInAllSpaces() -> Set<UInt32> {
        guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var ids: Set<UInt32> = []
        ids.reserveCapacity(list.count)
        for info in list {
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
                continue
            }
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            if wid != 0 {
                ids.insert(wid)
            }
        }
        return ids
    }

    private func syncAppWindows(forcePublish: Bool) async {
        guard !sharedBundleIDs.isEmpty else {
            audioStreamer.updateScope(isFullDesktop: isSharingFullDesktop, sharedBundleIDs: sharedBundleIDs)
            knownOpenAXWindowIDs.removeAll()
            knownStandardAXWindowIDs.removeAll()
            publishTopology(from: [], force: false)
            return
        }
        audioStreamer.updateScope(isFullDesktop: isSharingFullDesktop, sharedBundleIDs: sharedBundleIDs)

        var pidToSharedBundle = resolveSharedPIDToBundleMap()
        let axPreSnap = snapshotOpenSharedAXWindows(pidToSharedBundle: pidToSharedBundle)

        // Fast-path check: avoid heavy XPC calls to `replayd` (`SCShareableContent.excludingDesktopWindows`)
        // during steady-state 60fps video playback when no window has opened, closed, moved, resized,
        // or changed title (including off-screen / other-Space AX windows!), AND no helper icon retry is due.
        let now = CFAbsoluteTimeGetCurrent()
        let hasPendingIconRefresh = windowIconStates.values.contains { $0.attempts < 4 && now >= $0.nextRetryAt }
        let cgSnap = currentOnScreenWindowSnapshot()
        let combinedPreSig = cgSnap.signature + [-999_999] + axPreSnap.signature
        if !forcePublish && !hasPendingIconRefresh && !lastAppWindows.isEmpty && !cgSnap.signature.isEmpty && combinedPreSig == lastCGWindowSignature {
            return
        }

        // In Main Screen mode (or when Virtual Display relocation is paused via 「一键移回主屏」), immediately rescue
        // any genuinely open normal window that spawned off-screen (e.g. at stale Virtual Display coordinates saved
        // by WeChat / WeChatAppEx) AND surface newly spawned windows stranded on an inactive Space (e.g. Desktop 1
        // while WeChat's main window is in Full Screen on the Host).
        let activelyIsolatingOnVD = useVirtualDisplayMode && !isRelocationPaused
        var rescuedOrSurfacedAny = false
        if !activelyIsolatingOnVD && !axPreSnap.items.isEmpty {
            let physicalBounds = VirtualDisplayManager.physicalDisplayBounds(excluding: virtualDisplayManager?.displayID ?? 0)
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            var cascadeIdx = 0

            for item in axPreSnap.items where suppressedWindows[item.windowID] == nil {
                let winArea = max(1.0, item.frame.width * item.frame.height)
                let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
                let isOnPhysical = physicalBounds.contains { disp in
                    if disp.contains(center) { return true }
                    let inter = disp.intersection(item.frame)
                    guard !inter.isNull && !inter.isEmpty else { return false }
                    return (inter.width * inter.height) / winArea >= 0.25
                }

                if !isOnPhysical {
                    let anchorDisp: CGRect = {
                        if let primID = primaryWindowByBundle[item.bundleID],
                           let primBounds = AXWindowLookup.cgBounds(of: primID),
                           let matched = physicalBounds.first(where: { $0.contains(CGPoint(x: primBounds.midX, y: primBounds.midY)) }) {
                            return matched
                        }
                        return physicalBounds.first ?? mainBounds
                    }()
                    let safeArea = CGRect(
                        x: anchorDisp.minX + 24,
                        y: anchorDisp.minY + 44,
                        width: max(200, anchorDisp.width - 48),
                        height: max(160, anchorDisp.height - 68)
                    )
                    var targetSize = item.frame.size
                    if targetSize.width > safeArea.width || targetSize.height > safeArea.height {
                        targetSize = CGSize(
                            width: min(targetSize.width, safeArea.width),
                            height: min(targetSize.height, safeArea.height)
                        )
                        AXWindowLookup.setSize(item.element, targetSize)
                        if let updated = AXWindowLookup.frame(of: item.element)?.size {
                            targetSize = updated
                        }
                    }
                    let cascade = CGFloat(cascadeIdx % 8) * 28
                    cascadeIdx += 1
                    let targetOrigin = CGPoint(
                        x: min(max(safeArea.minX + 60 + cascade, safeArea.minX), max(safeArea.minX, safeArea.maxX - targetSize.width)),
                        y: min(max(safeArea.minY + 40 + cascade, safeArea.minY), max(safeArea.minY, safeArea.maxY - targetSize.height))
                    )
                    AXWindowLookup.setPosition(item.element, targetOrigin)
                    rescuedOrSurfacedAny = true
                    OpenUULogger.shared.info(
                        "CAPTURE",
                        "rescued off-screen window win=\(item.windowID) pid=\(item.pid) from=\(Int(item.frame.minX)),\(Int(item.frame.minY)) to=\(Int(targetOrigin.x)),\(Int(targetOrigin.y))"
                    )
                } else if !cgSnap.visibleIDs.contains(item.windowID) && !knownOpenAXWindowIDs.contains(item.windowID) {
                    // Brand-new window spawned on an inactive macOS Space (e.g. Desktop 1 while WeChat is in Full Screen):
                    // activate its owning process via AXFrontmost + AppKit and raise the window so the Host user sees it too.
                    AXWindowLookup.activateProcess(item.pid)
                    AXWindowLookup.raise(item.element)
                    rescuedOrSurfacedAny = true
                    OpenUULogger.shared.info("CAPTURE", "surfaced cross-space window win=\(item.windowID) pid=\(item.pid)")
                }
            }
        }

        if rescuedOrSurfacedAny {
            try? await Task.sleep(for: .milliseconds(120))
        }

        var postSnap = currentOnScreenWindowSnapshot()
        let axPostSnap = rescuedOrSurfacedAny ? snapshotOpenSharedAXWindows(pidToSharedBundle: pidToSharedBundle) : axPreSnap
        knownOpenAXWindowIDs = axPostSnap.openIDs
        knownStandardAXWindowIDs = axPostSnap.standardIDs
        let hasOffSpaceOpenWindows = axPostSnap.openIDs.contains { wid in
            suppressedWindows[wid] == nil && !postSnap.visibleIDs.contains(wid)
        }

        guard var content = try? await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: !hasOffSpaceOpenWindows
        ) else {
            return
        }
        for win in content.windows {
            if let pid = win.owningApplication?.processID, pid != 0,
               let bid = canonicalSharedBundleID(for: win.owningApplication?.bundleIdentifier) {
                pidToSharedBundle[pid] = bid
            }
        }
        lastCGWindowSignature = postSnap.signature + [-999_999] + axPostSnap.signature

        // In Virtual Display mode (Scheme C), ensure the virtual display is online with a valid mode and relocate
        // normal windows onto the virtual display — UNLESS the app's primary window could not be moved onto the
        // virtual display (e.g. WeChat is in macOS Full Screen on the Host's physical monitor, where snatching child
        // windows onto an invisible virtual display would hide newly opened images/links/videos from the Host user).
        if activelyIsolatingOnVD,
           let vdm = virtualDisplayManager,
           await vdm.ensureVirtualDisplayReady() {
            var movedAny = false
            let candidateNormalWins = content.windows.filter { win in
                guard isNormalAppWindow(win) else { return false }
                return resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle) != nil
            }
            let groupedByBundle = Dictionary(grouping: candidateNormalWins) { win in
                resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle) ?? ""
            }
            for (bid, wins) in groupedByBundle where !bid.isEmpty {
                let electedPrimary = wins.first(where: { $0.windowID == primaryWindowByBundle[bid] })
                    ?? pickPreferredPrimaryWindow(candidates: wins, canonicalBundleID: bid)
                var primaryOnVD = true
                if let prim = electedPrimary, let primPID = prim.owningApplication?.processID {
                    if vdm.isWindowOnVirtualDisplay(prim.frame) {
                        primaryOnVD = true
                    } else {
                        primaryOnVD = vdm.moveWindowToVirtualDisplay(pid: primPID, windowID: prim.windowID, currentFrame: prim.frame)
                        if primaryOnVD { movedAny = true }
                    }
                }
                guard primaryOnVD else { continue }
                for win in wins where win.windowID != electedPrimary?.windowID {
                    guard let pid = win.owningApplication?.processID else { continue }
                    if !vdm.isWindowOnVirtualDisplay(win.frame) {
                        if vdm.moveWindowToVirtualDisplay(pid: pid, windowID: win.windowID, currentFrame: win.frame) {
                            movedAny = true
                        }
                    }
                }
            }
            if movedAny {
                try? await Task.sleep(for: .milliseconds(150))
                if let refreshed = try? await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnly: !hasOffSpaceOpenWindows
                ) {
                    content = refreshed
                    postSnap = currentOnScreenWindowSnapshot()
                    let axAfterVD = snapshotOpenSharedAXWindows(pidToSharedBundle: pidToSharedBundle)
                    knownOpenAXWindowIDs = axAfterVD.openIDs
                    knownStandardAXWindowIDs = axAfterVD.standardIDs
                    lastCGWindowSignature = postSnap.signature + [-999_999] + axAfterVD.signature
                }
            }
        }
        let visibleOnScreenIDs = postSnap.visibleIDs
        let openAXWindowIDs = knownOpenAXWindowIDs
        let nonZeroAlphaAllIDs = hasOffSpaceOpenWindows ? nonZeroAlphaWindowIDsInAllSpaces() : visibleOnScreenIDs

        // Include all normal windows (layer == 0 or pinned standard windows at layer <= 25) PLUS all floating
        // popovers / emoji pickers / animated sticker hover previews / context menus (layer 1..400).
        let existingIDsOnHost = Set(content.windows.map(\.windowID)).union(openAXWindowIDs)
        suppressedWindows = suppressedWindows.filter { existingIDsOnHost.contains($0.key) }

        if !suppressedWindows.isEmpty {
            let zOrderRank = currentNormalWindowZOrder()
            var minActiveRankByBundle: [String: Int] = [:]
            for win in content.windows where win.windowLayer == 0 && win.frame.width >= 140 && win.frame.height >= 120 {
                guard suppressedWindows[win.windowID] == nil,
                      let bid = resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle),
                      let rank = zOrderRank[win.windowID] else { continue }
                if let cur = minActiveRankByBundle[bid] {
                    if rank < cur { minActiveRankByBundle[bid] = rank }
                } else {
                    minActiveRankByBundle[bid] = rank
                }
            }

            var focusedWinByPID: [pid_t: CGWindowID] = [:]
            var unsuppressedIDs: [UInt32] = []
            for win in content.windows {
                guard var state = suppressedWindows[win.windowID] else { continue }
                let bid = resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle) ?? state.bundleID
                let winPID = win.owningApplication?.processID ?? 0
                let curTitle = win.title ?? ""
                let frameChanged = !state.lastFrame.isEmpty && (
                    abs(win.frame.width - state.lastFrame.width) > 2 ||
                    abs(win.frame.height - state.lastFrame.height) > 2 ||
                    abs(win.frame.origin.x - state.lastFrame.origin.x) > 2 ||
                    abs(win.frame.origin.y - state.lastFrame.origin.y) > 2
                )
                let titleChanged = !curTitle.isEmpty && curTitle != state.lastTitle

                if frameChanged || titleChanged {
                    unsuppressedIDs.append(win.windowID)
                    continue
                }

                // If the user clicked inside an active window AFTER this window was suppressed (e.g. clicked another
                // image or link in WeChat) and macOS Accessibility reports this reused window as now focused/main,
                // unsuppress immediately — even for pinned `windowLayer == 3` panels or cross-Space windows!
                if interactionSeq > state.suppressedAtInteractionSeq, winPID != 0 {
                    let focusedID: CGWindowID
                    if let cached = focusedWinByPID[winPID] {
                        focusedID = cached
                    } else {
                        let queried = AXWindowLookup.focusedOrMainWindowID(pid: winPID) ?? 0
                        focusedWinByPID[winPID] = queried
                        focusedID = queried
                    }
                    if focusedID == win.windowID {
                        unsuppressedIDs.append(win.windowID)
                        continue
                    }
                }

                if win.windowLayer == 0,
                   let myRank = zOrderRank[win.windowID],
                   let activeRank = minActiveRankByBundle[bid] {
                    if myRank > activeRank {
                        state.seenBehindActiveWindow = true
                        state.lastFrame = win.frame
                        state.lastTitle = curTitle
                        suppressedWindows[win.windowID] = state
                    } else if state.seenBehindActiveWindow {
                        unsuppressedIDs.append(win.windowID)
                    }
                }
            }
            for id in unsuppressedIDs {
                suppressedWindows.removeValue(forKey: id)
                OpenUULogger.shared.info("CAPTURE", "unsuppressed re-presented win=\(id)")
            }
        }

        let appWindows = content.windows.filter { win in
            guard suppressedWindows[win.windowID] == nil else { return false }
            let isNormal = isNormalAppWindow(win)
            let isOnCurrentSpace = visibleOnScreenIDs.isEmpty || visibleOnScreenIDs.contains(win.windowID)
            let isOpenOnAnotherSpace = isNormal &&
                openAXWindowIDs.contains(win.windowID) &&
                nonZeroAlphaAllIDs.contains(win.windowID)
            guard isOnCurrentSpace || isOpenOnAnotherSpace else { return false }
            guard resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle) != nil else { return false }
            if isNormal {
                return true
            }
            if win.windowLayer > 0 && win.windowLayer < Self.maxCapturablePopoverLayer {
                return Self.isCapturablePopoverFrame(win.frame)
            }
            return false
        }

        let normalWindowsByBundle = Dictionary(grouping: appWindows.filter { isNormalAppWindow($0) }) { win in
            resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle)
                ?? (win.owningApplication?.bundleIdentifier ?? "")
        }
        for existingBid in Array(primaryWindowByBundle.keys) {
            if (normalWindowsByBundle[existingBid] ?? []).isEmpty {
                primaryWindowByBundle.removeValue(forKey: existingBid)
            }
        }
        for (bid, candidates) in normalWindowsByBundle where !bid.isEmpty {
            if let curPrimaryID = primaryWindowByBundle[bid],
               let curWin = candidates.first(where: { $0.windowID == curPrimaryID }) {
                if !isMainBundleProcessWindow(curWin, canonicalBundleID: bid),
                   candidates.contains(where: { isMainBundleProcessWindow($0, canonicalBundleID: bid) }),
                   let promoted = pickPreferredPrimaryWindow(candidates: candidates, canonicalBundleID: bid) {
                    primaryWindowByBundle[bid] = promoted.windowID
                }
            } else if let elected = pickPreferredPrimaryWindow(candidates: candidates, canonicalBundleID: bid) {
                primaryWindowByBundle[bid] = elected.windowID
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
            windowIconStates.removeValue(forKey: id)
        }
        windowIconStates = windowIconStates.filter { currentIDs.contains($0.key) }

        let prevSizesByID: [UInt32: CGSize] = Dictionary(uniqueKeysWithValues: lastAppWindows.map { ($0.windowID, $0.frame.size) })
        for win in appWindows where !isNormalAppWindow(win) && trackedIDs.contains(win.windowID) {
            if let prevSize = prevSizesByID[win.windowID],
               (abs(win.frame.width - prevSize.width) > 2 || abs(win.frame.height - prevSize.height) > 2) {
                windowCroppedSizes.removeValue(forKey: win.windowID)
                windowContentInsets.removeValue(forKey: win.windowID)
            }
        }

        await refreshHelperWindowIcons(for: appWindows, pidToSharedBundle: pidToSharedBundle)

        lastAppWindows = appWindows
        // Publish topology BEFORE starting new engines so the Client knows each window's `kind` (floating popover vs
        // normal window), live Dock icon, original title, and relative offset `(rel_x, rel_y)` before its first video frame arrives.
        publishTopology(from: appWindows, pidToSharedBundle: pidToSharedBundle, force: forcePublish)

        // 2. Start engines for newly opened windows across all shared apps, and sync size for existing windows
        //    (including floating popovers such as WeChat's search dropdown, which expands dynamically while typing).
        var startedAny = false
        for win in appWindows {
            if trackedIDs.contains(win.windowID) {
                engines[win.windowID]?.updateWindowLogicalSize(win.frame.size)
                continue
            }
            let isNormal = isNormalAppWindow(win)
            if isNormal {
                let bid = resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle)
                    ?? (win.owningApplication?.bundleIdentifier ?? "")
                if !bid.isEmpty, primaryWindowByBundle[bid] == nil {
                    primaryWindowByBundle[bid] = win.windowID
                }
            }
            do {
                try await startEngine(for: win, isNormalWindow: isNormal)
                startedAny = true
                let appName = win.owningApplication?.applicationName ?? "App"
                OpenUULogger.shared.info("CAPTURE", "started win=\(win.windowID) app=\(appName) layer=\(win.windowLayer) normal=\(isNormal) frame=\(Int(win.frame.origin.x)),\(Int(win.frame.origin.y)) \(Int(win.frame.width))x\(Int(win.frame.height))")
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
            publishTopology(from: appWindows, pidToSharedBundle: pidToSharedBundle, force: forcePublish)
        }
    }

    private func publishTopology(from windows: [SCWindow], pidToSharedBundle: [pid_t: String] = [:], force: Bool) {
        let frameByID: [UInt32: CGRect] = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.frame) })
        let normalWindowsByBundle = Dictionary(grouping: windows.filter { isNormalAppWindow($0) }) { win in
            resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle)
                ?? (win.owningApplication?.bundleIdentifier ?? "")
        }
        let hasPopover = windows.contains { !isNormalAppWindow($0) }
        let zOrderRank = hasPopover ? currentNormalWindowZOrder() : [:]

        var items: [WindowTopologyItem] = windows.map { win in
            let bid = resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle)
                ?? (win.owningApplication?.bundleIdentifier ?? "")
            let appName = win.owningApplication?.applicationName ?? "App"
            let primaryID = primaryWindowByBundle[bid] ?? win.windowID
            let isPopover = !isNormalAppWindow(win)
            let isMain = !isPopover && win.windowID == primaryID
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
            let iconState = windowIconStates[win.windowID]
            let rawTitle = resolveOriginalTitle(for: win, appName: appName, dockTitle: iconState?.dockTitle)
            let windowIconB64: String? = isPopover ? nil : iconState?.iconB64
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
        audioStreamer.updateScope(isFullDesktop: isSharingFullDesktop, sharedBundleIDs: sharedBundleIDs)
    }

    private func isHelperOrDistinctIconWindow(_ win: SCWindow, canonicalBundleID: String, primaryPID: pid_t) -> Bool {
        guard isNormalAppWindow(win) else { return false }
        let rawBid = win.owningApplication?.bundleIdentifier ?? ""
        let winPID = win.owningApplication?.processID ?? 0
        if !rawBid.isEmpty && rawBid != canonicalBundleID {
            return true
        }
        if rawBid.localizedCaseInsensitiveContains("AppEx") {
            return true
        }
        if winPID != 0 && primaryPID != 0 && winPID != primaryPID {
            return true
        }
        return false
    }

    private func refreshHelperWindowIcons(for windows: [SCWindow], pidToSharedBundle: [pid_t: String]) async {
        let now = CFAbsoluteTimeGetCurrent()
        let pidByID: [UInt32: pid_t] = Dictionary(uniqueKeysWithValues: windows.map { ($0.windowID, $0.owningApplication?.processID ?? 0) })
        let retryDelays: [CFAbsoluteTime] = [0.8, 2.0, 4.5]

        var requests: [LiveDockIconExtractor.Request] = []
        for win in windows where isNormalAppWindow(win) {
            let canonicalBid = resolvedSharedBundleID(for: win, pidToSharedBundle: pidToSharedBundle)
                ?? (win.owningApplication?.bundleIdentifier ?? "")
            let primaryID = primaryWindowByBundle[canonicalBid] ?? win.windowID
            let primaryPID = pidByID[primaryID] ?? 0
            guard isHelperOrDistinctIconWindow(win, canonicalBundleID: canonicalBid, primaryPID: primaryPID) else {
                continue
            }

            let curTitle = (win.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if var existing = windowIconStates[win.windowID] {
                let titleChanged = !curTitle.isEmpty && curTitle != existing.lastTitle
                if titleChanged {
                    existing.lastTitle = curTitle
                    existing.attempts = 0
                    existing.nextRetryAt = now
                    windowIconStates[win.windowID] = existing
                } else if existing.attempts >= 4 || now < existing.nextRetryAt {
                    continue
                }
            }

            let winPID = win.owningApplication?.processID ?? 0
            guard winPID != 0 else { continue }
            let primaryApp = NSRunningApplication.runningApplications(withBundleIdentifier: canonicalBid).first
            let primaryAppName = primaryApp?.localizedName ?? ""
            let primaryBundlePath = primaryApp?.bundleURL?.path

            requests.append(
                LiveDockIconExtractor.Request(
                    windowID: win.windowID,
                    pid: winPID,
                    rawBundleID: win.owningApplication?.bundleIdentifier ?? "",
                    appName: win.owningApplication?.applicationName ?? "",
                    windowTitle: curTitle,
                    primaryAppName: primaryAppName,
                    primaryBundleURLPath: primaryBundlePath
                )
            )
        }

        guard !requests.isEmpty else { return }
        let captured = await LiveDockIconExtractor.captureBatch(requests: requests)

        for req in requests {
            let prev = windowIconStates[req.windowID]
            let prevAttempts = prev?.attempts ?? 0
            let nextAttemptCount = prevAttempts + 1
            let delay = prevAttempts < retryDelays.count ? retryDelays[prevAttempts] : 60.0
            let res = captured[req.windowID]
            let newB64 = (res?.iconB64?.isEmpty == false) ? res?.iconB64 : prev?.iconB64
            let newDockTitle = (res?.dockTitle?.isEmpty == false) ? res?.dockTitle : prev?.dockTitle

            windowIconStates[req.windowID] = WindowIconState(
                iconB64: newB64,
                dockTitle: newDockTitle,
                lastTitle: req.windowTitle,
                attempts: nextAttemptCount,
                nextRetryAt: now + delay
            )
            if let b64 = newB64, b64 != prev?.iconB64 {
                OpenUULogger.shared.debug("CAPTURE", "updated live dock icon win=\(req.windowID) title='\(newDockTitle ?? req.windowTitle)' bytes=\(b64.count)")
            }
        }
    }

    private func resolveOriginalTitle(for win: SCWindow, appName: String, dockTitle: String?) -> String {
        let scTitle = (win.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let isGenericHelperTitle: (String) -> Bool = { s in
            let lower = s.lowercased()
            return lower.isEmpty || lower == "wechatappex" || lower == "wechatappex helper"
        }

        if !isGenericHelperTitle(scTitle) {
            return scTitle
        }
        if let dt = dockTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !isGenericHelperTitle(dt) {
            return dt
        }
        if let pid = win.owningApplication?.processID,
           let axWin = AXWindowLookup.find(pid: pid, windowID: win.windowID, frame: win.frame) {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXTitleAttribute as CFString, &ref) == .success,
               let axTitle = (ref as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !isGenericHelperTitle(axTitle) {
                return axTitle
            }
        }
        if let pid = win.owningApplication?.processID,
           let locName = NSRunningApplication(processIdentifier: pid)?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !isGenericHelperTitle(locName) {
            return locName
        }
        return !scTitle.isEmpty ? scTitle : (appName.isEmpty ? "远程窗口" : appName)
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

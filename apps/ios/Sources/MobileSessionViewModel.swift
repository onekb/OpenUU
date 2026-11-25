import Combine
import CryptoKit
import Foundation
import SwiftUI
import UIKit

enum MobileTab: Int, CaseIterable, Hashable {
    case connect = 0
    case devices = 1
    case remote = 2
    case settings = 3
}

enum MobileConnectionPhase: Equatable {
    case idle
    case connecting(String)
    case connected(String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var hostName: String {
        if case .connected(let name) = self { return name }
        return ""
    }
}

enum TouchControlMode: String, CaseIterable, Identifiable {
    case directTouch = "direct"
    case trackpad = "trackpad"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .directTouch: return "直触"
        case .trackpad: return "触控板"
        }
    }

    var systemImage: String {
        switch self {
        case .directTouch: return "hand.tap"
        case .trackpad: return "cursorarrow.motionlines"
        }
    }
}

enum VideoFitMode: String, CaseIterable, Identifiable {
    case fit = "fit"
    case fill = "fill"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: return "适应"
        case .fill: return "铺满"
        }
    }

    var fullLabel: String {
        switch self {
        case .fit: return "适应屏幕"
        case .fill: return "铺满全屏"
        }
    }

    var systemImage: String {
        switch self {
        case .fit: return "rectangle.arrowtriangle.2.inward"
        case .fill: return "rectangle.arrowtriangle.2.outward"
        }
    }
}

struct RemoteNotificationBanner: Identifiable, Equatable {
    let id = UUID()
    let appBundleID: String
    let title: String
    let subtitle: String
    let body: String
    let receivedAt = Date()
}

private final class LockedValue<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ initial: T) {
        self.storage = initial
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}

private struct E2EConfig {
    let target: String
    let pin: String
    let appBundleID: String
    let autoTest: Bool
    let landscape: Bool
    var openedApp: Bool = false
    var decodedMilestoneLogged: Bool = false
    var autoTestSent: Bool = false
    var landscapeRequested: Bool = false
    var landscapeConfirmedLogged: Bool = false
}

@MainActor
final class MobileSessionViewModel: ObservableObject {
    @Published var selectedTab: MobileTab = .connect
    @Published var phase: MobileConnectionPhase = .idle
    @Published var statusMessage: String = "未连接"
    @Published var linkBadge: String = ""
    @Published var linkRttMs: UInt32 = 0
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var identity: IdentitySnapshotModel?
    @Published var remoteApps: [RemoteAppSummary] = []
    @Published var appIcons: [String: UIImage] = [:]

    // Multi-window topology & popovers
    @Published var remoteWindows: [WindowTopologyItem] = []
    @Published var normalWindows: [WindowTopologyItem] = []
    @Published var activePopovers: [WindowTopologyItem] = []
    @Published var popoverRenderers: [UInt32: IOSVideoDisplayRenderer] = [:]
    @Published var popoverReadyIDs: Set<UInt32> = []
    @Published var selectedWindowID: UInt32 = 0
    @Published var windowSwitchNotice: String?
    @Published var proactiveTabRevealTick: Int = 0
    @Published var pinLandscapeTabBar: Bool = false

    @Published var showAppLauncher: Bool = true
    @Published var showDebugHUD: Bool = false
    @Published var remoteAudioEnabled: Bool = UserDefaults.standard.object(forKey: "openuu.ios.remoteAudioEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(remoteAudioEnabled, forKey: "openuu.ios.remoteAudioEnabled")
            audioPlayer.setMuted(!remoteAudioEnabled)
            if phase.isConnected {
                bridge.sendAudioControl(enabled: remoteAudioEnabled, muteHost: muteHostAudio)
            }
        }
    }
    @Published var muteHostAudio: Bool = UserDefaults.standard.object(forKey: "openuu.ios.muteHostAudio") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(muteHostAudio, forKey: "openuu.ios.muteHostAudio")
            if phase.isConnected {
                bridge.sendAudioControl(enabled: remoteAudioEnabled, muteHost: muteHostAudio)
            }
        }
    }
    @Published var touchMode: TouchControlMode = .directTouch
    @Published var manualFullscreen: Bool = false
    @Published var videoFitMode: VideoFitMode = .fit
    @Published var isLandscape: Bool = false
    @Published var showGestureGuide: Bool = false
    @Published var gestureFeedbackBadge: String?
    @Published var cursorPos: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published var cursorKind: String = "arrow"
    @Published var stickyModifiers: UInt32 = 0
    @Published var videoTelemetry: VideoStreamTelemetry = .empty
    @Published var notificationBanner: RemoteNotificationBanner?
    @Published var logs: [String] = []
    @Published var wanConfig: WanConfigModel = .default

    // Connect form & canvas zoom state
    @Published var targetInput: String = ""
    @Published var connectingStartedAt: Date?
    @Published var portInput: String = "\(OpenUUConstants.defaultPort)"
    @Published var pinInput: String = ""
    @Published var canvasZoomScale: CGFloat = 1.0
    @Published var canvasResetToken: Int = 0
    @Published var canvasZoomCommandScale: CGFloat = 1.0
    @Published var canvasZoomCommandToken: Int = 0

    let bridge: OpenUUBridge
    let deviceBook: DeviceBookStore
    var updater = MobileAppUpdater()
    let videoRenderer = IOSVideoDisplayRenderer()
    let audioPlayer = IOSAudioStreamPlayer()
    private var updaterCancellables: Set<AnyCancellable> = []

    private let activeWindowIDBox = LockedValue<UInt32>(0)
    private let popoverRenderersBox = LockedValue<[UInt32: IOSVideoDisplayRenderer]>([:])
    private let knownPopoverIDsBox = LockedValue<Set<UInt32>>([])
    private let pendingWindowPacketsBox = LockedValue<[UInt32: [EncodedVideoPacket]]>([:])
    private let userPausedAtLauncherBox = LockedValue<Bool>(false)

    // Window auto-focus & history tracking
    private var knownNormalWindowIDs: Set<UInt32> = []
    private var hadPriorTopology: Bool = false
    private var windowHistory: [UInt32] = []
    private var windowNoticeTask: Task<Void, Never>?

    // Popover drag target lock (from MOUSE_DOWN until MOUSE_UP)
    private var dragTargetWindowID: UInt32 = 0
    private var dragTargetRelX: Float = 0
    private var dragTargetRelY: Float = 0

    private let cachesDir: URL
    private let e2eLogURL: URL
    private var e2eConfig: E2EConfig?
    private var lastConnectedTarget: String = ""
    private var lastConnectedPort: UInt16 = OpenUUConstants.defaultPort
    private var lastConnectedPin: String = ""
    private var autoOpenDesktopOnConnect: Bool = false
    private var lastSyncedClipHash: String = ""
    private var discoveryTask: Task<Void, Never>?
    private var bannerDismissTask: Task<Void, Never>?
    private nonisolated(unsafe) var pasteboardObservers: [NSObjectProtocol] = []

    private static let maxLogs = 250

    init() {
        let appSupportRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let openuuSupport = appSupportRoot.appendingPathComponent("OpenUU", isDirectory: true)
        let cachesRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())

        self.cachesDir = cachesRoot
        self.e2eLogURL = cachesRoot.appendingPathComponent("openuu_e2e.log")

        let deviceName = UIDevice.current.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDeviceName = deviceName.isEmpty ? "OpenUU-iOS" : deviceName

        self.bridge = OpenUUBridge(
            deviceName: finalDeviceName,
            appSupportDir: openuuSupport,
            cachesDir: cachesRoot
        )
        self.deviceBook = DeviceBookStore(appSupportDir: openuuSupport)

        setupBridgeCallbacks()
        setupRendererCallbacks()
        setupPasteboardObservers()

        bridge.startDiscovery()
        refreshIdentityAndDeviceBook()
        startDiscoveryPolling()
        appendLog("OpenUU Core 已就绪 (\(finalDeviceName), \(MobileAppVersion.display))")

        updater.coordURLProvider = { [weak self] in
            self?.wanConfig.coord_url ?? OpenUUConstants.defaultCoordURL
        }
        updater.onLog = { [weak self] msg in
            self?.appendLog("[更新] \(msg)")
        }
        updater.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &updaterCancellables)
        updater.startScheduledChecks()

        checkAndStartE2EIfConfigured()
    }

    deinit {
        discoveryTask?.cancel()
        bannerDismissTask?.cancel()
        windowNoticeTask?.cancel()
        for obs in pasteboardObservers {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Setup Callbacks

    private func setupBridgeCallbacks() {
        bridge.onStatus = { [weak self] msg in
            Task { @MainActor [weak self] in
                self?.handleStatusMessage(msg)
            }
        }

        bridge.onControlEvent = { [weak self] evt in
            Task { @MainActor [weak self] in
                self?.handleControlEvent(evt)
            }
        }

        bridge.onProbeResults = { [weak self] results in
            Task { @MainActor [weak self] in
                self?.deviceBook.applyProbeResults(results)
            }
        }

        let renderer = videoRenderer
        let windowBox = activeWindowIDBox
        let popRenderersBox = popoverRenderersBox
        let popIDsBox = knownPopoverIDsBox
        let pendingBox = pendingWindowPacketsBox
        let pausedBox = userPausedAtLauncherBox
        bridge.onVideoFrame = { [weak self] packet in
            var active = windowBox.value
            let popMap = popRenderersBox.value
            let isKnownPopover = (popMap[packet.windowID] != nil) || popIDsBox.value.contains(packet.windowID)

            if active == 0 && packet.windowID != 0 && !isKnownPopover && !pausedBox.value {
                active = packet.windowID
                windowBox.value = active
                let adoptedID = packet.windowID
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.selectedWindowID == 0 && !self.userPausedAtLauncherBox.value {
                        self.selectedWindowID = adoptedID
                        self.showAppLauncher = false
                        self.recomputeWindowBuckets(allWindows: self.remoteWindows, selectedID: adoptedID)
                    }
                }
            }

            if packet.windowID == active {
                renderer.enqueue(packet: packet)
            } else if let popRenderer = popMap[packet.windowID] {
                popRenderer.enqueue(packet: packet)
            } else if isKnownPopover {
                Task { @MainActor [weak self] in
                    self?.popoverRenderer(for: packet.windowID).enqueue(packet: packet)
                }
            } else if packet.windowID != 0 {
                // Buffer early frames arriving over QUIC before WindowTopology is processed on MainActor!
                var pending = pendingBox.value
                let isKey = (packet.flags & 0x01) != 0
                if pending[packet.windowID] == nil && pending.count >= 12, let firstKey = pending.keys.first {
                    pending.removeValue(forKey: firstKey)
                }
                var list = pending[packet.windowID] ?? []
                if isKey {
                    list.removeAll(keepingCapacity: true)
                    list.append(packet)
                } else if list.count < 10 {
                    list.append(packet)
                }
                pending[packet.windowID] = list
                pendingBox.value = pending
            }
        }

        let player = audioPlayer
        bridge.onAudioFrame = { packet in
            player.enqueue(packet)
        }
    }

    private func setupRendererCallbacks() {
        videoRenderer.onTelemetryUpdated = { [weak self] telemetry in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.videoTelemetry = telemetry
                self.handleDecodedFramesProgress(telemetry)
            }
        }
        videoRenderer.onRequestKeyframe = { [weak self] in
            Task { @MainActor [weak self] in
                self?.requestKeyframeNow()
            }
        }
    }

    private func setupPasteboardObservers() {
        let center = NotificationCenter.default
        let o1 = center.addObserver(forName: UIPasteboard.changedNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase.isConnected else { return }
                self.pushLocalClipboardToHost(silent: true)
            }
        }
        let o2 = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.phase.isConnected else { return }
                self.pushLocalClipboardToHost(silent: true)
            }
        }
        pasteboardObservers = [o1, o2]
    }

    private func startDiscoveryPolling() {
        discoveryTask?.cancel()
        let bridgeRef = bridge
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                let peers = await Task.detached(priority: .utility) {
                    bridgeRef.listPeers()
                }.value
                await MainActor.run {
                    self?.discoveredPeers = peers
                }
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
    }

    // MARK: - Connection & Identity

    func refreshIdentityAndDeviceBook() {
        if let snap = bridge.getIdentitySnapshot() {
            identity = snap
            wanConfig = snap.wan_config
            deviceBook.syncFromTrustedPeers(snap.trusted_peers)
        }
    }

    func connectFromForm() {
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(targetInput)
        guard !cleanTarget.isEmpty else { return }
        let port = UInt16(portInput.trimmingCharacters(in: .whitespacesAndNewlines)) ?? OpenUUConstants.defaultPort
        connectSmart(target: cleanTarget, port: port, pin: pinInput.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func connectSmart(target: String, port: UInt16 = OpenUUConstants.defaultPort, pin: String = "", autoOpenDesktop: Bool = false) {
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(target)
        guard !cleanTarget.isEmpty else { return }
        clearWindowTrackingState()
        lastConnectedTarget = cleanTarget
        lastConnectedPort = port
        lastConnectedPin = pin
        autoOpenDesktopOnConnect = autoOpenDesktop
        connectingStartedAt = Date()
        let pretty = DeviceCodeFormatter.formatInput(cleanTarget)
        phase = .connecting("正在发起连接 \(pretty)...")
        statusMessage = "正在发起连接 \(pretty)..."
        linkBadge = "握手中..."
        appendLog("发起智能连接: \(cleanTarget)")
        let ok = bridge.connectSmart(target: cleanTarget, defaultPort: port, pin: pin)
        if !ok {
            connectingStartedAt = nil
            phase = .error("连接参数无效")
            appendLog("connectSmart 参数校验失败")
        }
    }

    func connectDirect(hostIP: String, port: UInt16, pin: String) {
        let cleanIP = hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanIP.isEmpty else { return }
        clearWindowTrackingState()
        lastConnectedTarget = cleanIP
        lastConnectedPort = port
        lastConnectedPin = pin
        autoOpenDesktopOnConnect = false
        connectingStartedAt = Date()
        phase = .connecting("正在直连 \(cleanIP):\(port)...")
        statusMessage = "正在直连 \(cleanIP):\(port)..."
        linkBadge = "直连握手中..."
        appendLog("发起局域网直连: \(cleanIP):\(port)")
        let ok = bridge.connectClient(hostIP: cleanIP, port: port, pin: pin)
        if !ok {
            connectingStartedAt = nil
            phase = .error("直连参数无效")
        }
    }

    func elapsedConnectingSeconds(at now: Date = Date()) -> Int {
        guard let start = connectingStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    func clearConnectionError() {
        if case .error = phase {
            phase = .idle
        }
    }

    func disconnect() {
        bridge.disconnect()
        resetSessionState()
        connectingStartedAt = nil
        phase = .idle
        statusMessage = "已断开连接"
        appendLog("已主动断开连接")
    }

    private func clearWindowTrackingState() {
        knownNormalWindowIDs.removeAll()
        hadPriorTopology = false
        userPausedAtLauncherBox.value = false
        windowHistory.removeAll()
        windowNoticeTask?.cancel()
        windowNoticeTask = nil
        windowSwitchNotice = nil
        popoverReadyIDs.removeAll()
        pendingWindowPacketsBox.value = [:]
        dragTargetWindowID = 0
        dragTargetRelX = 0
        dragTargetRelY = 0
    }

    private func drainPendingPackets(for windowID: UInt32, into renderer: IOSVideoDisplayRenderer) {
        var map = pendingWindowPacketsBox.value
        guard let buffered = map.removeValue(forKey: windowID), !buffered.isEmpty else { return }
        pendingWindowPacketsBox.value = map
        for pkt in buffered {
            renderer.enqueue(packet: pkt)
        }
    }

    private func releaseAllPopoverRenderers() {
        for (_, r) in popoverRenderers {
            r.flushAndRemoveImage()
        }
        popoverRenderers.removeAll()
        popoverReadyIDs.removeAll()
        popoverRenderersBox.value = [:]
        knownPopoverIDsBox.value = []
    }

    @discardableResult
    func popoverRenderer(for windowID: UInt32) -> IOSVideoDisplayRenderer {
        if let existing = popoverRenderers[windowID] {
            return existing
        }
        let renderer = IOSVideoDisplayRenderer()
        let bridgeRef = bridge
        renderer.onRequestKeyframe = {
            bridgeRef.requestKeyframe(windowID: windowID)
        }
        renderer.onFirstFrameDecoded = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.activePopovers.contains(where: { $0.window_id == windowID }) {
                    self.popoverReadyIDs.insert(windowID)
                }
            }
        }
        popoverRenderers[windowID] = renderer
        popoverRenderersBox.value = popoverRenderers
        drainPendingPackets(for: windowID, into: renderer)
        return renderer
    }

    private func recomputeWindowBuckets(allWindows: [WindowTopologyItem], selectedID: UInt32) {
        let normals = allWindows.filter { $0.kind != 2 }
        normalWindows = normals

        let popovers = allWindows.filter { pop in
            pop.kind == 2 && (
                pop.parent_window_id == selectedID
                    || pop.parent_window_id == 0
                    || normals.count <= 1
            )
        }
        activePopovers = popovers

        let activePopoverIDs = Set(popovers.map(\.window_id))
        var changedMap = false
        for pop in popovers {
            let r: IOSVideoDisplayRenderer
            if let existing = popoverRenderers[pop.window_id] {
                r = existing
            } else {
                r = popoverRenderer(for: pop.window_id)
                changedMap = true
            }
            drainPendingPackets(for: pop.window_id, into: r)
        }
        for existingID in Array(popoverRenderers.keys) where !activePopoverIDs.contains(existingID) {
            if let removed = popoverRenderers.removeValue(forKey: existingID) {
                removed.flushAndRemoveImage()
                changedMap = true
            }
        }
        if changedMap {
            popoverRenderersBox.value = popoverRenderers
        }
        let trimmedReady = popoverReadyIDs.intersection(activePopoverIDs)
        if trimmedReady != popoverReadyIDs {
            popoverReadyIDs = trimmedReady
        }
        knownPopoverIDsBox.value = Set(allWindows.filter { $0.kind == 2 }.map(\.window_id))
    }

    private func resetSessionState() {
        audioPlayer.stop()
        activeWindowIDBox.value = 0
        clearWindowTrackingState()
        releaseAllPopoverRenderers()
        selectedWindowID = 0
        remoteApps = []
        remoteWindows = []
        normalWindows = []
        activePopovers = []
        showAppLauncher = true
        manualFullscreen = false
        gestureFeedbackBadge = nil
        linkBadge = ""
        linkRttMs = 0
        stickyModifiers = 0
        videoTelemetry = .empty
        canvasZoomScale = 1.0
        canvasZoomCommandScale = 1.0
        canvasResetToken += 1
        videoRenderer.setWanJitterMode(false)
        videoRenderer.resetStream(resetDecodedCounter: true)
    }

    // MARK: - Remote Apps & Windows

    func refreshRemoteApps() {
        bridge.requestAppList()
    }

    func openRemoteApp(bundleID: String, appName: String) {
        appendLog("打开远程应用: \(appName) (\(bundleID))")
        userPausedAtLauncherBox.value = false
        showAppLauncher = false
        if activeWindowIDBox.value == 0 {
            selectedWindowID = 0
            videoRenderer.resetStream(resetDecodedCounter: true)
        }
        bridge.startRemoteSession(bundleID: bundleID, windowID: 0)
    }

    func openFullDesktop() {
        openRemoteApp(bundleID: OpenUUConstants.fullDesktopBundleID, appName: "整台桌面")
    }

    func selectWindow(_ windowID: UInt32) {
        selectRemoteWindow(windowID)
    }

    func selectRemoteWindow(_ windowID: UInt32) {
        userPausedAtLauncherBox.value = false
        let prev = activeWindowIDBox.value
        if windowID == prev && !showAppLauncher {
            recomputeWindowBuckets(allWindows: remoteWindows, selectedID: windowID)
            return
        }
        if prev != 0 && prev != windowID && remoteWindows.contains(where: { $0.window_id == prev && $0.kind != 2 }) {
            windowHistory.removeAll { $0 == prev }
            windowHistory.append(prev)
        }
        dragTargetWindowID = 0
        dragTargetRelX = 0
        dragTargetRelY = 0
        activeWindowIDBox.value = windowID
        selectedWindowID = windowID
        showAppLauncher = false
        videoRenderer.resetStream(resetDecodedCounter: false)
        if windowID != 0 {
            drainPendingPackets(for: windowID, into: videoRenderer)
        }
        recomputeWindowBuckets(allWindows: remoteWindows, selectedID: windowID)
        if windowID != 0 {
            bridge.requestKeyframe(windowID: windowID)
        }
    }

    func enterRemoteWorkspace() {
        selectedTab = .remote
        if selectedWindowID == 0 && !normalWindows.isEmpty {
            userPausedAtLauncherBox.value = false
            let chosen = windowHistory.last(where: { id in normalWindows.contains(where: { $0.window_id == id }) })
                .flatMap { id in normalWindows.first(where: { $0.window_id == id }) }
                ?? normalWindows.first(where: { $0.kind == 0 })
                ?? normalWindows[0]
            selectRemoteWindow(chosen.window_id)
        }
    }

    var canNavigateBackWindow: Bool {
        let cur = selectedWindowID
        return windowHistory.contains { id in
            id != 0 && id != cur && normalWindows.contains(where: { $0.window_id == id })
        }
    }

    @discardableResult
    func navigateBackWindow() -> Bool {
        let cur = selectedWindowID
        while let prevID = windowHistory.popLast() {
            if let match = normalWindows.first(where: { $0.window_id == prevID && $0.window_id != cur }) {
                userPausedAtLauncherBox.value = false
                dragTargetWindowID = 0
                dragTargetRelX = 0
                dragTargetRelY = 0
                activeWindowIDBox.value = match.window_id
                selectedWindowID = match.window_id
                showAppLauncher = false
                videoRenderer.resetStream(resetDecodedCounter: false)
                drainPendingPackets(for: match.window_id, into: videoRenderer)
                recomputeWindowBuckets(allWindows: remoteWindows, selectedID: match.window_id)
                bridge.requestKeyframe(windowID: match.window_id)
                showWindowSwitchNotice("返回窗口 · \(match.displayTitle)")
                return true
            }
        }
        return false
    }

    func enterAppLauncherPage() {
        let prev = activeWindowIDBox.value
        if prev != 0 && normalWindows.contains(where: { $0.window_id == prev }) {
            windowHistory.removeAll { $0 == prev }
            windowHistory.append(prev)
        }
        userPausedAtLauncherBox.value = true
        dragTargetWindowID = 0
        dragTargetRelX = 0
        dragTargetRelY = 0
        activeWindowIDBox.value = 0
        selectedWindowID = 0
        showAppLauncher = true
        manualFullscreen = false
        gestureFeedbackBadge = nil
        videoRenderer.resetStream(resetDecodedCounter: true)
        recomputeWindowBuckets(allWindows: remoteWindows, selectedID: 0)
        refreshRemoteApps()
    }

    @discardableResult
    func dismissActivePopoversViaEsc() -> Bool {
        guard let topPop = activePopovers.last else { return false }
        let targetID = activeWindowIDBox.value != 0 ? activeWindowIDBox.value : topPop.window_id
        bridge.sendKey(windowID: targetID, keyCode: MacKeyCodes.escape, isDown: true, isRepeat: false, modifiers: 0)
        bridge.sendKey(windowID: targetID, keyCode: MacKeyCodes.escape, isDown: false, isRepeat: false, modifiers: 0)
        return true
    }

    /// Sends ⌘W to a remote window and stops its stream, switching back to the previous window (never disconnects).
    func closeRemoteWindowTab(_ windowID: UInt32) {
        guard windowID != 0 else { return }
        bridge.sendKey(windowID: windowID, keyCode: MacKeyCodes.w, isDown: true, isRepeat: false, modifiers: MacModifiers.command | 256)
        bridge.sendKey(windowID: windowID, keyCode: MacKeyCodes.w, isDown: false, isRepeat: false, modifiers: MacModifiers.command | 256)
        stopRemoteWindow(windowID)
    }

    func stopRemoteWindow(_ windowID: UInt32) {
        bridge.stopRemoteSession(windowID: windowID)
        knownNormalWindowIDs.remove(windowID)
        windowHistory.removeAll { $0 == windowID }
        let remaining = remoteWindows.filter {
            $0.window_id != windowID && !($0.kind == 2 && $0.parent_window_id == windowID)
        }
        remoteWindows = remaining
        let remainingNormals = remaining.filter { $0.kind != 2 }

        if activeWindowIDBox.value == windowID {
            dragTargetWindowID = 0
            dragTargetRelX = 0
            dragTargetRelY = 0
            var next: UInt32 = 0
            while let candidate = windowHistory.popLast() {
                if remainingNormals.contains(where: { $0.window_id == candidate }) {
                    next = candidate
                    break
                }
            }
            if next == 0 {
                next = (remainingNormals.first(where: { $0.kind == 0 }) ?? remainingNormals.first)?.window_id ?? 0
            }
            activeWindowIDBox.value = next
            selectedWindowID = next
            if next == 0 {
                showAppLauncher = true
                manualFullscreen = false
                gestureFeedbackBadge = nil
                videoRenderer.resetStream(resetDecodedCounter: true)
            } else {
                showAppLauncher = false
                videoRenderer.resetStream(resetDecodedCounter: false)
                bridge.requestKeyframe(windowID: next)
            }
        }
        recomputeWindowBuckets(allWindows: remaining, selectedID: selectedWindowID)
    }

    func requestKeyframeNow() {
        let winID = activeWindowIDBox.value
        guard winID != 0 else { return }
        bridge.requestKeyframe(windowID: winID)
    }

    func resizeActiveWindow(width: Float, height: Float) {
        let winID = activeWindowIDBox.value
        guard winID != 0, width > 0, height > 0 else { return }
        bridge.sendResizeWindow(windowID: winID, width: width, height: height)
        appendLog("已请求调整窗口尺寸: \(Int(width))×\(Int(height))")
    }

    // MARK: - Input Dispatch (with Popover Hit-Testing & Drag Lock)

    func currentLogicalSize() -> CGSize {
        let winID = activeWindowIDBox.value
        if let topo = remoteWindows.first(where: { $0.window_id == winID }),
           topo.width > 0, topo.height > 0 {
            return CGSize(width: CGFloat(topo.width), height: CGFloat(topo.height))
        }
        if videoTelemetry.encodedWidth > 0 && videoTelemetry.encodedHeight > 0 {
            return CGSize(
                width: CGFloat(videoTelemetry.encodedWidth) / 2.0,
                height: CGFloat(videoTelemetry.encodedHeight) / 2.0
            )
        }
        return CGSize(width: 960, height: 600)
    }

    func sendPopoverMouseDirect(
        popoverWindowID: UInt32,
        lx: Float,
        ly: Float,
        effectiveRelX: Float,
        effectiveRelY: Float,
        type: UInt8,
        button: UInt32 = 0,
        clickCount: UInt32 = 1
    ) {
        guard popoverWindowID != 0 else { return }
        let mods = stickyModifiers
        if type == 1 {
            dragTargetWindowID = popoverWindowID
            dragTargetRelX = effectiveRelX
            dragTargetRelY = effectiveRelY
        } else if type == 2 && dragTargetWindowID == popoverWindowID {
            dragTargetWindowID = 0
            dragTargetRelX = 0
            dragTargetRelY = 0
        }
        bridge.sendMouse(
            windowID: popoverWindowID,
            x: lx,
            y: ly,
            type: type,
            button: button,
            clickCount: clickCount,
            modifiers: mods
        )
    }

    func sendPopoverScrollDirect(popoverWindowID: UInt32, lx: Float, ly: Float, deltaX: Float, deltaY: Float) {
        guard popoverWindowID != 0 else { return }
        bridge.sendScroll(
            windowID: popoverWindowID,
            x: lx,
            y: ly,
            deltaX: deltaX,
            deltaY: deltaY,
            isContinuous: true,
            modifiers: stickyModifiers
        )
    }

    func sendMouseNormalized(nx: CGFloat, ny: CGFloat, type: UInt8, button: UInt32 = 0, clickCount: UInt32 = 1) {
        let logical = currentLogicalSize()
        let rawPx = Float(nx * logical.width)
        let rawPy = Float(ny * logical.height)
        let px = Float(min(max(nx, 0), 1) * logical.width)
        let py = Float(min(max(ny, 0), 1) * logical.height)
        let mods = stickyModifiers

        // Keep active drag (type=3) and release (type=2) locked to the window where MOUSE_DOWN (type=1) began
        if (type == 3 || type == 2) && dragTargetWindowID != 0 {
            let targetID = dragTargetWindowID
            let lx: Float
            let ly: Float
            if targetID != activeWindowIDBox.value {
                lx = rawPx - dragTargetRelX
                ly = rawPy - dragTargetRelY
            } else {
                lx = px
                ly = py
            }
            if type == 2 {
                dragTargetWindowID = 0
                dragTargetRelX = 0
                dragTargetRelY = 0
            }
            bridge.sendMouse(
                windowID: targetID,
                x: lx,
                y: ly,
                type: type,
                button: button,
                clickCount: clickCount,
                modifiers: mods
            )
            return
        }

        // Hit-test topmost active popovers (kind == 2) first using unclamped rawPx/rawPy
        if let hitPopover = activePopovers.reversed().first(where: { pop in
            pop.width > 1 && pop.height > 1
                && rawPx >= pop.rel_x && rawPx <= pop.rel_x + pop.width
                && rawPy >= pop.rel_y && rawPy <= pop.rel_y + pop.height
        }) {
            let lx = rawPx - hitPopover.rel_x
            let ly = rawPy - hitPopover.rel_y
            if type == 1 {
                dragTargetWindowID = hitPopover.window_id
                dragTargetRelX = hitPopover.rel_x
                dragTargetRelY = hitPopover.rel_y
            }
            bridge.sendMouse(
                windowID: hitPopover.window_id,
                x: lx,
                y: ly,
                type: type,
                button: button,
                clickCount: clickCount,
                modifiers: mods
            )
            return
        }

        if type == 1 {
            dragTargetWindowID = activeWindowIDBox.value
            dragTargetRelX = 0
            dragTargetRelY = 0
        }
        sendMouseLogical(x: px, y: py, type: type, button: button, clickCount: clickCount, modifiers: mods)
    }

    func sendMouseLogical(
        x: Float,
        y: Float,
        type: UInt8,
        button: UInt32 = 0,
        clickCount: UInt32 = 1,
        modifiers: UInt32? = nil
    ) {
        let winID = activeWindowIDBox.value
        guard winID != 0 else { return }
        bridge.sendMouse(
            windowID: winID,
            x: x,
            y: y,
            type: type,
            button: button,
            clickCount: clickCount,
            modifiers: modifiers ?? stickyModifiers
        )
    }

    func sendScrollNormalized(nx: CGFloat, ny: CGFloat, deltaX: Float, deltaY: Float) {
        let logical = currentLogicalSize()
        let rawPx = Float(nx * logical.width)
        let rawPy = Float(ny * logical.height)
        let px = Float(min(max(nx, 0), 1) * logical.width)
        let py = Float(min(max(ny, 0), 1) * logical.height)
        let mods = stickyModifiers

        if let hitPopover = activePopovers.reversed().first(where: { pop in
            pop.width > 1 && pop.height > 1
                && rawPx >= pop.rel_x && rawPx <= pop.rel_x + pop.width
                && rawPy >= pop.rel_y && py <= pop.rel_y + pop.height
        }) {
            bridge.sendScroll(
                windowID: hitPopover.window_id,
                x: rawPx - hitPopover.rel_x,
                y: rawPy - hitPopover.rel_y,
                deltaX: deltaX,
                deltaY: deltaY,
                isContinuous: true,
                modifiers: mods
            )
            return
        }

        sendScrollLogical(x: px, y: py, deltaX: deltaX, deltaY: deltaY, isContinuous: true, modifiers: mods)
    }

    func sendScrollLogical(
        x: Float,
        y: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Bool = true,
        modifiers: UInt32? = nil
    ) {
        let winID = activeWindowIDBox.value
        guard winID != 0 else { return }
        bridge.sendScroll(
            windowID: winID,
            x: x,
            y: y,
            deltaX: deltaX,
            deltaY: deltaY,
            isContinuous: isContinuous,
            modifiers: modifiers ?? stickyModifiers
        )
    }

    func toggleStickyModifier(_ bit: UInt32) {
        stickyModifiers ^= bit
    }

    func sendKeyTap(keyCode: UInt32, explicitModifiers: UInt32? = nil, isRepeat: Bool = false) {
        let winID = activeWindowIDBox.value
        guard winID != 0 else { return }
        let mods = explicitModifiers ?? stickyModifiers
        bridge.sendKey(windowID: winID, keyCode: keyCode, isDown: true, isRepeat: isRepeat, modifiers: mods)
        bridge.sendKey(windowID: winID, keyCode: keyCode, isDown: false, isRepeat: false, modifiers: mods)
        if !isRepeat && explicitModifiers == nil && stickyModifiers != 0 {
            stickyModifiers = 0
        }
    }

    func sendTextCommit(_ text: String) {
        let winID = activeWindowIDBox.value
        guard winID != 0, !text.isEmpty else { return }
        bridge.sendTextCommit(windowID: winID, text: text)
    }

    /// Streams committed IME characters directly to the Mac without requiring a visible staging input box.
    func handleDirectIMEInput(_ rawText: String) {
        guard !rawText.isEmpty else { return }
        if stickyModifiers != 0, rawText.count == 1, let first = rawText.first,
           let (code, extraShift) = MacKeyCodes.asciiToKeyAndShift(first) {
            let mods = stickyModifiers | extraShift
            sendKeyTap(keyCode: code, explicitModifiers: mods)
            stickyModifiers = 0
            return
        }
        if rawText == " " {
            sendKeyTap(keyCode: MacKeyCodes.space)
            return
        }

        var buffer = ""
        func flushBuffer() {
            if !buffer.isEmpty {
                sendTextCommit(buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }

        for ch in rawText {
            switch ch {
            case "\r\n", "\n", "\r", "\u{0003}":
                flushBuffer()
                sendKeyTap(keyCode: MacKeyCodes.returnKey)
            case "\t":
                flushBuffer()
                sendKeyTap(keyCode: MacKeyCodes.tab)
            case "\u{0008}", "\u{007F}":
                flushBuffer()
                sendKeyTap(keyCode: MacKeyCodes.delete)
            default:
                buffer.append(ch)
            }
        }
        flushBuffer()
    }

    // MARK: - Clipboard & File Drop

    func pushLocalClipboardToHost(silent: Bool = false) {
        guard phase.isConnected else { return }
        let pb = UIPasteboard.general
        if let text = pb.string, !text.isEmpty {
            let hash = sha256Hex(Data(text.utf8))
            if silent && hash == lastSyncedClipHash { return }
            lastSyncedClipHash = hash
            bridge.sendClipboardText(hash: hash, text: text)
            if !silent {
                appendLog("已同步本机剪贴板文本至 Mac (\(text.count) 字)")
            }
            return
        }
        if let img = pb.image, let pngData = img.pngData(), !pngData.isEmpty {
            let hash = sha256Hex(pngData)
            if silent && hash == lastSyncedClipHash { return }
            lastSyncedClipHash = hash
            bridge.sendClipboardImage(hash: hash, mimeType: "image/png", data: pngData)
            if !silent {
                appendLog("已同步本机剪贴板图片至 Mac (\(pngData.count / 1024) KB)")
            }
        }
    }

    func handlePickedFile(url: URL) {
        let winID = activeWindowIDBox.value
        guard winID != 0 else {
            appendLog("请先打开一个远程窗口再发送文件")
            return
        }
        let logical = currentLogicalSize()
        let x = Float(logical.width / 2.0)
        let y = Float(logical.height / 2.0)
        let uploadsDir = cachesDir.appendingPathComponent("uploads", isDirectory: true)
        let bridgeRef = bridge

        Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            do {
                try FileManager.default.createDirectory(at: uploadsDir, withIntermediateDirectories: true)
                let filename = url.lastPathComponent.isEmpty ? "openuu-upload" : url.lastPathComponent
                let destURL = uploadsDir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(filename)")
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try? FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: url, to: destURL)
                let ok = bridgeRef.sendFileBlob(windowID: winID, x: x, y: y, fileURL: destURL)
                await MainActor.run { [weak self] in
                    self?.appendLog(ok ? "已发送文件至远程窗口: \(filename)" : "发送文件失败: \(filename)")
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.appendLog("读取所选文件失败: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Device Book, WAN, Zoom & Viewport

    func probeDeviceBookOnline() {
        let queries = deviceBook.probeQueries()
        guard !queries.isEmpty else { return }
        bridge.probeDevicesOnline(queries)
    }

    func saveWanConfig(_ cfg: WanConfigModel) {
        let ok = bridge.setWanConfig(cfg)
        if ok {
            wanConfig = cfg
            refreshIdentityAndDeviceBook()
            appendLog("WAN 配置已保存 (\(cfg.coord_url))")
        } else {
            appendLog("保存 WAN 配置失败")
        }
    }

    func removeTrustedPeer(deviceID: String) {
        if bridge.removeTrustedPeer(deviceID: deviceID) {
            refreshIdentityAndDeviceBook()
            appendLog("已撤销信任设备: \(deviceID)")
        }
    }

    func dismissNotificationBanner() {
        notificationBanner = nil
        bannerDismissTask?.cancel()
    }

    func clearLogs() {
        logs.removeAll()
    }

    func resetZoom() {
        canvasZoomScale = 1.0
        canvasZoomCommandScale = 1.0
        canvasResetToken += 1
    }

    func setZoomScale(_ targetScale: CGFloat) {
        let clamped = min(max(targetScale, 1.0), 5.0)
        canvasZoomScale = clamped
        canvasZoomCommandScale = clamped
        canvasZoomCommandToken += 1
    }

    func zoomIn() {
        setZoomScale((canvasZoomScale * 2.0).rounded() / 2.0 + 0.5)
    }

    func zoomOut() {
        setZoomScale((canvasZoomScale * 2.0).rounded() / 2.0 - 0.5)
    }

    func toggleVideoFitMode() {
        videoFitMode = (videoFitMode == .fit) ? .fill : .fit
        videoRenderer.setVideoFitMode(videoFitMode)
    }

    func requestOrientation(landscape: Bool, lockForE2E: Bool = false) {
        let targetMask: UIInterfaceOrientationMask = landscape ? .landscapeRight : .portrait
        OpenUUAppDelegate.forcedOrientationMask = lockForE2E ? targetMask : nil

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let activeScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        guard let windowScene = activeScene else { return }

        for window in windowScene.windows {
            window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }

        let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: targetMask)
        windowScene.requestGeometryUpdate(preferences) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.appendLog("旋转屏幕请求反馈: \(error.localizedDescription)")
            }
        }
    }

    func updateViewportGeometry(size: CGSize, isImmersiveFullscreen: Bool) {
        let landscapeNow = size.width > size.height
        if isLandscape != landscapeNow {
            isLandscape = landscapeNow
        }
        if var cfg = e2eConfig,
           cfg.landscape,
           isImmersiveFullscreen,
           landscapeNow,
           !cfg.landscapeConfirmedLogged {
            cfg.landscapeConfirmedLogged = true
            e2eConfig = cfg
            writeE2ELog("E2E_IMMERSIVE_LANDSCAPE width=\(Int(size.width)) height=\(Int(size.height))")
        }
    }

    // MARK: - Bridge Event Handlers

    private func handleStatusMessage(_ msg: String) {
        statusMessage = msg
        appendLog(msg)

        if msg.hasPrefix("connected to host:") {
            let hostName = msg
                .replacingOccurrences(of: "connected to host:", with: "")
                .components(separatedBy: " (")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Mac"
            connectingStartedAt = nil
            phase = .connected(hostName.isEmpty ? "Mac" : hostName)
            audioPlayer.setMuted(!remoteAudioEnabled)
            bridge.sendAudioControl(enabled: remoteAudioEnabled, muteHost: muteHostAudio)
            refreshIdentityAndDeviceBook()
            let remoteDevID = identity?.trusted_peers.first?.device_id ?? ""
            if !lastConnectedTarget.isEmpty {
                deviceBook.recordConnectedHost(
                    remoteName: hostName,
                    remoteDeviceID: remoteDevID,
                    target: lastConnectedTarget,
                    port: lastConnectedPort,
                    passwordUsed: lastConnectedPin
                )
            }
            bridge.requestAppList()
            selectedTab = .remote
            if e2eConfig != nil {
                writeE2ELog("E2E_CONNECTED host=\(hostName) raw=\(msg)")
            }
            if autoOpenDesktopOnConnect {
                autoOpenDesktopOnConnect = false
                openFullDesktop()
            }
        } else if msg.hasPrefix("connect failed:") {
            let reason = msg.replacingOccurrences(of: "connect failed:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            resetSessionState()
            connectingStartedAt = nil
            phase = .error(reason)
            if e2eConfig != nil {
                writeE2ELog("E2E_CONNECT_FAILED reason=\(reason)")
            }
        } else if msg.contains("disconnected") {
            resetSessionState()
            connectingStartedAt = nil
            phase = .idle
            if e2eConfig != nil {
                writeE2ELog("E2E_DISCONNECTED raw=\(msg)")
            }
        } else if phase.isConnecting {
            phase = .connecting(msg)
        }
    }

    private func handleControlEvent(_ evt: ControlEventMessage) {
        switch evt.type {
        case "link_quality":
            let mode = evt.link_mode ?? "lan"
            let rtt = evt.rtt_ms ?? 0
            linkRttMs = rtt
            videoRenderer.setWanJitterMode(mode != "lan")
            let label: String
            switch mode {
            case "lan": label = "LAN 直连"
            case "wan_direct": label = "P2P 直连"
            case "wan_relay": label = "中继"
            default: label = mode
            }
            linkBadge = rtt > 0 ? "\(label) · \(rtt)ms" : label

        case "list_apps_resp":
            let apps = evt.apps ?? []
            remoteApps = apps
            decodeAppIcons(apps)
            if e2eConfig != nil {
                writeE2ELog("E2E_LIST_APPS_RESP list_apps_resp count=\(apps.count)")
                if var cfg = e2eConfig, !cfg.openedApp {
                    let targetBundle = cfg.appBundleID.isEmpty
                        ? (cfg.autoTest ? "com.tencent.xinWeChat" : "")
                        : cfg.appBundleID
                    if !targetBundle.isEmpty {
                        cfg.openedApp = true
                        e2eConfig = cfg
                        selectedTab = .remote
                        writeE2ELog("E2E_OPENING_APP bundle_id=\(targetBundle)")
                        openRemoteApp(bundleID: targetBundle, appName: targetBundle)
                    }
                }
            }

        case "window_topology":
            handleWindowTopology(evt.windows ?? [])

        case "cursor":
            if let kind = evt.kind, !kind.isEmpty {
                cursorKind = kind
            }

        case "clipboard_sync":
            let hash = evt.content_hash ?? ""
            guard hash.isEmpty || hash != lastSyncedClipHash else { return }
            let clipKind = evt.clip_kind ?? 0
            if clipKind == 0, let text = evt.text, !text.isEmpty {
                lastSyncedClipHash = hash.isEmpty ? sha256Hex(Data(text.utf8)) : hash
                UIPasteboard.general.string = text
                appendLog("已接收 Mac 剪贴板文本 (\(text.count) 字)")
            } else if clipKind == 1, let b64 = evt.image_b64,
                      let imgData = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                      let image = UIImage(data: imgData) {
                lastSyncedClipHash = hash.isEmpty ? sha256Hex(imgData) : hash
                UIPasteboard.general.image = image
                appendLog("已接收 Mac 剪贴板图片 (\(imgData.count / 1024) KB)")
            }

        case "notification":
            let bid = evt.app_bundle_id ?? ""
            let fallbackTitle = remoteApps.first(where: { $0.bundle_id == bid })?.name ?? bid
            let banner = RemoteNotificationBanner(
                appBundleID: bid,
                title: (evt.title?.isEmpty == false ? evt.title! : fallbackTitle),
                subtitle: evt.subtitle ?? "",
                body: evt.body ?? ""
            )
            notificationBanner = banner
            bannerDismissTask?.cancel()
            bannerDismissTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(3200))
                if !Task.isCancelled, self?.notificationBanner?.id == banner.id {
                    self?.notificationBanner = nil
                }
            }

        case "badge_update":
            if let bid = evt.app_bundle_id, let badge = evt.badge_text {
                appendLog("角标更新: \(bid) -> \(badge)")
            }

        case "file_drop":
            if let path = evt.local_path, !path.isEmpty {
                appendLog("收到远程文件: \(path)")
            }

        default:
            break
        }
    }

    private func handleWindowTopology(_ windows: [WindowTopologyItem]) {
        remoteWindows = windows
        if e2eConfig != nil {
            let ids = windows.map { String($0.window_id) }.joined(separator: ",")
            writeE2ELog("E2E_WINDOW_TOPOLOGY window_topology ids=\(ids)")
        }

        let normals = windows.filter { $0.kind != 2 }
        let newlyOpened = normals.filter { !knownNormalWindowIDs.contains($0.window_id) }
        let hadPrior = hadPriorTopology && !knownNormalWindowIDs.isEmpty

        knownNormalWindowIDs = Set(normals.map(\.window_id))
        if !normals.isEmpty {
            hadPriorTopology = true
        }

        let curSelected = selectedWindowID
        if hadPrior, let targetNew = newlyOpened.last {
            userPausedAtLauncherBox.value = false
            if curSelected != 0 && curSelected != targetNew.window_id && normals.contains(where: { $0.window_id == curSelected }) {
                windowHistory.removeAll { $0 == curSelected }
                windowHistory.append(curSelected)
            }
            selectWindow(targetNew.window_id)
            showWindowSwitchNotice("新窗口 · \(targetNew.displayTitle)")
            proactiveTabRevealTick += 1
        } else if !normals.isEmpty && ((curSelected == 0 && !userPausedAtLauncherBox.value) || (curSelected != 0 && !normals.contains(where: { $0.window_id == curSelected }))) {
            var fallback: WindowTopologyItem?
            while let prevID = windowHistory.popLast() {
                if let match = normals.first(where: { $0.window_id == prevID }) {
                    fallback = match
                    break
                }
            }
            let chosen = fallback ?? normals.first(where: { $0.kind == 0 }) ?? normals[0]
            selectWindow(chosen.window_id)
        } else if normals.isEmpty && curSelected != 0 {
            userPausedAtLauncherBox.value = false
            activeWindowIDBox.value = 0
            selectedWindowID = 0
            showAppLauncher = true
            videoRenderer.resetStream(resetDecodedCounter: true)
        }

        recomputeWindowBuckets(allWindows: windows, selectedID: selectedWindowID)
    }

    private func showWindowSwitchNotice(_ text: String) {
        windowSwitchNotice = text
        windowNoticeTask?.cancel()
        windowNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2400))
            if !Task.isCancelled {
                self?.windowSwitchNotice = nil
            }
        }
    }

    private func decodeAppIcons(_ apps: [RemoteAppSummary]) {
        let existing = Set(appIcons.keys)
        let pending: [(String, String)] = apps.compactMap { app in
            guard !existing.contains(app.bundle_id),
                  let b64 = app.icon_png_b64, !b64.isEmpty else { return nil }
            return (app.bundle_id, b64)
        }
        guard !pending.isEmpty else { return }

        Task.detached(priority: .utility) {
            var decoded: [(String, UIImage)] = []
            for (bid, b64) in pending {
                if let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                   let img = UIImage(data: raw) {
                    decoded.append((bid, img))
                }
            }
            guard !decoded.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                for (bid, img) in decoded {
                    self.appIcons[bid] = img
                }
            }
        }
    }

    // MARK: - Automated E2E Test Harness

    private func checkAndStartE2EIfConfigured() {
        let env = ProcessInfo.processInfo.environment
        let args = CommandLine.arguments

        func argValue(_ flag: String) -> String? {
            for (idx, arg) in args.enumerated() {
                if arg == flag, idx + 1 < args.count { return args[idx + 1] }
                if arg.hasPrefix(flag + "=") { return String(arg.dropFirst(flag.count + 1)) }
            }
            return nil
        }

        func boolFlag(_ flag: String, envKey: String) -> Bool {
            if let val = argValue(flag) {
                let low = val.lowercased()
                return low == "1" || low == "true" || low == "yes"
            }
            if args.contains(flag) { return true }
            if let raw = env[envKey] {
                let low = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return low == "1" || low == "true" || low == "yes"
            }
            return false
        }

        let target = (argValue("--e2e-target") ?? env["OPENUU_E2E_TARGET"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return }

        let pin = (argValue("--e2e-pin") ?? env["OPENUU_E2E_PIN"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let appBundle = (argValue("--e2e-app") ?? env["OPENUU_E2E_APP"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let autoTest = boolFlag("--e2e-autotest", envKey: "OPENUU_E2E_AUTOTEST")
        let landscape = boolFlag("--e2e-landscape", envKey: "OPENUU_E2E_LANDSCAPE")

        try? "".write(to: e2eLogURL, atomically: true, encoding: .utf8)
        e2eConfig = E2EConfig(target: target, pin: pin, appBundleID: appBundle, autoTest: autoTest, landscape: landscape)
        showDebugHUD = true
        selectedTab = .remote
        targetInput = target
        pinInput = pin

        writeE2ELog("E2E_START target=\(target) app=\(appBundle) autotest=\(autoTest) landscape=\(landscape) log=\(e2eLogURL.path)")
        connectSmart(target: target, port: OpenUUConstants.defaultPort, pin: pin)
    }

    private func handleDecodedFramesProgress(_ telemetry: VideoStreamTelemetry) {
        guard var cfg = e2eConfig, telemetry.decodedFrames >= 5 else { return }

        if !cfg.decodedMilestoneLogged {
            cfg.decodedMilestoneLogged = true
            e2eConfig = cfg
            writeE2ELog("E2E_DECODED decoded_frames=\(telemetry.decodedFrames) codec=\(telemetry.codecName) fps=\(telemetry.fps) size=\(telemetry.encodedWidth)x\(telemetry.encodedHeight)")
        }

        if cfg.landscape && !cfg.landscapeRequested && !cfg.autoTest {
            cfg.landscapeRequested = true
            e2eConfig = cfg
            writeE2ELog("E2E_LANDSCAPE_REQUESTED")
            requestOrientation(landscape: true, lockForE2E: true)
        }

        guard cfg.autoTest && !cfg.autoTestSent else { return }
        cfg.autoTestSent = true
        e2eConfig = cfg

        let framesAtTrigger = telemetry.decodedFrames
        let winID = activeWindowIDBox.value
        let shouldRotateLandscape = cfg.landscape
        writeE2ELog("E2E_DISPATCHING_AUTOTEST win_id=\(winID) decoded_frames=\(framesAtTrigger)")

        Task { [weak self] in
            guard let self else { return }
            self.sendMouseLogical(x: 480, y: 300, type: 0, button: 0, clickCount: 0, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(30))
            self.sendMouseLogical(x: 480, y: 300, type: 1, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(30))
            self.sendMouseLogical(x: 480, y: 300, type: 2, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(40))

            self.sendMouseLogical(x: 320, y: 240, type: 0, button: 0, clickCount: 0, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(20))
            self.sendMouseLogical(x: 320, y: 240, type: 1, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(25))
            self.sendMouseLogical(x: 380, y: 265, type: 3, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(25))
            self.sendMouseLogical(x: 440, y: 290, type: 3, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(25))
            self.sendMouseLogical(x: 440, y: 290, type: 2, button: 0, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(40))

            self.sendMouseLogical(x: 520, y: 310, type: 0, button: 1, clickCount: 0, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(20))
            self.sendMouseLogical(x: 520, y: 310, type: 1, button: 1, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(25))
            self.sendMouseLogical(x: 520, y: 310, type: 2, button: 1, clickCount: 1, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(40))

            self.sendScrollLogical(x: 480, y: 300, deltaX: 0, deltaY: -120, isContinuous: true, modifiers: 0)
            try? await Task.sleep(for: .milliseconds(40))
            self.sendTextCommit("你好，OpenUU iOS 端！")
            try? await Task.sleep(for: .milliseconds(40))
            self.sendKeyTap(keyCode: MacKeyCodes.c, explicitModifiers: MacModifiers.command)
            try? await Task.sleep(for: .milliseconds(40))

            self.lastSyncedClipHash = "ios-e2e-clip-1"
            self.bridge.sendClipboardText(hash: "ios-e2e-clip-1", text: "Hello from iOS E2E")

            let finalFrames = max(framesAtTrigger, self.videoTelemetry.decodedFrames)
            self.writeE2ELog("E2E_ALL_SENT decoded_frames=\(finalFrames)")

            if shouldRotateLandscape {
                try? await Task.sleep(for: .milliseconds(400))
                self.e2eConfig?.landscapeRequested = true
                self.writeE2ELog("E2E_LANDSCAPE_REQUESTED")
                self.requestOrientation(landscape: true, lockForE2E: true)
            }
        }
    }

    private func writeE2ELog(_ line: String) {
        let formatted = "[OpenUUE2E] \(line)"
        print(formatted)
        fflush(stdout)
        appendLog(formatted)

        let payload = (formatted + "\n").data(using: .utf8) ?? Data()
        if FileManager.default.fileExists(atPath: e2eLogURL.path),
           let handle = try? FileHandle(forWritingTo: e2eLogURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: e2eLogURL, options: .atomic)
        }
    }

    // MARK: - Helpers

    func appendLog(_ line: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        let entry = "[\(df.string(from: Date()))] \(line)"
        logs.append(entry)
        if logs.count > Self.maxLogs {
            logs.removeFirst(logs.count - Self.maxLogs)
        }
    }

    private func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

import AppKit
import SwiftUI

enum SidebarTab: String, CaseIterable, Identifiable {
    case remoteHome = "remote"
    case deviceList = "devices"
    case securityQuality = "security"
    case networkLogs = "network"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remoteHome: return "远程控制"
        case .deviceList: return "设备列表"
        case .securityQuality: return "安全与画质"
        case .networkLogs: return "网络与日志"
        }
    }

    var icon: String {
        switch self {
        case .remoteHome: return "desktopcomputer.and.arrow.down"
        case .deviceList: return "laptopcomputer.and.iphone"
        case .securityQuality: return "shield.lefthalf.filled"
        case .networkLogs: return "antenna.radiowaves.left.and.right"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    // Host & Discovery bridges
    let hostBridge = OpenUUBridge()
    let probeBridge = OpenUUBridge()
    let captureManager = MultiWindowCaptureManager()
    let inputInjector = InputInjector()
    let sleepPreventer = SleepPreventer()
    let dockProxyManager = DockProxyManager()
    let virtualDisplayManager = VirtualDisplayManager()
    let clipboardSync = ClipboardSyncManager()
    let notificationMonitor = NotificationBadgeMonitor()
    let clientNotificationManager = ClientNotificationManager()

    // Multi-Host Device Book & Concurrent Sessions
    let deviceBook = DeviceBookStore()
    @Published var sessions: [String: RemotePeerSession] = [:]
    @Published var activeSessionOrder: [String] = []
    @Published var selectedSessionID: String?
    private var nextSessionIndex: Int = 0

    // Host incoming file-drop batching
    private var pendingDroppedFiles: [UInt32: [URL]] = [:]
    private var pendingDropTasks: [UInt32: Task<Void, Never>] = [:]

    private enum PrefKey {
        static let manualHostIP = "openuu.client.lastHostIP"
        static let manualHostPort = "openuu.client.lastHostPort"
        static let clientPIN = "openuu.client.lastPIN"
        static let hostPIN = "openuu.host.savedPIN"
        static let silentClick = "openuu.host.silentClickMode"
        static let hoverCursor = "openuu.host.hoverCursorSync"
        static let preventSleep = "openuu.host.preventDisplaySleep"
        static let captureScheme = "openuu.host.captureScheme"
        static let clipboardSync = "openuu.shared.clipboardSync"
        static let notificationSync = "openuu.shared.notificationSync"
        static let dynamicRes = "openuu.host.dynamicResolutionBoost"
        static let targetFPS = "openuu.host.targetFPS"
        static let debugHUD = "openuu.client.showDebugHUD"
    }

    enum CaptureScheme: String, CaseIterable, Identifiable {
        case mainScreen = "main"
        case virtualDisplay = "virtual"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mainScreen: return "方案A：主屏模式（OBS防裁剪 + 出屏自动拉入）"
            case .virtualDisplay: return "方案C：虚拟副屏隔离（后台无感不打扰主屏）"
            }
        }
    }

    // Navigation & UI state
    @Published var selectedTab: SidebarTab = .remoteHome
    @Published var statusLog: String = "就绪" {
        didSet {
            if statusLog != oldValue {
                OpenUULogger.shared.debug("UI", statusLog)
            }
        }
    }
    @Published var logEntries: [OpenUULogEntry] = []
    @Published var selectedLogLevel: OpenUULogLevel = .debug

    // Host state
    @Published var isHostRunning = false
    @Published var activeStreamCount: Int = 0
    @Published var hostPort: UInt16 = 39481
    @Published var hostPIN: String = UserDefaults.standard.string(forKey: PrefKey.hostPIN) ?? String(format: "%06d", Int.random(in: 0...999999)) {
        didSet { UserDefaults.standard.set(hostPIN, forKey: PrefKey.hostPIN) }
    }
    @Published var isHostPasswordRevealed: Bool = true
    @Published var silentClickMode: Bool = UserDefaults.standard.object(forKey: PrefKey.silentClick) as? Bool ?? true {
        didSet {
            inputInjector.silentMode = silentClickMode
            UserDefaults.standard.set(silentClickMode, forKey: PrefKey.silentClick)
        }
    }
    @Published var hoverCursorSync: Bool = UserDefaults.standard.object(forKey: PrefKey.hoverCursor) as? Bool ?? true {
        didSet {
            inputInjector.hoverCursorSync = hoverCursorSync
            UserDefaults.standard.set(hoverCursorSync, forKey: PrefKey.hoverCursor)
        }
    }
    @Published var preventDisplaySleep: Bool = UserDefaults.standard.object(forKey: PrefKey.preventSleep) as? Bool ?? true {
        didSet {
            sleepPreventer.setEnabled(preventDisplaySleep)
            UserDefaults.standard.set(preventDisplaySleep, forKey: PrefKey.preventSleep)
        }
    }
    @Published var dynamicResolutionBoost: Bool = UserDefaults.standard.object(forKey: PrefKey.dynamicRes) as? Bool ?? true {
        didSet {
            captureManager.dynamicResolutionEnabled = dynamicResolutionBoost
            UserDefaults.standard.set(dynamicResolutionBoost, forKey: PrefKey.dynamicRes)
        }
    }
    @Published var targetFPS: Int = {
        let saved = UserDefaults.standard.integer(forKey: PrefKey.targetFPS)
        return [30, 45, 60].contains(saved) ? saved : 45
    }() {
        didSet {
            captureManager.targetFPS = targetFPS
            UserDefaults.standard.set(targetFPS, forKey: PrefKey.targetFPS)
        }
    }
    @Published var showDebugHUD: Bool = UserDefaults.standard.object(forKey: PrefKey.debugHUD) as? Bool ?? false {
        didSet {
            UserDefaults.standard.set(showDebugHUD, forKey: PrefKey.debugHUD)
            for sess in sessions.values {
                sess.showDebugHUD = showDebugHUD
            }
        }
    }
    @Published var clipboardSyncEnabled: Bool = UserDefaults.standard.object(forKey: PrefKey.clipboardSync) as? Bool ?? true {
        didSet {
            clipboardSync.isEnabled = clipboardSyncEnabled
            UserDefaults.standard.set(clipboardSyncEnabled, forKey: PrefKey.clipboardSync)
        }
    }
    @Published var notificationSyncEnabled: Bool = UserDefaults.standard.object(forKey: PrefKey.notificationSync) as? Bool ?? true {
        didSet {
            notificationMonitor.setEnabled(notificationSyncEnabled)
            clientNotificationManager.isEnabled = notificationSyncEnabled
            UserDefaults.standard.set(notificationSyncEnabled, forKey: PrefKey.notificationSync)
        }
    }
    @Published var captureScheme: CaptureScheme = CaptureScheme(rawValue: UserDefaults.standard.string(forKey: PrefKey.captureScheme) ?? "main") ?? .mainScreen {
        didSet {
            UserDefaults.standard.set(captureScheme.rawValue, forKey: PrefKey.captureScheme)
            applyCaptureScheme()
        }
    }
    @Published var hasAccessibilityPermission: Bool = InputInjector.hasAccessibilityPermission(prompt: false)
    @Published var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published var hasDirectCapturePermission: Bool = false
    @Published var showingPermissionGuideSheet: Bool = false
    @Published var pendingStartHostAfterPermission: Bool = false
    @Published var permissionCheckFeedback: String = ""

    var hasEffectiveScreenRecordingPermission: Bool {
        hasScreenRecordingPermission || hasDirectCapturePermission
    }

    var hasAllHostPermissions: Bool {
        hasEffectiveScreenRecordingPermission && hasAccessibilityPermission
    }

    var missingHostPermissionSummary: String {
        switch (hasEffectiveScreenRecordingPermission, hasAccessibilityPermission) {
        case (true, true): return ""
        case (false, false): return "缺少屏幕录制与辅助功能权限"
        case (false, true): return "缺少屏幕录制权限"
        case (true, false): return "缺少辅助功能权限"
        }
    }

    // Quick-connect fields on Home tab
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var quickConnectTarget: String = DeviceCodeFormatter.formatInput(
        UserDefaults.standard.string(forKey: PrefKey.manualHostIP) ?? ""
    ) {
        didSet {
            UserDefaults.standard.set(
                DeviceCodeFormatter.sanitizeForUse(quickConnectTarget),
                forKey: PrefKey.manualHostIP
            )
            // Only auto-fill saved password when the password field is currently empty,
            // never overwriting a fresh password just typed/pasted by the user!
            if quickConnectPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let matched = deviceBook.findMatchingDevice(forTarget: quickConnectTarget),
               !matched.savedPassword.isEmpty {
                quickConnectPassword = matched.savedPassword
            }
        }
    }
    @Published var quickConnectPort: String = UserDefaults.standard.string(forKey: PrefKey.manualHostPort) ?? "39481" {
        didSet { UserDefaults.standard.set(quickConnectPort, forKey: PrefKey.manualHostPort) }
    }
    @Published var quickConnectPassword: String = UserDefaults.standard.string(forKey: PrefKey.clientPIN) ?? "" {
        didSet { UserDefaults.standard.set(quickConnectPassword, forKey: PrefKey.clientPIN) }
    }

    // Identity & WAN Config state
    @Published var myFormattedDeviceCode: String = "--- --- ---"
    @Published var myRawDeviceCode: String = ""
    @Published var myHostTicket: String = ""
    @Published var coordStatusText: String = "未开启被控监听"
    @Published var trustedPeers: [TrustedPeerModel] = []
    static let defaultRelayToken = "openuu-public-relay-fair-use"

    @Published var wanCoordURL: String = "https://openuu.1kb.ren"
    @Published var wanRelayURL: String = "https://openuu-relay.1kb.ren"
    @Published var wanRelayAuthToken: String = AppState.defaultRelayToken
    @Published var wanEnablePublicFallback: Bool = true
    @Published var wanAllowInsecureTLS: Bool = false
    @Published var hostLinkBadge: String = ""

    private var discoveryTimer: Timer?
    private var presenceTickCounter: Int = 0

    var connectedSessions: [RemotePeerSession] {
        activeSessionOrder.compactMap { id in
            guard let s = sessions[id], s.phase.isConnected || s.phase.isConnecting else { return nil }
            return s
        }
    }

    var connectedHostCount: Int {
        sessions.values.filter { $0.phase.isConnected }.count
    }

    var totalOpenRemoteWindows: Int {
        sessions.values.reduce(0) { $0 + $1.openWindowCount }
    }

    init() {
        UserDefaults.standard.set(hostPIN, forKey: PrefKey.hostPIN)

        OpenUULogger.shared.onEntryAppended = { [weak self] entry in
            guard let self else { return }
            self.logEntries.append(entry)
            if self.logEntries.count > 400 {
                self.logEntries.removeFirst(self.logEntries.count - 400)
            }
        }
        OpenUULogger.shared.info("APP", "launched version=v0.4.0 multiHost=true scheme=\(captureScheme.rawValue) fps=\(targetFPS)")

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hostBridge.stopHost()
                for s in self.sessions.values {
                    s.disconnect()
                }
                self.virtualDisplayManager.returnAllWindowsToMainDisplay()
                self.dockProxyManager.terminateAll()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshPermission()
                if self.showingPermissionGuideSheet {
                    await self.pollPermissionsInGuideSheet(checkScreenCaptureKit: true)
                }
            }
        }

        probeBridge.onProbeResults = { [weak self] results in
            Task { @MainActor [weak self] in
                self?.deviceBook.applyProbeResults(results)
            }
        }

        setupHostCallbacks()
        setupSharedManagers()
    }

    private func setupHostCallbacks() {
        hostBridge.onStatus = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.statusLog = "[被控端] \(msg)"
                if msg.hasPrefix("client connected:") {
                    self.refreshIdentitySnapshot()
                    self.clipboardSync.start()
                    await self.pushHostAppListToClient()
                    self.notificationMonitor.start()
                    self.captureManager.requestAllKeyframes()
                } else if msg.contains("disconnected") {
                    self.hostLinkBadge = ""
                    self.captureManager.networkTier = .lan
                    self.notificationMonitor.stop()
                    if self.connectedHostCount == 0 {
                        self.clipboardSync.stop()
                    }
                    await self.stopAllHostStreams()
                }
            }
        }

        hostBridge.onControlEvent = { [weak self] evt in
            guard let self else { return }
            switch evt.type {
            case "link_quality":
                let modeRaw = evt.link_mode ?? "lan"
                let rtt = evt.rtt_ms ?? 0
                let tier = StreamNetworkTier(rawValue: modeRaw) ?? .lan
                Task { @MainActor in
                    self.captureManager.networkTier = tier
                    self.hostLinkBadge = rtt > 0 ? "\(tier.label) · \(rtt)ms" : tier.label
                }
            case "list_apps_req":
                Task { @MainActor in
                    await self.pushHostAppListToClient()
                }
            case "start_session":
                let bid = evt.bundle_id ?? ""
                Task { @MainActor in
                    self.captureManager.isRelocationPaused = false
                    if self.captureScheme == .virtualDisplay {
                        self.inputInjector.setVirtualDisplayID(self.virtualDisplayManager.displayID)
                    }
                    await self.captureManager.addSharedApp(bundleID: bid)
                }
            case "stop_session":
                if let winID = evt.window_id {
                    Task { @MainActor in
                        await self.captureManager.stopWindow(windowID: winID)
                    }
                }
            case "request_keyframe":
                Task { @MainActor in
                    self.captureManager.requestAllKeyframes()
                }
            case "clipboard_sync":
                Task { @MainActor in
                    self.clipboardSync.applyRemoteClipboard(
                        hash: evt.content_hash ?? "",
                        clipKind: evt.clip_kind ?? 0,
                        text: evt.text,
                        mimeType: evt.mime_type,
                        imageBase64: evt.image_b64
                    )
                }
            case "file_drop":
                if let winID = evt.window_id, let path = evt.local_path, !path.isEmpty {
                    let url = URL(fileURLWithPath: path)
                    Task { @MainActor in
                        if winID == 0 {
                            self.enqueueClipboardFile(url)
                        } else {
                            self.enqueueDroppedFileForPaste(windowID: winID, fileURL: url)
                        }
                    }
                }
            default:
                self.inputInjector.handleControlEvent(evt)
            }
        }
    }

    private func setupSharedManagers() {
        let hBridge = hostBridge
        captureManager.onEncodedFrame = { codec, flags, winID, pts, w, h, data in
            hBridge.sendVideoFrame(
                codec: codec,
                flags: flags,
                windowID: winID,
                timestampUS: pts,
                width: w,
                height: h,
                data: data
            )
        }
        captureManager.onTopologyChanged = { [weak self] items in
            self?.activeStreamCount = items.count
            self?.hostBridge.sendWindowTopology(items)
        }
        captureManager.virtualDisplayManager = virtualDisplayManager
        captureManager.useVirtualDisplayMode = (captureScheme == .virtualDisplay)
        captureManager.dynamicResolutionEnabled = dynamicResolutionBoost
        captureManager.targetFPS = targetFPS
        virtualDisplayManager.onDisplayIDChanged = { [weak self] displayID in
            self?.inputInjector.setVirtualDisplayID(displayID)
        }
        captureManager.onStatus = { [weak self] msg in
            self?.statusLog = "[被控端] \(msg)"
        }
        captureManager.onWindowContentInset = { [weak self] winID, inset in
            self?.inputInjector.setContentInset(for: winID, inset: inset)
        }

        inputInjector.silentMode = silentClickMode
        inputInjector.hoverCursorSync = hoverCursorSync
        sleepPreventer.setEnabled(preventDisplaySleep)

        // Multi-host clipboard broadcast (local -> Host client + ALL connected remote Macs!)
        clipboardSync.isEnabled = clipboardSyncEnabled
        clipboardSync.onSendText = { [weak self] hash, text in
            guard let self else { return }
            if self.isHostRunning {
                self.hostBridge.sendClipboardText(hash: hash, text: text)
            }
            for sess in self.sessions.values where sess.phase.isConnected {
                sess.bridge.sendClipboardText(hash: hash, text: text)
            }
        }
        clipboardSync.onSendImage = { [weak self] hash, mime, data in
            guard let self else { return }
            if self.isHostRunning {
                self.hostBridge.sendClipboardImage(hash: hash, mimeType: mime, data: data)
            }
            for sess in self.sessions.values where sess.phase.isConnected {
                sess.bridge.sendClipboardImage(hash: hash, mimeType: mime, data: data)
            }
        }
        clipboardSync.onSendFiles = { [weak self] urls in
            guard let self else { return }
            for url in urls {
                if self.isHostRunning {
                    self.hostBridge.sendFileBlob(windowID: 0, x: 0, y: 0, fileURL: url)
                }
                for sess in self.sessions.values where sess.phase.isConnected {
                    sess.bridge.sendFileBlob(windowID: 0, x: 0, y: 0, fileURL: url)
                }
            }
            self.statusLog = "[剪贴板] 正在向已连接设备同步 \(urls.count) 个文件..."
        }
        clipboardSync.onStatusLog = { [weak self] msg in
            self?.statusLog = "[剪贴板] \(msg)"
        }

        notificationMonitor.setEnabled(notificationSyncEnabled)
        clientNotificationManager.isEnabled = notificationSyncEnabled
        notificationMonitor.onNotification = { [weak self] bid, title, subtitle, body in
            self?.hostBridge.sendNotification(bundleID: bid, title: title, subtitle: subtitle, body: body)
        }
        notificationMonitor.onBadgeChanged = { [weak self] bid, badgeText in
            self?.hostBridge.sendBadgeUpdate(bundleID: bid, badgeText: badgeText)
        }
        clientNotificationManager.onNotificationClicked = { [weak self] compositeBid in
            guard let self else { return }
            self.handleDockOrNotificationFocus(compositeKey: compositeBid)
        }

        inputInjector.onDebugLog = { [weak self] msg in
            Task { @MainActor in
                self?.statusLog = "[输入] \(msg)"
            }
        }
        inputInjector.onCursorKindChanged = { [weak self] kind in
            self?.hostBridge.sendCursorUpdate(kind: kind)
        }
        inputInjector.onWindowResized = { [weak self] winID in
            Task { @MainActor in
                self?.captureManager.notifyWindowResized(windowID: winID)
            }
        }
        inputInjector.onNormalWindowInteracted = { [weak self] winID in
            Task { @MainActor in
                self?.captureManager.notifyNormalWindowInteracted(windowID: winID)
            }
        }
        inputInjector.onDragOutFilesDetected = { [weak self] urls in
            Task { @MainActor [weak self] in
                guard let self, self.isHostRunning else { return }
                for url in urls {
                    self.hostBridge.sendFileBlob(windowID: 0xFFFF_FFFE, x: 0, y: 0, fileURL: url)
                }
                self.statusLog = "[被控端] 检测到拖出 \(urls.count) 个文件，正在传给控制端..."
            }
        }

        // Route Dock proxy click / close to the exact RemotePeerSession (`"<sessionID>::<subKey>"`)
        dockProxyManager.onFocusAppRequested = { [weak self] dockKey in
            self?.handleDockOrNotificationFocus(compositeKey: dockKey)
        }
        dockProxyManager.onCloseAppRequested = { [weak self] dockKey in
            self?.handleDockClose(compositeKey: dockKey)
        }
    }

    // MARK: - Multi-Host Session Orchestration

    func currentWanConfigModel() -> WanConfigModel {
        WanConfigModel(
            coord_url: wanCoordURL.trimmingCharacters(in: .whitespacesAndNewlines),
            relay_url: wanRelayURL.trimmingCharacters(in: .whitespacesAndNewlines),
            relay_auth_token: wanRelayAuthToken.trimmingCharacters(in: .whitespacesAndNewlines),
            enable_public_fallback: wanEnablePublicFallback,
            allow_insecure_tls: wanAllowInsecureTLS
        )
    }

    /// Connect to a saved device from the Device Book WITHOUT disconnecting any other active remote Macs!
    func connectDevice(_ device: ManagedRemoteDevice, autoOpenDesktop: Bool = false) {
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(device.target)
        let sess = ensureSession(for: device)
        sess.alias = device.alias
        sess.target = cleanTarget
        sess.port = device.port
        sess.bridge.setWanConfig(currentWanConfigModel())
        selectedSessionID = sess.id
        let typedQuickPW = quickConnectPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let sameAsQuickTarget = deviceBook.findMatchingDevice(forTarget: quickConnectTarget)?.id == device.id
        let password: String
        if sameAsQuickTarget && !typedQuickPW.isEmpty && typedQuickPW != device.savedPassword {
            password = typedQuickPW
            _ = deviceBook.addOrUpdateDevice(
                id: device.id,
                alias: device.alias,
                target: cleanTarget,
                port: device.port,
                savedPassword: password,
                groupTag: device.groupTag,
                isFavorite: device.isFavorite,
                notes: device.notes
            )
        } else {
            password = device.savedPassword.isEmpty ? typedQuickPW : device.savedPassword
        }
        sess.connect(password: password, autoOpenDesktop: autoOpenDesktop)
    }

    /// Quick-connect from the Home screen (`远程控制` tab). Automatically enrolls into Device Book on success!
    func connectFromQuickInput(autoOpenDesktop: Bool = false) {
        let rawTarget = DeviceCodeFormatter.sanitizeForUse(quickConnectTarget)
        guard !rawTarget.isEmpty else {
            statusLog = "请输入伙伴 9 位设备代码、openuu:// 连接串或 IP/域名"
            return
        }
        let port = UInt16(quickConnectPort) ?? 39481
        let matched = deviceBook.findMatchingDevice(forTarget: rawTarget)
        let typedPW = quickConnectPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = !typedPW.isEmpty ? typedPW : (matched?.savedPassword ?? "")

        let device = deviceBook.addOrUpdateDevice(
            id: matched?.id,
            alias: matched?.alias ?? "",
            target: rawTarget,
            port: port,
            savedPassword: password,
            groupTag: matched?.groupTag ?? "常用",
            isFavorite: matched?.isFavorite ?? false,
            notes: matched?.notes ?? ""
        )
        let sess = ensureSession(for: device)
        sess.target = rawTarget
        sess.port = port
        sess.bridge.setWanConfig(currentWanConfigModel())
        selectedSessionID = sess.id
        sess.connect(password: password, autoOpenDesktop: autoOpenDesktop)
    }

    /// Connect directly to a LAN-discovered peer in 1 click.
    func connectDiscoveredPeer(_ peer: DiscoveredPeer, autoOpenDesktop: Bool = false) {
        let target = peer.preferredIP
        quickConnectTarget = target
        quickConnectPort = "\(peer.port)"
        let matched = deviceBook.devices.first {
            $0.remoteDeviceID == peer.device_id || $0.target == target
        }
        let pw = matched?.savedPassword.isEmpty == false ? matched!.savedPassword : quickConnectPassword
        let dev = deviceBook.addOrUpdateDevice(
            id: matched?.id,
            alias: matched?.alias ?? peer.device_name,
            target: target,
            port: peer.port,
            savedPassword: pw
        )
        connectDevice(dev, autoOpenDesktop: autoOpenDesktop)
    }

    func disconnectSession(id: String) {
        guard let sess = sessions[id] else { return }
        sess.disconnect()
        if selectedSessionID == id {
            selectedSessionID = connectedSessions.first?.id
        }
        if connectedHostCount == 0 && !isHostRunning {
            clipboardSync.stop()
        }
        objectWillChange.send()
    }

    func disconnectAllClientSessions() {
        for sess in sessions.values where sess.phase.isConnected || sess.phase.isConnecting {
            sess.disconnect()
        }
        selectedSessionID = nil
        if !isHostRunning {
            clipboardSync.stop()
        }
        statusLog = "已断开所有远程控制连接"
        objectWillChange.send()
    }

    func deleteManagedDevice(_ device: ManagedRemoteDevice) {
        if let sess = sessions.removeValue(forKey: device.id) {
            sess.disconnect()
        }
        activeSessionOrder.removeAll { $0 == device.id }
        if !device.remoteDeviceID.isEmpty {
            hostBridge.removeTrustedPeer(deviceID: device.remoteDeviceID)
            probeBridge.removeTrustedPeer(deviceID: device.remoteDeviceID)
        }
        deviceBook.removeDevice(id: device.id)
        if selectedSessionID == device.id {
            selectedSessionID = connectedSessions.first?.id
        }
        statusLog = "已从设备列表删除: \(device.alias)"
    }

    private func ensureSession(for device: ManagedRemoteDevice) -> RemotePeerSession {
        if let existing = sessions[device.id] {
            if !activeSessionOrder.contains(device.id) {
                activeSessionOrder.insert(device.id, at: 0)
            }
            return existing
        }
        nextSessionIndex += 1
        let sess = RemotePeerSession(
            id: device.id,
            sessionIndex: nextSessionIndex,
            alias: device.alias,
            target: device.target,
            port: device.port,
            wanConfig: currentWanConfigModel()
        )
        sess.showDebugHUD = showDebugHUD
        sess.onStateMutated = { [weak self] in
            self?.objectWillChange.send()
        }
        sess.onStatusLog = { [weak self] msg in
            self?.statusLog = msg
        }
        sess.onConnected = { [weak self] connectedSess, remoteName, remoteDevID in
            guard let self else { return }
            self.clipboardSync.start()
            self.clientNotificationManager.requestPermissionIfNeeded()
            let saved = self.deviceBook.recordConnectedHost(
                existingID: connectedSess.id,
                remoteName: remoteName,
                remoteDeviceID: remoteDevID,
                target: connectedSess.target,
                port: connectedSess.port,
                passwordUsed: self.quickConnectPassword
            )
            connectedSess.alias = saved.alias
            self.selectedSessionID = connectedSess.id
            self.refreshIdentitySnapshot()
            self.objectWillChange.send()
        }
        sess.onRemoteClipboard = { [weak self] hash, kind, text, mime, imgB64 in
            self?.clipboardSync.applyRemoteClipboard(
                hash: hash,
                clipKind: kind,
                text: text,
                mimeType: mime,
                imageBase64: imgB64
            )
        }
        sess.onRemoteClipboardFile = { [weak self] url in
            self?.enqueueClipboardFile(url)
        }
        sess.onBeforePasteShortcut = { [weak self] in
            self?.clipboardSync.syncNowIfChanged()
        }
        sess.onPresentNotification = { [weak self] srcSess, bid, appTitle, title, subtitle, body, icon in
            guard let self else { return }
            self.clientNotificationManager.presentRemoteNotification(
                bundleID: srcSess.dockKey(for: bid),
                appName: appTitle,
                title: title,
                subtitle: subtitle,
                body: body,
                icon: icon
            )
        }
        sess.onEnsureDockIcon = { [weak self] key, title, icon in
            self?.dockProxyManager.ensureDockIcon(for: key, title: title, compositedIcon: icon)
        }
        sess.onUpdateDockIcon = { [weak self] key, icon in
            self?.dockProxyManager.updateIcon(icon, for: key)
        }
        sess.onUpdateDockTitle = { [weak self] key, title in
            self?.dockProxyManager.updateTitle(title, for: key)
        }
        sess.onUpdateDockBadge = { [weak self] key, badge in
            guard let self, self.notificationSyncEnabled else { return }
            self.dockProxyManager.updateBadge(badge, for: key)
        }
        sess.onRemoveDockIcon = { [weak self] key in
            self?.dockProxyManager.removeDockIcon(for: key)
        }

        sessions[device.id] = sess
        activeSessionOrder.insert(device.id, at: 0)
        return sess
    }

    private func handleDockOrNotificationFocus(compositeKey: String) {
        let parts = compositeKey.components(separatedBy: "::")
        if parts.count == 2, let sess = sessions[parts[0]] {
            let subKey = parts[1]
            if sess.openedBundleIDs.contains(subKey) || subKey.hasPrefix("win-") {
                sess.focusWindows(subKey: subKey)
            } else if let app = sess.remoteApps.first(where: { $0.bundle_id == subKey }) {
                sess.openApp(app)
            }
        }
    }

    private func handleDockClose(compositeKey: String) {
        let parts = compositeKey.components(separatedBy: "::")
        if parts.count == 2, let sess = sessions[parts[0]] {
            sess.closeWindows(subKey: parts[1])
            objectWillChange.send()
        }
    }

    // MARK: - Identity, Presence Probing & Host Control

    func refreshIdentitySnapshot(syncWanFields: Bool = false) {
        guard let snap = hostBridge.getIdentitySnapshot() else { return }
        myFormattedDeviceCode = snap.formatted_code
        myRawDeviceCode = snap.device_code
        myHostTicket = snap.host_ticket
        if isHostRunning {
            coordStatusText = snap.coord_status
        }
        var byID: [String: TrustedPeerModel] = [:]
        for p in snap.trusted_peers {
            byID[p.device_id] = p
        }
        for sess in sessions.values {
            if let sSnap = sess.bridge.getIdentitySnapshot() {
                for p in sSnap.trusted_peers {
                    if let ex = byID[p.device_id] {
                        if p.last_connected_ms >= ex.last_connected_ms {
                            byID[p.device_id] = p
                        }
                    } else {
                        byID[p.device_id] = p
                    }
                }
            }
        }
        let mergedTrusted = byID.values.sorted { $0.last_connected_ms > $1.last_connected_ms }
        trustedPeers = mergedTrusted
        deviceBook.syncFromTrustedPeers(mergedTrusted)

        if syncWanFields {
            wanCoordURL = snap.wan_config.coord_url
            wanRelayURL = snap.wan_config.relay_url
            wanRelayAuthToken = snap.wan_config.relay_auth_token ?? ""
            wanEnablePublicFallback = snap.wan_config.enable_public_fallback
            wanAllowInsecureTLS = snap.wan_config.allow_insecure_tls
        }
    }

    func probeAllSavedDevicesNow() {
        let queries = deviceBook.devices.map { d in
            let matchedTrusted = trustedPeers.first { tp in
                (!d.remoteDeviceID.isEmpty && tp.device_id == d.remoteDeviceID)
                    || (!d.deviceCode.isEmpty && tp.device_code == d.deviceCode)
            }
            return DeviceProbeQueryModel(
                id: d.id,
                target: DeviceCodeFormatter.sanitizeForUse(d.target),
                pin: d.savedPassword,
                endpoint_id: matchedTrusted?.endpoint_id ?? ""
            )
        }
        guard !queries.isEmpty else { return }
        probeBridge.setWanConfig(currentWanConfigModel())
        probeBridge.probeDevicesOnline(queries)
    }

    func saveWanSettings() {
        let cfg = currentWanConfigModel()
        hostBridge.setWanConfig(cfg)
        probeBridge.setWanConfig(cfg)
        for sess in sessions.values {
            sess.bridge.setWanConfig(cfg)
        }
        refreshIdentitySnapshot(syncWanFields: true)
        probeAllSavedDevicesNow()
        statusLog = isHostRunning
            ? "[网络] 已保存跨网配置（重启被控服务后将向新服务器注册本机设备码）"
            : "[网络] 已保存跨网打洞与中继配置"
    }

    func copyMyDeviceCode() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(myFormattedDeviceCode, forType: .string)
        clipboardSync.ignoreCurrentPasteboardChange()
        statusLog = "已复制本机设备代码: \(myFormattedDeviceCode)"
    }

    func copyInvitationBundle() {
        let invite = "【OpenUU 远程协助】\n设备代码：\(myFormattedDeviceCode)\n访问密码：\(hostPIN)"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(invite, forType: .string)
        clipboardSync.ignoreCurrentPasteboardChange()
        statusLog = "已复制本机设备代码与访问密码，可直接发送给伙伴"
    }

    func copyMyHostTicket() {
        refreshIdentitySnapshot()
        guard !myHostTicket.isEmpty else {
            statusLog = "请先开启「允许控制本机」并等待 2 秒生成跨网连接串"
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(myHostTicket, forType: .string)
        clipboardSync.ignoreCurrentPasteboardChange()
        statusLog = "已复制 openuu:// 免寻址跨网连接串"
    }

    func regenerateHostPIN(strong: Bool = false) {
        hostPIN = hostBridge.generateAccessCode(strongAlphanumeric: strong)
    }

    func toggleHostService() {
        if isHostRunning {
            Task { await stopHostService() }
        } else {
            requestStartHost()
        }
    }

    /// Checks required macOS permissions before starting Host mode; if missing, guides the user to System Settings.
    func requestStartHost() {
        hasAccessibilityPermission = InputInjector.hasAccessibilityPermission(prompt: false)
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()

        if hasAllHostPermissions {
            startHost()
            return
        }

        permissionCheckFeedback = ""
        pendingStartHostAfterPermission = true
        showingPermissionGuideSheet = true
        statusLog = "[被控端] \(missingHostPermissionSummary)，请先在系统设置中开启权限"

        // If Screen Recording was just granted in-session and SCShareableContent already works, re-verify asynchronously.
        if !hasEffectiveScreenRecordingPermission {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.pollPermissionsInGuideSheet(checkScreenCaptureKit: false)
            }
        }
    }

    func openPermissionGuide(startHostWhenReady: Bool = false) {
        refreshPermission()
        permissionCheckFeedback = ""
        pendingStartHostAfterPermission = startHostWhenReady
        showingPermissionGuideSheet = true
    }

    func dismissPermissionGuide() {
        showingPermissionGuideSheet = false
        pendingStartHostAfterPermission = false
        permissionCheckFeedback = ""
    }

    func openScreenRecordingSettings() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openAccessibilitySettings() {
        _ = InputInjector.hasAccessibilityPermission(prompt: true)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openNextMissingPermissionSettings() {
        if !hasEffectiveScreenRecordingPermission {
            openScreenRecordingSettings()
        } else if !hasAccessibilityPermission {
            openAccessibilitySettings()
        }
    }

    func pollPermissionsInGuideSheet(checkScreenCaptureKit: Bool = false) async {
        hasAccessibilityPermission = InputInjector.hasAccessibilityPermission(prompt: false)
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight {
            hasScreenRecordingPermission = true
        } else if checkScreenCaptureKit {
            await checkDirectCapturePermission()
        }

        if hasAllHostPermissions {
            permissionCheckFeedback = ""
            let shouldStart = pendingStartHostAfterPermission
            pendingStartHostAfterPermission = false
            showingPermissionGuideSheet = false
            if shouldStart && !isHostRunning {
                startHost()
                statusLog = "[被控端] 权限已就绪，已自动开启本机被控服务"
            }
        }
    }

    func recheckPermissionsAndStartIfReady() async {
        await pollPermissionsInGuideSheet(checkScreenCaptureKit: true)
        guard !hasAllHostPermissions else { return }

        switch (hasEffectiveScreenRecordingPermission, hasAccessibilityPermission) {
        case (false, false):
            permissionCheckFeedback = "尚未检测到「屏幕录制」与「辅助功能」权限，请点击上方按钮前往系统设置勾选 OpenUU。"
        case (false, true):
            permissionCheckFeedback = "尚未检测到「屏幕录制」权限。若你已在系统设置中勾选 OpenUU，点击下方「重启应用生效」即可完成开启。"
        case (true, false):
            permissionCheckFeedback = "尚未检测到「辅助功能」权限，请在「系统设置 ➔ 隐私与安全性 ➔ 辅助功能」中打开 OpenUU 开关。"
        case (true, true):
            permissionCheckFeedback = ""
        }
    }

    func relaunchApplication() {
        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
                Task { @MainActor in
                    NSApp.terminate(nil)
                }
            }
        } else if let execPath = Bundle.main.executablePath {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: execPath)
            try? proc.run()
            NSApp.terminate(nil)
        }
    }

    func startHost() {
        refreshPermission()
        let preferred = hostPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = hostBridge.startHost(port: hostPort, preferredPIN: preferred.isEmpty ? nil : preferred) else {
            statusLog = "启动本机被控服务失败"
            return
        }
        hostPort = result.boundPort
        hostPIN = result.pin
        isHostRunning = true
        refreshIdentitySnapshot()
        if captureScheme == .virtualDisplay {
            applyCaptureScheme()
        }
    }

    func stopHostService() async {
        await captureManager.stopAll()
        activeStreamCount = 0
        hostLinkBadge = ""
        captureManager.networkTier = .lan
        hostBridge.stopHost()
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        isHostRunning = false
        coordStatusText = "未开启被控监听"
        statusLog = "[被控端] 已停止本机被控监听"
    }

    func stopAllHostStreams() async {
        await captureManager.stopAll()
        activeStreamCount = 0
        hostBridge.sendWindowTopology([])
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        statusLog = "[被控端] 已停止所有正在共享的画面"
    }

    func startDiscovery() {
        refreshIdentitySnapshot(syncWanFields: true)
        probeBridge.startDiscovery()
        probeAllSavedDevicesNow()
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.discoveredPeers = self.probeBridge.listPeers()
                if self.isHostRunning {
                    self.refreshIdentitySnapshot(syncWanFields: false)
                }
                self.presenceTickCounter += 1
                // Poll WAN online status every 120s (60 * 2s) and only when a window is visible,
                // using a single batched `/v1/resolve-batch` request to preserve public quota.
                if self.presenceTickCounter % 60 == 0 {
                    let hasVisibleWindow = NSApp.isActive || NSApp.windows.contains(where: { $0.isVisible })
                    if hasVisibleWindow {
                        self.probeAllSavedDevicesNow()
                    }
                }
            }
        }
    }

    func revokeTrustedPeer(_ peer: TrustedPeerModel) {
        hostBridge.removeTrustedPeer(deviceID: peer.device_id)
        probeBridge.removeTrustedPeer(deviceID: peer.device_id)
        for s in sessions.values {
            s.bridge.removeTrustedPeer(deviceID: peer.device_id)
        }
        refreshIdentitySnapshot()
        statusLog = "已撤销信任授权: \(peer.device_name)"
    }

    // MARK: - Permissions, Display & Diagnostics

    func refreshPermission() {
        hasAccessibilityPermission = InputInjector.hasAccessibilityPermission(prompt: false)
        let preflight = CGPreflightScreenCaptureAccess()
        if preflight || hasDirectCapturePermission {
            hasScreenRecordingPermission = true
            Task { await checkDirectCapturePermission() }
        } else {
            hasScreenRecordingPermission = false
            hasDirectCapturePermission = false
        }
    }

    func checkDirectCapturePermission() async {
        do {
            _ = try await WindowCatalog.fetchWindows()
            hasDirectCapturePermission = true
            hasScreenRecordingPermission = true
        } catch {
            hasDirectCapturePermission = false
        }
    }

    func applyCaptureScheme() {
        let useVirtual = (captureScheme == .virtualDisplay)
        captureManager.useVirtualDisplayMode = useVirtual
        captureManager.isRelocationPaused = false
        if useVirtual {
            let ok = virtualDisplayManager.ensureVirtualDisplay()
            statusLog = ok
                ? "[被控端] 已启用虚拟副屏隔离模式"
                : "[被控端] 当前系统不支持 CGVirtualDisplay，已自动回退主屏模式"
            if !ok {
                captureManager.useVirtualDisplayMode = false
                inputInjector.setVirtualDisplayID(0)
            } else {
                inputInjector.setVirtualDisplayID(virtualDisplayManager.displayID)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let ready = await self.virtualDisplayManager.ensureVirtualDisplayReady()
                    if ready {
                        self.inputInjector.setVirtualDisplayID(self.virtualDisplayManager.displayID)
                        await self.captureManager.syncNow()
                    }
                }
            }
        } else {
            inputInjector.setVirtualDisplayID(0)
            virtualDisplayManager.destroyVirtualDisplay()
            statusLog = "[被控端] 已切换为主屏模式，窗口已归位"
            Task { @MainActor [weak self] in
                await self?.captureManager.syncNow()
            }
        }
    }

    func returnWindowsToMainDisplay() {
        captureManager.isRelocationPaused = true
        inputInjector.setVirtualDisplayID(0)
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        statusLog = "[被控端] 已将所有共享窗口移回主屏"
    }

    private func enqueueClipboardFile(_ fileURL: URL) {
        let key: UInt32 = 0
        pendingDroppedFiles[key, default: []].append(fileURL)
        pendingDropTasks[key]?.cancel()
        pendingDropTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled else { return }
            self.pendingDropTasks.removeValue(forKey: key)
            guard let urls = self.pendingDroppedFiles.removeValue(forKey: key), !urls.isEmpty else { return }
            self.clipboardSync.applyRemoteClipboardFiles(urls)
        }
    }

    private func enqueueDroppedFileForPaste(windowID: UInt32, fileURL: URL) {
        pendingDroppedFiles[windowID, default: []].append(fileURL)
        pendingDropTasks[windowID]?.cancel()
        pendingDropTasks[windowID] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled else { return }
            self.pendingDropTasks.removeValue(forKey: windowID)
            guard let urls = self.pendingDroppedFiles.removeValue(forKey: windowID), !urls.isEmpty else { return }

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            self.clipboardSync.ignoreCurrentPasteboardChange()
            self.inputInjector.pasteDroppedFiles(windowID: CGWindowID(windowID), fileURLs: urls)
            self.statusLog = "[被控端] 已接收并粘贴 \(urls.count) 个拖入文件"
        }
    }

    private func pushHostAppListToClient() async {
        do {
            let windows = try await WindowCatalog.fetchWindows()
            var grouped: [String: (name: String, pid: UInt32, count: UInt32, sampleWindowID: UInt32, sampleTitle: String)] = [:]
            for w in windows {
                if let existing = grouped[w.bundleID] {
                    grouped[w.bundleID] = (existing.name, existing.pid, existing.count + 1, existing.sampleWindowID, existing.sampleTitle)
                } else {
                    let pid = UInt32(w.window.owningApplication?.processID ?? 0)
                    grouped[w.bundleID] = (w.appName, pid, 1, w.windowID, w.title)
                }
            }
            let weChatApp = NSRunningApplication.runningApplications(withBundleIdentifier: WindowCatalog.weChatBundleID).first
            let helperRequests: [LiveDockIconExtractor.Request] = grouped.compactMap { (bid, val) in
                guard bid.localizedCaseInsensitiveContains("AppEx"), val.pid != 0 else { return nil }
                return LiveDockIconExtractor.Request(
                    windowID: val.sampleWindowID,
                    pid: pid_t(val.pid),
                    rawBundleID: bid,
                    appName: val.name,
                    windowTitle: val.sampleTitle,
                    primaryAppName: weChatApp?.localizedName ?? "微信",
                    primaryBundleURLPath: weChatApp?.bundleURL?.path
                )
            }
            let liveHelperResults = await LiveDockIconExtractor.captureBatch(requests: helperRequests)

            var apps: [RemoteAppSummary] = grouped.map { (bid, val) in
                let live = liveHelperResults[val.sampleWindowID]
                let iconB64: String
                if let liveB64 = live?.iconB64, !liveB64.isEmpty {
                    iconB64 = liveB64
                } else {
                    let rawIcon = NSRunningApplication(processIdentifier: pid_t(val.pid))?.icon
                    iconB64 = IconCompositor.encodeIconToBase64PNG(rawIcon, size: 128)
                }
                let displayName: String = {
                    if let dt = live?.dockTitle, !dt.isEmpty { return dt }
                    if bid.localizedCaseInsensitiveContains("AppEx") && !val.sampleTitle.isEmpty {
                        return val.sampleTitle
                    }
                    return val.name
                }()
                return RemoteAppSummary(bundle_id: bid, name: displayName, pid: val.pid, window_count: val.count, icon_png_b64: iconB64)
            }.sorted { lhs, rhs in
                let lWeChat = lhs.bundle_id == WindowCatalog.weChatBundleID
                let rWeChat = rhs.bundle_id == WindowCatalog.weChatBundleID
                if lWeChat != rWeChat { return lWeChat }
                return lhs.name < rhs.name
            }
            let desktopIcon = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: "整台电脑桌面")
            let desktopB64 = IconCompositor.encodeIconToBase64PNG(desktopIcon, size: 128)
            let hostName = Host.current().localizedName ?? "Mac"
            let desktopEntry = RemoteAppSummary(
                bundle_id: MultiWindowCaptureManager.fullDesktopBundleID,
                name: "整台电脑桌面 (\(hostName))",
                pid: 0,
                window_count: 1,
                icon_png_b64: desktopB64
            )
            apps.insert(desktopEntry, at: 0)
            notificationMonitor.updateWatchedApps(apps.filter { $0.bundle_id != MultiWindowCaptureManager.fullDesktopBundleID }.map { ($0.bundle_id, $0.name) })
            hostBridge.sendAppList(apps)
        } catch {
            statusLog = "[被控端] 获取应用列表失败（请检查屏幕录制权限）: \(error.localizedDescription)"
        }
    }

    func copyDiagnosticLogs() {
        let connDesc = connectedSessions.map { "\($0.alias)(\($0.openWindowCount)w)" }.joined(separator: ",")
        let role = [
            isHostRunning ? "Host(port=\(hostPort), streams=\(activeStreamCount))" : nil,
            !connDesc.isEmpty ? "MultiClient[\(connDesc)]" : nil,
        ].compactMap { $0 }.joined(separator: " + ")
        let perms = "Screen=\(hasScreenRecordingPermission), Direct=\(hasDirectCapturePermission), AX=\(hasAccessibilityPermission)"
        let snapshot = "savedDevices=\(deviceBook.devices.count) activeSessions=\(connectedHostCount) totalWindows=\(totalOpenRemoteWindows)"
        let report = OpenUULogger.shared.buildDiagnosticReport(
            appVersion: "v0.4.0",
            roleSummary: role.isEmpty ? "Idle" : role,
            schemeSummary: captureScheme.rawValue,
            permissionsSummary: perms,
            stateSnapshot: snapshot,
            minLevel: selectedLogLevel
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        clipboardSync.ignoreCurrentPasteboardChange()
        statusLog = "[日志] 已复制诊断日志到剪贴板"
    }

    func revealLogFileInFinder() {
        let url = OpenUULogger.shared.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(OpenUULogger.shared.logDirectoryURL)
        }
    }

    func clearDiagnosticLogs() {
        OpenUULogger.shared.clear()
        logEntries.removeAll()
        statusLog = "[日志] 已清空诊断日志"
    }
}

@MainActor
final class OpenUUAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleURL.pathExtension != "app", let icon = IconCompositor.rawAppIcon {
            NSApp.applicationIconImage = icon
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct OpenUUApp: App {
    @NSApplicationDelegateAdaptor(OpenUUAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("OpenUU") {
            WorkspaceMainView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}

import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let hostBridge = ChameyeBridge()
    let clientBridge = ChameyeBridge()
    let captureManager = MultiWindowCaptureManager()
    let inputInjector = InputInjector()
    let sleepPreventer = SleepPreventer()
    let dockProxyManager = DockProxyManager()
    let virtualDisplayManager = VirtualDisplayManager()
    let fastVideoRouter = FastVideoRouter()
    let clipboardSync = ClipboardSyncManager()
    let notificationMonitor = NotificationBadgeMonitor()
    let clientNotificationManager = ClientNotificationManager()
    var proxyWindows: [UInt32: ProxyWindowController] = [:]
    var knownWindows: [UInt32: WindowTopologyItem] = [:]
    var locallyClosedWindows: Set<UInt32> = []
    private var pendingDroppedFiles: [UInt32: [URL]] = [:]
    private var pendingDropTasks: [UInt32: Task<Void, Never>] = [:]
    var compositedIcons: [String: NSImage] = [:]
    var openedBundleIDs: Set<String> = []
    var windowToBundleID: [UInt32: String] = [:]

    private enum PrefKey {
        static let manualHostIP = "chameye.client.lastHostIP"
        static let manualHostPort = "chameye.client.lastHostPort"
        static let clientPIN = "chameye.client.lastPIN"
        static let hostPIN = "chameye.host.savedPIN"
        static let silentClick = "chameye.host.silentClickMode"
        static let hoverCursor = "chameye.host.hoverCursorSync"
        static let preventSleep = "chameye.host.preventDisplaySleep"
        static let captureScheme = "chameye.host.captureScheme"
        static let clipboardSync = "chameye.shared.clipboardSync"
        static let notificationSync = "chameye.shared.notificationSync"
        static let dynamicRes = "chameye.host.dynamicResolutionBoost"
        static let targetFPS = "chameye.host.targetFPS"
        static let debugHUD = "chameye.client.showDebugHUD"
    }

    enum CaptureScheme: String, CaseIterable, Identifiable {
        case mainScreen = "main"
        case virtualDisplay = "virtual"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mainScreen: return "方案A：主屏模式（OBS防裁剪+出屏自动拉入）"
            case .virtualDisplay: return "方案C：虚拟副屏隔离（不打扰主屏）"
            }
        }
    }

    @Published var statusLog: String = "就绪" {
        didSet {
            if statusLog != oldValue {
                ChameyeLogger.shared.log("Status", statusLog)
            }
        }
    }
    @Published var logLines: [String] = []
    @Published var isHostRunning = false
    @Published var activeStreamCount: Int = 0
    @Published var hostPort: UInt16 = 39481
    @Published var hostPIN: String = UserDefaults.standard.string(forKey: PrefKey.hostPIN) ?? String(format: "%06d", Int.random(in: 0...999999)) {
        didSet { UserDefaults.standard.set(hostPIN, forKey: PrefKey.hostPIN) }
    }
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
            for controller in proxyWindows.values {
                controller.setDebugHUDVisible(showDebugHUD)
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

    // Client state
    @Published var discoveredPeers: [DiscoveredPeer] = []
    @Published var isClientConnected = false
    @Published var remoteApps: [RemoteAppSummary] = []
    @Published var manualHostIP: String = UserDefaults.standard.string(forKey: PrefKey.manualHostIP) ?? "127.0.0.1" {
        didSet { UserDefaults.standard.set(manualHostIP, forKey: PrefKey.manualHostIP) }
    }
    @Published var manualHostPort: String = UserDefaults.standard.string(forKey: PrefKey.manualHostPort) ?? "39481" {
        didSet { UserDefaults.standard.set(manualHostPort, forKey: PrefKey.manualHostPort) }
    }
    @Published var clientPIN: String = UserDefaults.standard.string(forKey: PrefKey.clientPIN) ?? "" {
        didSet { UserDefaults.standard.set(clientPIN, forKey: PrefKey.clientPIN) }
    }

    private var discoveryTimer: Timer?

    init() {
        // Persist initial generated PIN immediately so it stays fixed across restarts.
        UserDefaults.standard.set(hostPIN, forKey: PrefKey.hostPIN)

        // Hook diagnostic logger into live UI ring buffer
        ChameyeLogger.shared.onLineAppended = { [weak self] line in
            guard let self else { return }
            self.logLines.append(line)
            if self.logLines.count > 300 {
                self.logLines.removeFirst(self.logLines.count - 300)
            }
        }
        ChameyeLogger.shared.log("App", "Chameye v0.2.30 launched (scheme=\(captureScheme.rawValue), hud=\(showDebugHUD))")

        // Ensure clean QUIC CONNECTION_CLOSE, window return, and Dock cleanup on Cmd+Q quit!
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.hostBridge.stopHost()
                self.clientBridge.disconnect()
                self.virtualDisplayManager.returnAllWindowsToMainDisplay()
                self.dockProxyManager.terminateAll()
            }
        }

        hostBridge.onStatus = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.statusLog = "[Host] \(msg)"
                if msg.hasPrefix("client connected:") {
                    self.clipboardSync.start()
                    await self.pushHostAppListToClient()
                    self.notificationMonitor.start()
                    self.captureManager.requestAllKeyframes()
                } else if msg.contains("disconnected") {
                    self.notificationMonitor.stop()
                    if !self.isClientConnected {
                        self.clipboardSync.stop()
                    }
                    await self.stopAllHostStreams()
                }
            }
        }
        clientBridge.onStatus = { [weak self] msg in
            Task { @MainActor in
                guard let self else { return }
                self.statusLog = "[Client] \(msg)"
                if msg.hasPrefix("connected to host:") {
                    self.isClientConnected = true
                    self.clipboardSync.start()
                    self.clientNotificationManager.requestPermissionIfNeeded()
                    self.clientBridge.requestAppList()
                } else if msg.contains("disconnected") || msg.contains("connect failed") {
                    if !self.isHostRunning {
                        self.clipboardSync.stop()
                    }
                    self.cleanupClientSessionState()
                }
            }
        }
        hostBridge.onControlEvent = { [weak self] evt in
            guard let self else { return }
            switch evt.type {
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
        clientBridge.onControlEvent = { [weak self] evt in
            Task { @MainActor in
                guard let self else { return }
                if evt.type == "cursor", let kind = evt.kind {
                    for controller in self.proxyWindows.values {
                        controller.applyCursor(kind: kind)
                    }
                } else if evt.type == "window_topology", let windows = evt.windows {
                    self.reconcileRemoteWindows(windows)
                } else if evt.type == "list_apps_resp", let apps = evt.apps {
                    self.remoteApps = apps
                    for app in apps {
                        let rawIcon = IconCompositor.decodeBase64PNG(app.icon_png_b64 ?? "")
                        self.compositedIcons[app.bundle_id] = IconCompositor.compositeWithChameyeBadge(rawIcon)
                    }
                } else if evt.type == "clipboard_sync" {
                    self.clipboardSync.applyRemoteClipboard(
                        hash: evt.content_hash ?? "",
                        clipKind: evt.clip_kind ?? 0,
                        text: evt.text,
                        mimeType: evt.mime_type,
                        imageBase64: evt.image_b64
                    )
                } else if evt.type == "notification" {
                    let bid = evt.app_bundle_id ?? ""
                    let appName = self.remoteApps.first(where: { $0.bundle_id == bid })?.name ?? bid
                    let icon = self.compositedIcons[bid]
                    self.clientNotificationManager.presentRemoteNotification(
                        bundleID: bid,
                        appName: appName,
                        title: evt.title ?? "",
                        subtitle: evt.subtitle ?? "",
                        body: evt.body ?? "",
                        icon: icon
                    )
                } else if evt.type == "badge_update" {
                    let bid = evt.app_bundle_id ?? ""
                    let badge = evt.badge_text ?? ""
                    if !bid.isEmpty, self.notificationSyncEnabled {
                        self.dockProxyManager.updateBadge(badge, for: bid)
                    }
                } else if evt.type == "file_drop", let path = evt.local_path, !path.isEmpty {
                    let url = URL(fileURLWithPath: path)
                    let winID = evt.window_id ?? 0
                    if winID == 0xFFFF_FFFE {
                        // Drag-out from Host remote window -> hand off to active local drag session on Client!
                        var handedOff = false
                        for ctrl in self.proxyWindows.values {
                            if ctrl.deliverDragOutFiles([url]) {
                                handedOff = true
                                break
                            }
                        }
                        if !handedOff {
                            // If user already released mouse before transfer finished, put file on clipboard for Cmd+V!
                            self.enqueueClipboardFile(url)
                        }
                    } else {
                        self.enqueueClipboardFile(url)
                    }
                }
            }
        }
        let router = fastVideoRouter
        clientBridge.onVideoFrame = { [weak self] packet in
            // Fast path: enqueue directly onto the window's hardware renderQueue without hopping to @MainActor.
            // Only hop to @MainActor on the first frame of a window or when the remote window's dimensions change.
            let needsWindowSync = router.routeAndEnqueue(packet)
            if needsWindowSync {
                let winID = packet.windowID
                let w = packet.width
                let h = packet.height
                Task { @MainActor [weak self] in
                    guard let self, !self.locallyClosedWindows.contains(winID) else { return }
                    let controller = self.ensureProxyWindow(for: winID)
                    controller.syncRemoteFrameSize(windowID: winID, width: w, height: h)
                }
            }
        }
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
            self?.statusLog = "[Host] \(msg)"
        }
        captureManager.onWindowContentInset = { [weak self] winID, inset in
            self?.inputInjector.setContentInset(for: winID, inset: inset)
        }
        inputInjector.silentMode = silentClickMode
        inputInjector.hoverCursorSync = hoverCursorSync
        sleepPreventer.setEnabled(preventDisplaySleep)
        clipboardSync.isEnabled = clipboardSyncEnabled
        clipboardSync.onSendText = { [weak self] hash, text in
            guard let self else { return }
            if self.isHostRunning {
                self.hostBridge.sendClipboardText(hash: hash, text: text)
            }
            if self.isClientConnected {
                self.clientBridge.sendClipboardText(hash: hash, text: text)
            }
        }
        clipboardSync.onSendImage = { [weak self] hash, mime, data in
            guard let self else { return }
            if self.isHostRunning {
                self.hostBridge.sendClipboardImage(hash: hash, mimeType: mime, data: data)
            }
            if self.isClientConnected {
                self.clientBridge.sendClipboardImage(hash: hash, mimeType: mime, data: data)
            }
        }
        clipboardSync.onSendFiles = { [weak self] urls in
            guard let self else { return }
            for url in urls {
                if self.isHostRunning {
                    self.hostBridge.sendFileBlob(windowID: 0, x: 0, y: 0, fileURL: url)
                }
                if self.isClientConnected {
                    self.clientBridge.sendFileBlob(windowID: 0, x: 0, y: 0, fileURL: url)
                }
            }
            self.statusLog = "[剪贴板] 正在同步 \(urls.count) 个文件到对端..."
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
        clientNotificationManager.onNotificationClicked = { [weak self] bid in
            guard let self else { return }
            if self.openedBundleIDs.contains(bid) {
                self.focusWindows(for: bid)
            } else if let app = self.remoteApps.first(where: { $0.bundle_id == bid }) {
                self.openRemoteApp(app)
            }
        }
        inputInjector.onDebugLog = { [weak self] msg in
            Task { @MainActor in
                self?.statusLog = "[Input] \(msg)"
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
                self?.captureManager.lastInteractedWindowID = winID
            }
        }
        inputInjector.onDragOutFilesDetected = { [weak self] urls in
            Task { @MainActor [weak self] in
                guard let self, self.isHostRunning else { return }
                for url in urls {
                    self.hostBridge.sendFileBlob(windowID: 0xFFFF_FFFE, x: 0, y: 0, fileURL: url)
                }
                self.statusLog = "[Host] 检测到拖出 \(urls.count) 个文件，正在传给控制端..."
            }
        }
        dockProxyManager.onFocusAppRequested = { [weak self] bundleID in
            self?.focusWindows(for: bundleID)
        }
        dockProxyManager.onCloseAppRequested = { [weak self] bundleID in
            self?.closeWindows(for: bundleID)
        }
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
            // Batch multi-file drops arriving within 140ms into a single NSPasteboard + Cmd+V!
            try? await Task.sleep(for: .milliseconds(140))
            guard let self, !Task.isCancelled else { return }
            self.pendingDropTasks.removeValue(forKey: windowID)
            guard let urls = self.pendingDroppedFiles.removeValue(forKey: windowID), !urls.isEmpty else { return }

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            self.clipboardSync.ignoreCurrentPasteboardChange()
            self.inputInjector.pasteDroppedFiles(windowID: CGWindowID(windowID), fileURLs: urls)
            self.statusLog = "[Host] 已接收并粘贴 \(urls.count) 个拖入文件"
        }
    }

    private func pushHostAppListToClient() async {
        do {
            let windows = try await WindowCatalog.fetchWindows()
            var grouped: [String: (name: String, pid: UInt32, count: UInt32)] = [:]
            for w in windows {
                if let existing = grouped[w.bundleID] {
                    grouped[w.bundleID] = (existing.name, existing.pid, existing.count + 1)
                } else {
                    let pid = UInt32(w.window.owningApplication?.processID ?? 0)
                    grouped[w.bundleID] = (w.appName, pid, 1)
                }
            }
            var apps: [RemoteAppSummary] = grouped.map { (bid, val) in
                let rawIcon = NSRunningApplication(processIdentifier: pid_t(val.pid))?.icon
                let iconB64 = IconCompositor.encodeIconToBase64PNG(rawIcon, size: 128)
                return RemoteAppSummary(bundle_id: bid, name: val.name, pid: val.pid, window_count: val.count, icon_png_b64: iconB64)
            }.sorted { lhs, rhs in
                let lWeChat = lhs.bundle_id == WindowCatalog.weChatBundleID
                let rWeChat = rhs.bundle_id == WindowCatalog.weChatBundleID
                if lWeChat != rWeChat { return lWeChat }
                return lhs.name < rhs.name
            }
            // Prepend "Full Remote Desktop" option at the top of the app list.
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
            statusLog = "[Host] 获取应用列表失败（请检查屏幕录制权限）: \(error.localizedDescription)"
        }
    }

    private func ensureProxyWindow(for windowID: UInt32) -> ProxyWindowController {
        if let existing = proxyWindows[windowID] {
            return existing
        }
        let info = knownWindows[windowID]
        let offset = CGFloat(proxyWindows.count * 36)
        var initialOrigin = NSPoint(x: 200 + offset, y: 200 - offset)

        // If this is a floating popover/preview (emoji picker / sticker hover preview),
        // place it at the exact relative offset over its parent proxy window!
        if let info, info.parent_window_id != 0,
           let parentWin = proxyWindows[info.parent_window_id]?.window {
            let parentTopY = parentWin.frame.maxY
            let x = parentWin.frame.minX + CGFloat(info.rel_x)
            let y = parentTopY - CGFloat(info.rel_y) - CGFloat(info.height)
            initialOrigin = NSPoint(x: x, y: y)
        }

        let title = info?.title ?? (proxyWindows.isEmpty ? "Chameye v0.2.30 - 远程窗口" : "Chameye v0.2.30 - 子窗口")
        let controller = ProxyWindowController(
            bridge: clientBridge,
            renderer: fastVideoRouter.renderer(for: windowID),
            title: title,
            origin: initialOrigin,
            onDebugLog: { [weak self] msg in
                Task { @MainActor in self?.statusLog = "[Client] \(msg)" }
            }
        )
        controller.setDebugHUDVisible(showDebugHUD)
        controller.onWindowMovedByUser = { [weak self] in
            self?.refreshFloatingPopoversPlacement()
        }
        controller.onBeforePasteShortcut = { [weak self] in
            self?.clipboardSync.syncNowIfChanged()
        }
        controller.onWindowClosedByUser = { [weak self] closedID in
            guard let self else { return }
            // Suppress any in-flight QUIC video frames from immediately resurrecting this closed proxy window.
            self.locallyClosedWindows.insert(closedID)
            self.proxyWindows.removeValue(forKey: closedID)
            self.fastVideoRouter.unregister(windowID: closedID)
            self.dockProxyManager.removeDockIcon(for: "win-\(closedID)")

            // Also close any child/popover windows anchored to this window.
            let childIDs = self.knownWindows.values
                .filter { $0.parent_window_id == closedID }
                .map(\.window_id)
            for childID in childIDs {
                self.locallyClosedWindows.insert(childID)
                self.fastVideoRouter.unregister(windowID: childID)
                self.dockProxyManager.removeDockIcon(for: "win-\(childID)")
                if let childCtrl = self.proxyWindows.removeValue(forKey: childID) {
                    childCtrl.closeProgrammatically()
                }
            }

            // Always stop streaming this window locally (「关投屏」 never closes the remote app window;
            // 「关对端窗」 sends Cmd+W).
            self.clientBridge.stopRemoteSession(windowID: closedID)
            if let bid = self.windowToBundleID.removeValue(forKey: closedID) {
                let stillHasWindow = self.windowToBundleID.values.contains(bid)
                if !stillHasWindow {
                    self.openedBundleIDs.remove(bid)
                    self.dockProxyManager.removeDockIcon(for: bid)
                }
            }
        }
        proxyWindows[windowID] = controller
        if let info {
            applyTopologyToProxyWindow(info, controller: controller)
        }
        return controller
    }

    private func applyTopologyToProxyWindow(_ item: WindowTopologyItem, controller: ProxyWindowController) {
        controller.updateWindowTitle(item.title)
        let isFloatingPopover = item.kind == 2
        let myArea = item.width * item.height
        let isOverlayPreview = isFloatingPopover && knownWindows.values.contains(where: { other in
            other.window_id != item.window_id &&
            other.kind == 2 &&
            other.parent_window_id == item.parent_window_id &&
            (other.width * other.height) > myArea + 100
        })
        controller.configureFloatingPopover(isFloating: isFloatingPopover, isOverlayPreview: isOverlayPreview)
        if isFloatingPopover, item.parent_window_id != 0,
           let parentCtrl = proxyWindows[item.parent_window_id],
           let parentWin = parentCtrl.window {
            let parentRemote = parentCtrl.remoteLogicalSize
            let scaleX = parentRemote.width > 10 ? (parentWin.frame.width / parentRemote.width) : 1.0
            let scaleY = parentRemote.height > 10 ? (parentWin.frame.height / parentRemote.height) : 1.0
            controller.updatePopoverPlacement(
                parentFrame: parentWin.frame,
                relX: CGFloat(item.rel_x) * scaleX,
                relY: CGFloat(item.rel_y) * scaleY,
                fallbackSize: CGSize(width: CGFloat(item.width), height: CGFloat(item.height))
            )
        }
    }

    private func refreshFloatingPopoversPlacement() {
        for (winID, ctrl) in proxyWindows {
            if let item = knownWindows[winID], item.kind == 2 {
                applyTopologyToProxyWindow(item, controller: ctrl)
            }
        }
    }

    private func resolveCompositedIcon(for item: WindowTopologyItem) -> NSImage {
        if let customB64 = item.icon_png_b64, !customB64.isEmpty,
           let raw = IconCompositor.decodeBase64PNG(customB64) {
            return IconCompositor.compositeWithChameyeBadge(raw)
        }
        if item.parent_window_id != 0,
           let bid = windowToBundleID[item.parent_window_id],
           let icon = compositedIcons[bid] {
            return icon
        }
        if let app = remoteApps.first(where: { !($0.name.isEmpty) && item.title.hasPrefix($0.name) }),
           let icon = compositedIcons[app.bundle_id] {
            return icon
        }
        if let first = compositedIcons.values.first {
            return first
        }
        return IconCompositor.compositeWithChameyeBadge(nil)
    }

    private func ensureDockIconForSecondaryWindow(_ item: WindowTopologyItem, iconChanged: Bool = false) {
        guard item.kind == 1 else { return }
        let icon = resolveCompositedIcon(for: item)
        let key = "win-\(item.window_id)"
        dockProxyManager.ensureDockIcon(for: key, title: item.title, compositedIcon: icon)
        if iconChanged {
            dockProxyManager.updateIcon(icon, for: key)
        }
    }

    private func reconcileRemoteWindows(_ remoteWindows: [WindowTopologyItem]) {
        let activeIDs = Set(remoteWindows.map(\.window_id))
        locallyClosedWindows = locallyClosedWindows.intersection(activeIDs)
        for (winID, _) in knownWindows where !activeIDs.contains(winID) {
            knownWindows.removeValue(forKey: winID)
            dockProxyManager.removeDockIcon(for: "win-\(winID)")
        }
        for item in remoteWindows {
            let prevIcon = knownWindows[item.window_id]?.icon_png_b64
            knownWindows[item.window_id] = item
            if item.kind == 1 {
                let iconChanged = (item.icon_png_b64 != nil && item.icon_png_b64 != prevIcon)
                ensureDockIconForSecondaryWindow(item, iconChanged: iconChanged)
            }
        }
        for item in remoteWindows {
            if let ctrl = proxyWindows[item.window_id] {
                applyTopologyToProxyWindow(item, controller: ctrl)
            }
        }
        for (winID, ctrl) in proxyWindows where !activeIDs.contains(winID) {
            proxyWindows.removeValue(forKey: winID)
            fastVideoRouter.unregister(windowID: winID)
            dockProxyManager.removeDockIcon(for: "win-\(winID)")
            if let bid = windowToBundleID.removeValue(forKey: winID) {
                if !windowToBundleID.values.contains(bid) {
                    openedBundleIDs.remove(bid)
                    dockProxyManager.removeDockIcon(for: bid)
                }
            }
            ctrl.closeProgrammatically()
        }
        if remoteWindows.isEmpty {
            dockProxyManager.terminateAll()
            openedBundleIDs.removeAll()
        }
    }

    func refreshPermission() {
        hasAccessibilityPermission = InputInjector.hasAccessibilityPermission(prompt: false)
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
        if hasScreenRecordingPermission {
            Task { await checkDirectCapturePermission() }
        } else {
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

    func regenerateHostPIN() {
        hostPIN = String(format: "%06d", Int.random(in: 0...999999))
    }

    func startHost() {
        refreshPermission()
        let preferred = hostPIN.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let result = hostBridge.startHost(port: hostPort, preferredPIN: preferred.isEmpty ? nil : preferred) else {
            statusLog = "启动 Host 失败"
            return
        }
        hostPort = result.boundPort
        hostPIN = result.pin
        isHostRunning = true
        if captureScheme == .virtualDisplay {
            applyCaptureScheme()
        }
    }

    func applyCaptureScheme() {
        let useVirtual = (captureScheme == .virtualDisplay)
        captureManager.useVirtualDisplayMode = useVirtual
        captureManager.isRelocationPaused = false
        if useVirtual {
            let ok = virtualDisplayManager.ensureVirtualDisplay()
            statusLog = ok
                ? "[Host] 已启用虚拟副屏模式（不打扰主屏）"
                : "[Host] 当前系统不支持 CGVirtualDisplay，已自动回退方案A"
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
            statusLog = "[Host] 已切换为主屏模式（方案A），窗口已归位主屏"
            Task { @MainActor [weak self] in
                await self?.captureManager.syncNow()
            }
        }
    }

    func returnWindowsToMainDisplay() {
        captureManager.isRelocationPaused = true
        inputInjector.setVirtualDisplayID(0)
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        statusLog = "[Host] 已将所有远程窗口移回主屏"
    }

    func stopHostService() async {
        await captureManager.stopAll()
        activeStreamCount = 0
        hostBridge.stopHost()
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        isHostRunning = false
        statusLog = "[Host] 已关闭监听服务"
    }

    func stopAllHostStreams() async {
        await captureManager.stopAll()
        activeStreamCount = 0
        hostBridge.sendWindowTopology([])
        virtualDisplayManager.returnAllWindowsToMainDisplay()
        statusLog = "[Host] 已停止所有画面传输"
    }

    func startDiscovery() {
        clientBridge.startDiscovery()
        discoveryTimer?.invalidate()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.discoveredPeers = self?.clientBridge.listPeers() ?? []
            }
        }
    }

    func connectToHost() {
        guard let port = UInt16(manualHostPort) else {
            statusLog = "端口格式不正确"
            return
        }
        _ = clientBridge.connectClient(hostIP: manualHostIP, port: port, pin: clientPIN)
    }

    func disconnectClient() {
        clientBridge.disconnect()
        cleanupClientSessionState()
        statusLog = "[Client] 已断开连接"
    }

    private func cleanupClientSessionState() {
        isClientConnected = false
        remoteApps = []
        for (_, ctrl) in proxyWindows {
            ctrl.closeProgrammatically()
        }
        proxyWindows.removeAll()
        fastVideoRouter.clear()
        knownWindows.removeAll()
        windowToBundleID.removeAll()
        openedBundleIDs.removeAll()
        dockProxyManager.terminateAll()
    }

    func refreshRemoteApps() {
        clientBridge.requestAppList()
    }

    func openRemoteApp(_ app: RemoteAppSummary) {
        locallyClosedWindows.removeAll()
        openedBundleIDs.insert(app.bundle_id)
        let icon = compositedIcons[app.bundle_id] ?? IconCompositor.compositeWithChameyeBadge(
            IconCompositor.decodeBase64PNG(app.icon_png_b64 ?? "")
        )
        compositedIcons[app.bundle_id] = icon
        dockProxyManager.ensureDockIcon(for: app.bundle_id, title: app.name, compositedIcon: icon)
        clientBridge.startRemoteSession(bundleID: app.bundle_id, windowID: 0)
        statusLog = "[Client] 正在打开远程应用: \(app.name)..."
    }

    private func focusWindows(for bundleID: String) {
        NSApp.activate(ignoringOtherApps: true)
        if bundleID.hasPrefix("win-"),
           let winID = UInt32(bundleID.dropFirst(4)),
           let ctrl = proxyWindows[winID] {
            ctrl.window?.makeKeyAndOrderFront(nil)
            return
        }
        var matched = false
        for (winID, ctrl) in proxyWindows {
            let winTitle = knownWindows[winID]?.title ?? ""
            let appName = remoteApps.first(where: { $0.bundle_id == bundleID })?.name ?? ""
            if windowToBundleID[winID] == bundleID || (!appName.isEmpty && winTitle.hasPrefix(appName)) {
                windowToBundleID[winID] = bundleID
                ctrl.window?.makeKeyAndOrderFront(nil)
                matched = true
            }
        }
        if !matched {
            for ctrl in proxyWindows.values {
                ctrl.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func closeWindows(for bundleID: String) {
        if bundleID.hasPrefix("win-"),
           let winID = UInt32(bundleID.dropFirst(4)) {
            dockProxyManager.removeDockIcon(for: bundleID)
            fastVideoRouter.unregister(windowID: winID)
            if let ctrl = proxyWindows.removeValue(forKey: winID) {
                clientBridge.sendKey(windowID: winID, keyCode: 13, isDown: true, isRepeat: false, modifiers: 8)
                clientBridge.sendKey(windowID: winID, keyCode: 13, isDown: false, isRepeat: false, modifiers: 8)
                ctrl.closeProgrammatically()
            }
            return
        }
        openedBundleIDs.remove(bundleID)
        let appName = remoteApps.first(where: { $0.bundle_id == bundleID })?.name ?? ""
        for (winID, ctrl) in proxyWindows {
            let winTitle = knownWindows[winID]?.title ?? ""
            if windowToBundleID[winID] == bundleID || (!appName.isEmpty && winTitle.hasPrefix(appName)) {
                proxyWindows.removeValue(forKey: winID)
                fastVideoRouter.unregister(windowID: winID)
                windowToBundleID.removeValue(forKey: winID)
                dockProxyManager.removeDockIcon(for: "win-\(winID)")
                clientBridge.stopRemoteSession(windowID: winID)
                ctrl.closeProgrammatically()
            }
        }
    }
    func copyDiagnosticLogs() {
        let role = [
            isHostRunning ? "Host(port=\(hostPort), streams=\(activeStreamCount))" : nil,
            isClientConnected ? "Client(host=\(manualHostIP):\(manualHostPort), windows=\(proxyWindows.count))" : nil,
        ].compactMap { $0 }.joined(separator: " + ")
        let perms = "Screen=\(hasScreenRecordingPermission), Direct=\(hasDirectCapturePermission), AX=\(hasAccessibilityPermission)"
        let report = ChameyeLogger.shared.buildDiagnosticReport(
            appVersion: "v0.2.30",
            roleSummary: role.isEmpty ? "Idle" : role,
            schemeSummary: captureScheme.rawValue,
            permissionsSummary: perms
        )
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(report, forType: .string)
        clipboardSync.ignoreCurrentPasteboardChange()
        statusLog = "[日志] 已复制诊断日志到剪贴板（可直接粘贴反馈）"
    }

    func revealLogFileInFinder() {
        let url = ChameyeLogger.shared.logFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(ChameyeLogger.shared.logDirectoryURL)
        }
    }

    func clearDiagnosticLogs() {
        ChameyeLogger.shared.clear()
        logLines.removeAll()
        statusLog = "[日志] 已清空诊断日志"
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TabView {
                clientTab
                    .tabItem { Label("连接控制 (Client)", systemImage: "display.and.arrow.down") }

                hostTab
                    .tabItem { Label("被控共享 (Host)", systemImage: "macwindow.on.rectangle") }

                settingsAndLogsTab
                    .tabItem { Label("设置与日志", systemImage: "gearshape.2") }
            }

            Divider()
            HStack {
                Circle().fill(state.isClientConnected || state.isHostRunning ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)
                Text(state.statusLog)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("复制日志") {
                    state.copyDiagnosticLogs()
                }
                .controlSize(.mini)
            }
        }
        .padding()
        .frame(minWidth: 540, minHeight: 440)
        .onAppear {
            state.refreshPermission()
            state.startDiscovery()
        }
    }

    private var hostTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("只需在本机启动 Host 服务，控制端连上后可直接挑选要打开的应用（支持同时开多个）。")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("固定配对码 (PIN):")
                TextField("6位数字", text: $state.hostPIN)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .disabled(state.isHostRunning)
                if !state.isHostRunning {
                    Button("随机换码") {
                        state.regenerateHostPIN()
                    }
                    Button("启动 Host 服务") {
                        state.startHost()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Label("监听中: \(state.hostPort)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button(state.activeStreamCount > 0 ? "停止传输 (\(state.activeStreamCount))" : "暂无传输") {
                        Task { await state.stopAllHostStreams() }
                    }
                    .disabled(state.activeStreamCount == 0)
                    Button("关闭监听") {
                        Task { await state.stopHostService() }
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            HStack {
                Text("窗口运行模式:")
                Picker("", selection: $state.captureScheme) {
                    ForEach(AppState.CaptureScheme.allCases) { scheme in
                        Text(scheme.label).tag(scheme)
                    }
                }
                .labelsHidden()
                if state.captureScheme == .virtualDisplay {
                    Button("移回主屏") {
                        state.returnWindowsToMainDisplay()
                    }
                    .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Text("帧率上限:")
                Picker("", selection: $state.targetFPS) {
                    Text("30 FPS (省流最稳)").tag(30)
                    Text("45 FPS (均衡推荐)").tag(45)
                    Text("60 FPS (极致丝滑)").tag(60)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
            }

            HStack(spacing: 12) {
                Toggle("视频动态降采样", isOn: $state.dynamicResolutionBoost)
                    .toggleStyle(.checkbox)
                    .help("看视频或大幅滚动时自动将分辨率从 2.0x 短暂降至 1.2x（减少 64% 像素吞吐），静止后 0.85 秒自动恢复 2.0x Retina 锐利文字")
                Toggle("同步光标形状", isOn: $state.hoverCursorSync)
                    .toggleStyle(.checkbox)
                Toggle("静默点击（不抢鼠标）", isOn: $state.silentClickMode)
                    .toggleStyle(.checkbox)
                Toggle("阻止息屏", isOn: $state.preventDisplaySleep)
                    .toggleStyle(.checkbox)
                Toggle("双向剪贴板", isOn: $state.clipboardSyncEnabled)
                    .toggleStyle(.checkbox)
                Toggle("消息通知与角标", isOn: $state.notificationSyncEnabled)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("检查权限") {
                    state.refreshPermission()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: state.hasScreenRecordingPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasScreenRecordingPermission ? .green : .orange)
                    Text("屏幕录制权限（画面采集）：\(state.hasScreenRecordingPermission ? "已授权" : "未授权")")
                        .font(.caption)
                    Spacer()
                    if !state.hasScreenRecordingPermission {
                        Button("去授权") {
                            _ = CGRequestScreenCaptureAccess()
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Image(systemName: state.hasDirectCapturePermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasDirectCapturePermission ? .green : .orange)
                    Text("直接窗口访问（绕过系统选择器）：\(state.hasDirectCapturePermission ? "已授权" : "未授权")")
                        .font(.caption)
                    Spacer()
                    if !state.hasDirectCapturePermission {
                        Button("去授权") {
                            Task { await state.checkDirectCapturePermission() }
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Image(systemName: state.hasAccessibilityPermission ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.hasAccessibilityPermission ? .green : .orange)
                    Text("辅助功能权限（远程点击/输入）：\(state.hasAccessibilityPermission ? "已授权" : "未授权")")
                        .font(.caption)
                    Spacer()
                    if !state.hasAccessibilityPermission {
                        Button("去授权") {
                            _ = InputInjector.hasAccessibilityPermission(prompt: true)
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Spacer()
        }
        .padding(.top, 8)
    }

    private var clientTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Host IP", text: $state.manualHostIP)
                    .textFieldStyle(.roundedBorder)
                TextField("端口", text: $state.manualHostPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 75)
                TextField("配对码", text: $state.clientPIN)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 95)
                if state.isClientConnected {
                    Button("断开连接") {
                        state.disconnectClient()
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                } else {
                    Button("连接") {
                        state.connectToHost()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !state.discoveredPeers.isEmpty {
                HStack {
                    Text("局域网发现:").font(.caption).foregroundStyle(.secondary)
                    ForEach(state.discoveredPeers) { peer in
                        Button("\(peer.device_name) (\(peer.preferredIP))") {
                            state.manualHostIP = peer.preferredIP
                            state.manualHostPort = "\(peer.port)"
                        }
                        .controlSize(.small)
                    }
                }
            }

            HStack {
                Text("被控端可打开的应用（可同时打开多个）").font(.headline)
                Spacer()
                Button("刷新远程列表") {
                    state.refreshRemoteApps()
                }
                .disabled(!state.isClientConnected)
            }

            List(state.remoteApps) { app in
                HStack(spacing: 10) {
                    if let icon = state.compositedIcons[app.bundle_id] {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 30, height: 30)
                    }
                    VStack(alignment: .leading) {
                        Text(app.name).font(.headline)
                        Text("\(app.bundle_id) · \(app.window_count) 个窗口")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开") {
                        state.openRemoteApp(app)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .frame(minHeight: 200)
        }
        .padding(.top, 8)
    }

    private var settingsAndLogsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("显示与同步设置") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("画面调试浮窗（远程窗口左下角 FPS / 码率 / 编码 HUD）", isOn: $state.showDebugHUD)
                        .toggleStyle(.checkbox)
                    Toggle("双向剪贴板同步（文字 / 图片 / 文件）", isOn: $state.clipboardSyncEnabled)
                        .toggleStyle(.checkbox)
                    Toggle("消息通知横幅与 Dock 未读角标同步", isOn: $state.notificationSyncEnabled)
                        .toggleStyle(.checkbox)
                    Toggle("动态分辨率加速（操作时降分辨，静止恢复 Retina 超清）", isOn: $state.dynamicResolutionBoost)
                        .toggleStyle(.checkbox)
                    Toggle("阻止息屏（共享期间保持显示器唤醒）", isOn: $state.preventDisplaySleep)
                        .toggleStyle(.checkbox)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Text("诊断日志（实时落盘至 ~/Library/Logs/Chameye/chameye.log）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("复制诊断日志") {
                    state.copyDiagnosticLogs()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("打开日志目录") {
                    state.revealLogFileInFinder()
                }
                .controlSize(.small)
                Button("清空") {
                    state.clearDiagnosticLogs()
                }
                .controlSize(.small)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(state.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(size: 10.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(6)
                }
                .background(Color.black.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: state.logLines.count) { _, newCount in
                    if newCount > 0 {
                        proxy.scrollTo(newCount - 1, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 140)
        }
        .padding(.top, 8)
    }
}

final class ChameyeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct ChameyeApp: App {
    @NSApplicationDelegateAdaptor(ChameyeAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Chameye v0.2.30") {
            ContentView()
        }
    }
}

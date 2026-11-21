import AppKit
import Foundation

enum RemoteSessionPhase: Equatable {
    case idle
    case connecting
    case connected
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }
}

/// Represents ONE independent remote Host connection so a single OpenUU Client can simultaneously connect to,
/// monitor, and control MULTIPLE remote Macs side-by-side without window ID or Dock icon collisions!
@MainActor
final class RemotePeerSession: ObservableObject, Identifiable {
    let id: String
    let sessionIndex: Int
    let bridge: OpenUUBridge
    let fastVideoRouter = FastVideoRouter()

    @Published var alias: String
    @Published var target: String
    @Published var port: UInt16
    @Published var phase: RemoteSessionPhase = .idle
    @Published var linkBadge: String = ""
    @Published var statusMessage: String = "未连接"
    @Published var remoteHostName: String = ""
    @Published var remoteApps: [RemoteAppSummary] = []
    @Published var openWindowCount: Int = 0

    var autoOpenFullDesktopOnConnect: Bool = false
    var showDebugHUD: Bool = false {
        didSet {
            for ctrl in proxyWindows.values {
                ctrl.setDebugHUDVisible(showDebugHUD)
            }
        }
    }

    var proxyWindows: [UInt32: ProxyWindowController] = [:]
    var knownWindows: [UInt32: WindowTopologyItem] = [:]
    var locallyClosedWindows: Set<UInt32> = []
    var compositedIcons: [String: NSImage] = [:]
    var openedBundleIDs: Set<String> = []
    var windowToBundleID: [UInt32: String] = [:]

    // Callbacks wired by AppState
    var onStateMutated: (() -> Void)?
    var onConnected: ((_ session: RemotePeerSession, _ remoteName: String, _ remoteDeviceID: String) -> Void)?
    var onStatusLog: ((String) -> Void)?
    var onRemoteClipboard: ((_ hash: String, _ kind: Int32, _ text: String?, _ mime: String?, _ imgB64: String?) -> Void)?
    var onRemoteClipboardFile: ((URL) -> Void)?
    var onBeforePasteShortcut: (() -> Void)?
    var onPresentNotification: ((_ session: RemotePeerSession, _ bundleID: String, _ appName: String, _ title: String, _ subtitle: String, _ body: String, _ icon: NSImage?) -> Void)?
    var onEnsureDockIcon: ((_ dockKey: String, _ title: String, _ icon: NSImage) -> Void)?
    var onUpdateDockIcon: ((_ dockKey: String, _ icon: NSImage) -> Void)?
    var onUpdateDockBadge: ((_ dockKey: String, _ badge: String) -> Void)?
    var onRemoveDockIcon: ((_ dockKey: String) -> Void)?

    init(
        id: String,
        sessionIndex: Int,
        alias: String,
        target: String,
        port: UInt16 = 39481,
        wanConfig: WanConfigModel? = nil
    ) {
        self.id = id
        self.sessionIndex = sessionIndex
        self.alias = alias
        self.target = target
        self.port = port
        self.bridge = OpenUUBridge()
        if let wanConfig {
            self.bridge.setWanConfig(wanConfig)
        }
        setupBridgeCallbacks()
    }

    func dockKey(for subKey: String) -> String {
        "\(id)::\(subKey)"
    }

    private func setupBridgeCallbacks() {
        bridge.onStatus = { [weak self] msg in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.statusMessage = msg
                self.onStatusLog?("[\(self.alias)] \(msg)")
                if msg.hasPrefix("connected to host:") {
                    let rawName = msg
                        .replacingOccurrences(of: "connected to host:", with: "")
                        .components(separatedBy: " (")
                        .first?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? self.alias
                    self.remoteHostName = rawName
                    self.phase = .connected
                    self.bridge.requestAppList()
                    let remoteDevID = self.bridge.getIdentitySnapshot()?.trusted_peers.first?.device_id ?? ""
                    self.onConnected?(self, rawName, remoteDevID)
                    if self.autoOpenFullDesktopOnConnect {
                        self.autoOpenFullDesktopOnConnect = false
                        self.openFullDesktop()
                    }
                } else if msg.hasPrefix("connect failed:") {
                    let reason = msg.replacingOccurrences(of: "connect failed:", with: "").trimmingCharacters(in: .whitespaces)
                    self.cleanupSessionWindows()
                    self.phase = .error(reason)
                    self.onStateMutated?()
                } else if msg.contains("disconnected") {
                    self.cleanupSessionWindows()
                    self.phase = .idle
                    self.onStateMutated?()
                }
            }
        }

        bridge.onControlEvent = { [weak self] evt in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch evt.type {
                case "link_quality":
                    let modeRaw = evt.link_mode ?? "lan"
                    let rtt = evt.rtt_ms ?? 0
                    let tier = StreamNetworkTier(rawValue: modeRaw) ?? .lan
                    self.fastVideoRouter.setWanJitterMode(tier != .lan)
                    self.linkBadge = rtt > 0 ? "\(tier.label) · \(rtt)ms" : tier.label
                    self.onStateMutated?()
                case "cursor":
                    if let kind = evt.kind {
                        for controller in self.proxyWindows.values {
                            controller.applyCursor(kind: kind)
                        }
                    }
                case "window_topology":
                    if let windows = evt.windows {
                        self.reconcileRemoteWindows(windows)
                    }
                case "list_apps_resp":
                    if let apps = evt.apps {
                        self.remoteApps = apps
                        for app in apps {
                            let rawIcon = IconCompositor.decodeBase64PNG(app.icon_png_b64 ?? "")
                            self.compositedIcons[app.bundle_id] = IconCompositor.compositeWithOpenUUBadge(rawIcon)
                        }
                        self.onStateMutated?()
                    }
                case "clipboard_sync":
                    self.onRemoteClipboard?(
                        evt.content_hash ?? "",
                        evt.clip_kind ?? 0,
                        evt.text,
                        evt.mime_type,
                        evt.image_b64
                    )
                case "notification":
                    let bid = evt.app_bundle_id ?? ""
                    let appName = self.remoteApps.first(where: { $0.bundle_id == bid })?.name ?? bid
                    let icon = self.compositedIcons[bid]
                    self.onPresentNotification?(
                        self,
                        bid,
                        "\(appName) · \(self.alias)",
                        evt.title ?? "",
                        evt.subtitle ?? "",
                        evt.body ?? "",
                        icon
                    )
                case "badge_update":
                    let bid = evt.app_bundle_id ?? ""
                    let badge = evt.badge_text ?? ""
                    if !bid.isEmpty {
                        self.onUpdateDockBadge?(self.dockKey(for: bid), badge)
                    }
                case "file_drop":
                    if let path = evt.local_path, !path.isEmpty {
                        let url = URL(fileURLWithPath: path)
                        let winID = evt.window_id ?? 0
                        if winID == 0xFFFF_FFFE {
                            var handedOff = false
                            for ctrl in self.proxyWindows.values {
                                if ctrl.deliverDragOutFiles([url]) {
                                    handedOff = true
                                    break
                                }
                            }
                            if !handedOff {
                                self.onRemoteClipboardFile?(url)
                            }
                        } else {
                            self.onRemoteClipboardFile?(url)
                        }
                    }
                default:
                    break
                }
            }
        }

        let router = fastVideoRouter
        bridge.onVideoFrame = { [weak self] packet in
            let needsWindowSync = router.routeAndEnqueue(packet)
            if needsWindowSync {
                let winID = packet.windowID
                let w = packet.width
                let h = packet.height
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.locallyClosedWindows.contains(winID) {
                        return
                    }
                    let controller = self.ensureProxyWindow(for: winID)
                    controller.syncRemoteFrameSize(windowID: winID, width: w, height: h)
                }
            }
        }
    }

    func connect(password: String, autoOpenDesktop: Bool = false) {
        autoOpenFullDesktopOnConnect = autoOpenDesktop
        phase = .connecting
        linkBadge = "正在握手..."
        onStateMutated?()
        _ = bridge.connectSmart(target: target, defaultPort: port, pin: password)
    }

    func disconnect() {
        bridge.disconnect()
        cleanupSessionWindows()
        phase = .idle
        linkBadge = ""
        onStatusLog?("[\(alias)] 已断开远程连接")
    }

    func refreshApps() {
        bridge.requestAppList()
    }

    func openApp(_ app: RemoteAppSummary) {
        locallyClosedWindows.removeAll()
        fastVideoRouter.unsuppressAll()
        openedBundleIDs.insert(app.bundle_id)
        let icon = compositedIcons[app.bundle_id] ?? IconCompositor.compositeWithOpenUUBadge(
            IconCompositor.decodeBase64PNG(app.icon_png_b64 ?? "")
        )
        compositedIcons[app.bundle_id] = icon
        onEnsureDockIcon?(dockKey(for: app.bundle_id), "\(app.name) · \(alias)", icon)
        bridge.startRemoteSession(bundleID: app.bundle_id, windowID: 0)
        onStatusLog?("[\(alias)] 正在打开远程应用: \(app.name)...")
    }

    func openFullDesktop() {
        if let desktopApp = remoteApps.first(where: { $0.bundle_id == MultiWindowCaptureManager.fullDesktopBundleID }) {
            openApp(desktopApp)
        } else {
            let fallback = RemoteAppSummary(
                bundle_id: MultiWindowCaptureManager.fullDesktopBundleID,
                name: "整台桌面 (\(alias))",
                pid: 0,
                window_count: 1,
                icon_png_b64: nil
            )
            openApp(fallback)
        }
    }

    func cleanupSessionWindows() {
        remoteApps = []
        linkBadge = ""
        fastVideoRouter.setWanJitterMode(false)
        for (_, ctrl) in proxyWindows {
            ctrl.closeProgrammatically()
        }
        proxyWindows.removeAll()
        openWindowCount = 0
        fastVideoRouter.clear()
        for winID in knownWindows.keys {
            onRemoveDockIcon?(dockKey(for: "win-\(winID)"))
        }
        for bid in openedBundleIDs {
            onRemoveDockIcon?(dockKey(for: bid))
        }
        knownWindows.removeAll()
        windowToBundleID.removeAll()
        openedBundleIDs.removeAll()
    }

    // MARK: - Window Topology & Proxy Window Management (Scoped to this Remote Host)

    private func decoratedWindowTitle(_ rawTitle: String) -> String {
        let base = rawTitle.isEmpty ? "远程窗口" : rawTitle
        return "[\(alias)] \(base)"
    }

    private func resolveCompositedIcon(for item: WindowTopologyItem) -> NSImage {
        if let customB64 = item.icon_png_b64, !customB64.isEmpty,
           let raw = IconCompositor.decodeBase64PNG(customB64) {
            return IconCompositor.compositeWithOpenUUBadge(raw)
        }
        if item.parent_window_id != 0,
           let bid = windowToBundleID[item.parent_window_id],
           let icon = compositedIcons[bid] {
            return icon
        }
        if let app = remoteApps.first(where: { !$0.name.isEmpty && item.title.hasPrefix($0.name) }),
           let icon = compositedIcons[app.bundle_id] {
            return icon
        }
        if let first = compositedIcons.values.first {
            return first
        }
        return IconCompositor.compositeWithOpenUUBadge(nil)
    }

    private func reconcileRemoteWindows(_ remoteWindows: [WindowTopologyItem]) {
        let activeIDs = Set(remoteWindows.map(\.window_id))
        let removedClosed = locallyClosedWindows.subtracting(activeIDs)
        for winID in removedClosed {
            fastVideoRouter.unsuppress(windowID: winID)
        }
        locallyClosedWindows = locallyClosedWindows.intersection(activeIDs)

        for (winID, _) in knownWindows where !activeIDs.contains(winID) {
            knownWindows.removeValue(forKey: winID)
            onRemoveDockIcon?(dockKey(for: "win-\(winID)"))
        }
        for item in remoteWindows {
            let prevIcon = knownWindows[item.window_id]?.icon_png_b64
            knownWindows[item.window_id] = item
            if item.kind == 1 {
                let icon = resolveCompositedIcon(for: item)
                let key = dockKey(for: "win-\(item.window_id)")
                onEnsureDockIcon?(key, "\(item.title) · \(alias)", icon)
                if item.icon_png_b64 != nil && item.icon_png_b64 != prevIcon {
                    onUpdateDockIcon?(key, icon)
                }
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
            onRemoveDockIcon?(dockKey(for: "win-\(winID)"))
            if let bid = windowToBundleID.removeValue(forKey: winID) {
                if !windowToBundleID.values.contains(bid) {
                    openedBundleIDs.remove(bid)
                    onRemoveDockIcon?(dockKey(for: bid))
                }
            }
            ctrl.closeProgrammatically()
        }
        if remoteWindows.isEmpty {
            for bid in openedBundleIDs {
                onRemoveDockIcon?(dockKey(for: bid))
            }
            openedBundleIDs.removeAll()
        }
        openWindowCount = proxyWindows.count
    }

    private func ensureProxyWindow(for windowID: UInt32) -> ProxyWindowController {
        if let existing = proxyWindows[windowID] {
            return existing
        }
        let info = knownWindows[windowID]
        let hostOffset = CGFloat((sessionIndex % 5) * 48)
        let winOffset = CGFloat(proxyWindows.count * 32)
        var initialOrigin = NSPoint(x: 180 + hostOffset + winOffset, y: 220 - winOffset)

        if let info, info.parent_window_id != 0,
           let parentWin = proxyWindows[info.parent_window_id]?.window {
            let parentTopY = parentWin.frame.maxY
            let x = parentWin.frame.minX + CGFloat(info.rel_x)
            let y = parentTopY - CGFloat(info.rel_y) - CGFloat(info.height)
            initialOrigin = NSPoint(x: x, y: y)
        }

        let title = decoratedWindowTitle(info?.title ?? "")
        let controller = ProxyWindowController(
            bridge: bridge,
            renderer: fastVideoRouter.renderer(for: windowID),
            title: title,
            origin: initialOrigin,
            onDebugLog: { [weak self] msg in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.onStatusLog?("[\(self.alias)] \(msg)")
                }
            }
        )
        controller.setDebugHUDVisible(showDebugHUD)
        controller.onWindowMovedByUser = { [weak self] in
            self?.refreshFloatingPopoversPlacement()
        }
        controller.onBeforePasteShortcut = { [weak self] in
            self?.onBeforePasteShortcut?()
        }
        controller.onWindowClosedByUser = { [weak self] closedID in
            guard let self else { return }
            self.locallyClosedWindows.insert(closedID)
            self.proxyWindows.removeValue(forKey: closedID)
            self.fastVideoRouter.suppress(windowID: closedID)
            self.onRemoveDockIcon?(self.dockKey(for: "win-\(closedID)"))

            let childIDs = self.knownWindows.values
                .filter { $0.parent_window_id == closedID }
                .map(\.window_id)
            for childID in childIDs {
                self.locallyClosedWindows.insert(childID)
                self.fastVideoRouter.suppress(windowID: childID)
                self.onRemoveDockIcon?(self.dockKey(for: "win-\(childID)"))
                if let childCtrl = self.proxyWindows.removeValue(forKey: childID) {
                    childCtrl.closeProgrammatically()
                }
            }

            self.bridge.stopRemoteSession(windowID: closedID)
            if let bid = self.windowToBundleID.removeValue(forKey: closedID) {
                if !self.windowToBundleID.values.contains(bid) {
                    self.openedBundleIDs.remove(bid)
                    self.onRemoveDockIcon?(self.dockKey(for: bid))
                }
            }
            if closedID == MultiWindowCaptureManager.fullDesktopWindowID {
                self.openedBundleIDs.remove(MultiWindowCaptureManager.fullDesktopBundleID)
                self.onRemoveDockIcon?(self.dockKey(for: MultiWindowCaptureManager.fullDesktopBundleID))
            }
            self.openWindowCount = self.proxyWindows.count
        }
        proxyWindows[windowID] = controller
        openWindowCount = proxyWindows.count
        if let info {
            applyTopologyToProxyWindow(info, controller: controller)
        }
        return controller
    }

    private func applyTopologyToProxyWindow(_ item: WindowTopologyItem, controller: ProxyWindowController) {
        controller.updateWindowTitle(decoratedWindowTitle(item.title))
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

    func focusWindows(subKey: String) {
        NSApp.activate(ignoringOtherApps: true)
        if subKey.hasPrefix("win-"),
           let winID = UInt32(subKey.dropFirst(4)),
           let ctrl = proxyWindows[winID] {
            ctrl.window?.makeKeyAndOrderFront(nil)
            return
        }
        var matched = false
        for (winID, ctrl) in proxyWindows {
            let winTitle = knownWindows[winID]?.title ?? ""
            let appName = remoteApps.first(where: { $0.bundle_id == subKey })?.name ?? ""
            if windowToBundleID[winID] == subKey || (!appName.isEmpty && winTitle.hasPrefix(appName)) {
                windowToBundleID[winID] = subKey
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

    func closeWindows(subKey: String) {
        if subKey.hasPrefix("win-"),
           let winID = UInt32(subKey.dropFirst(4)) {
            onRemoveDockIcon?(dockKey(for: subKey))
            fastVideoRouter.unregister(windowID: winID)
            if let ctrl = proxyWindows.removeValue(forKey: winID) {
                bridge.sendKey(windowID: winID, keyCode: 13, isDown: true, isRepeat: false, modifiers: 8)
                bridge.sendKey(windowID: winID, keyCode: 13, isDown: false, isRepeat: false, modifiers: 8)
                ctrl.closeProgrammatically()
            }
            openWindowCount = proxyWindows.count
            return
        }
        openedBundleIDs.remove(subKey)
        let appName = remoteApps.first(where: { $0.bundle_id == subKey })?.name ?? ""
        for (winID, ctrl) in proxyWindows {
            let winTitle = knownWindows[winID]?.title ?? ""
            if windowToBundleID[winID] == subKey || (!appName.isEmpty && winTitle.hasPrefix(appName)) {
                proxyWindows.removeValue(forKey: winID)
                fastVideoRouter.unregister(windowID: winID)
                windowToBundleID.removeValue(forKey: winID)
                onRemoveDockIcon?(dockKey(for: "win-\(winID)"))
                bridge.stopRemoteSession(windowID: winID)
                ctrl.closeProgrammatically()
            }
        }
        openWindowCount = proxyWindows.count
    }
}

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

    var errorReason: String? {
        if case .error(let msg) = self { return msg }
        return nil
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
    let audioPlayer = AudioStreamPlayer()

    @Published var alias: String
    @Published var target: String
    @Published var port: UInt16
    @Published var phase: RemoteSessionPhase = .idle
    @Published var connectingStartedAt: Date?
    @Published var linkBadge: String = ""
    @Published var statusMessage: String = "未连接"
    @Published var remoteHostName: String = ""
    @Published var remoteApps: [RemoteAppSummary] = []
    @Published var openWindowCount: Int = 0
    @Published var isAudioMuted: Bool = false {
        didSet {
            audioPlayer.setMuted(isAudioMuted)
            for ctrl in proxyWindows.values {
                ctrl.setAudioMuted(isAudioMuted)
            }
            if phase.isConnected {
                bridge.sendAudioControl(enabled: !isAudioMuted, muteHost: muteHostSpeakers)
            }
        }
    }
    @Published var muteHostSpeakers: Bool = true {
        didSet {
            if phase.isConnected {
                bridge.sendAudioControl(enabled: !isAudioMuted, muteHost: muteHostSpeakers)
            }
        }
    }

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
    private var primaryWindowByBundleID: [String: UInt32] = [:]
    private var lastOpenedBundleID: String?

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
    var onUpdateDockTitle: ((_ dockKey: String, _ title: String) -> Void)?
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
                    self.connectingStartedAt = nil
                    self.phase = .connected
                    self.audioPlayer.setMuted(self.isAudioMuted)
                    self.bridge.sendAudioControl(enabled: !self.isAudioMuted, muteHost: self.muteHostSpeakers)
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
                    self.connectingStartedAt = nil
                    self.phase = .error(reason)
                    self.onStateMutated?()
                } else if msg.contains("disconnected") {
                    self.cleanupSessionWindows()
                    self.connectingStartedAt = nil
                    self.phase = .idle
                    self.onStateMutated?()
                } else if self.phase.isConnecting {
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
                case "file_transfer_progress":
                    let winID = evt.window_id ?? 0
                    let blobID = evt.blob_id ?? ""
                    let name = evt.filename ?? "file.bin"
                    let received = evt.received_bytes ?? 0
                    let total = evt.total_bytes ?? 0
                    let state = evt.transfer_state ?? 0
                    if winID == 0xFFFF_FFFE, !blobID.isEmpty {
                        if state == 1 {
                            let desc = DragOutTransferCoordinator.shared.registerTransferStarted(
                                blobID: blobID,
                                filename: name,
                                totalBytes: total
                            )
                            for ctrl in self.proxyWindows.values {
                                if ctrl.deliverDragOutItems([desc]) {
                                    break
                                }
                            }
                        } else if state == 2 {
                            DragOutTransferCoordinator.shared.updateTransferProgress(
                                blobID: blobID,
                                filename: name,
                                receivedBytes: received,
                                totalBytes: total
                            )
                        } else if state == 3 {
                            DragOutTransferCoordinator.shared.markTransferFailed(blobID: blobID)
                        }
                    }
                case "file_drop":
                    if let path = evt.local_path, !path.isEmpty {
                        let url = URL(fileURLWithPath: path)
                        let winID = evt.window_id ?? 0
                        let blobID = evt.blob_id ?? ""
                        let total = evt.total_bytes ?? 0
                        if winID == 0xFFFF_FFFE {
                            let effectiveID = blobID.isEmpty ? UUID().uuidString : blobID
                            let wasClaimed = DragOutTransferCoordinator.shared.markTransferCompleted(
                                blobID: effectiveID,
                                inboxURL: url,
                                totalBytes: total
                            )
                            if !wasClaimed {
                                let desc = DragOutItemDescriptor(
                                    blobID: effectiveID,
                                    filename: url.lastPathComponent,
                                    totalBytes: total
                                )
                                var handedOff = false
                                for ctrl in self.proxyWindows.values {
                                    if ctrl.deliverDragOutItems([desc]) {
                                        handedOff = true
                                        break
                                    }
                                }
                                if !handedOff {
                                    DragOutTransferCoordinator.shared.abandonUnclaimedDragOut(blobID: effectiveID)
                                }
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

        let player = audioPlayer
        bridge.onAudioFrame = { packet in
            player.enqueue(packet)
        }
    }

    func connect(password: String, autoOpenDesktop: Bool = false) {
        autoOpenFullDesktopOnConnect = autoOpenDesktop
        connectingStartedAt = Date()
        phase = .connecting
        statusMessage = "正在发起连接 \(DeviceCodeFormatter.formatInput(target))..."
        linkBadge = "正在握手..."
        onStateMutated?()
        _ = bridge.connectSmart(target: target, defaultPort: port, pin: password)
    }

    func disconnect() {
        bridge.disconnect()
        cleanupSessionWindows()
        connectingStartedAt = nil
        phase = .idle
        linkBadge = ""
        onStatusLog?("[\(alias)] 已断开远程连接")
    }

    func clearError() {
        if case .error = phase {
            phase = .idle
            onStateMutated?()
        }
    }

    func elapsedConnectingSeconds(at now: Date = Date()) -> Int {
        guard let start = connectingStartedAt else { return 0 }
        return max(0, Int(now.timeIntervalSince(start)))
    }

    func refreshApps() {
        bridge.requestAppList()
    }

    func openApp(_ app: RemoteAppSummary) {
        locallyClosedWindows.removeAll()
        fastVideoRouter.unsuppressAll()
        openedBundleIDs.insert(app.bundle_id)
        lastOpenedBundleID = app.bundle_id
        let icon = compositedIcons[app.bundle_id] ?? IconCompositor.compositeWithOpenUUBadge(
            IconCompositor.decodeBase64PNG(app.icon_png_b64 ?? "")
        )
        compositedIcons[app.bundle_id] = icon
        onEnsureDockIcon?(dockKey(for: app.bundle_id), app.name, icon)
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
        audioPlayer.stop()
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
        primaryWindowByBundleID.removeAll()
        openedBundleIDs.removeAll()
        lastOpenedBundleID = nil
    }

    // MARK: - Window Topology & Proxy Window Management (Scoped to this Remote Host)

    private func displayWindowTitle(_ rawTitle: String) -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "远程窗口" : trimmed
    }

    private func resolveCompositedIcon(for item: WindowTopologyItem) -> NSImage {
        if let customB64 = item.icon_png_b64, !customB64.isEmpty,
           let raw = IconCompositor.decodeBase64PNG(customB64) {
            return IconCompositor.compositeWithOpenUUBadge(raw)
        }
        if let bid = windowToBundleID[item.window_id],
           let icon = compositedIcons[bid] {
            return icon
        }
        if item.parent_window_id != 0,
           let bid = windowToBundleID[item.parent_window_id],
           let icon = compositedIcons[bid] {
            return icon
        }
        if let app = remoteApps.first(where: { !$0.name.isEmpty && (item.title == $0.name || item.title.hasPrefix($0.name)) }),
           let icon = compositedIcons[app.bundle_id] {
            return icon
        }
        if let first = compositedIcons.values.first {
            return first
        }
        return IconCompositor.compositeWithOpenUUBadge(nil)
    }

    private func bindBundleID(for item: WindowTopologyItem) {
        if windowToBundleID[item.window_id] != nil { return }
        if item.window_id == MultiWindowCaptureManager.fullDesktopWindowID {
            windowToBundleID[item.window_id] = MultiWindowCaptureManager.fullDesktopBundleID
            return
        }
        if item.parent_window_id != 0, let parentBid = windowToBundleID[item.parent_window_id] {
            windowToBundleID[item.window_id] = parentBid
            return
        }
        if let app = remoteApps.first(where: {
            openedBundleIDs.contains($0.bundle_id) && !$0.name.isEmpty &&
            (item.title == $0.name || item.title.hasPrefix($0.name))
        }) {
            windowToBundleID[item.window_id] = app.bundle_id
            return
        }
        let nonDesktopOpened = openedBundleIDs.subtracting([MultiWindowCaptureManager.fullDesktopBundleID])
        if nonDesktopOpened.count == 1, let sole = nonDesktopOpened.first {
            windowToBundleID[item.window_id] = sole
            return
        }
        if openedBundleIDs.count == 1, let sole = openedBundleIDs.first {
            windowToBundleID[item.window_id] = sole
            return
        }
        if let last = lastOpenedBundleID, openedBundleIDs.contains(last) {
            let alreadyBound = windowToBundleID.values.contains(last)
            if !alreadyBound || item.kind == 0 {
                windowToBundleID[item.window_id] = last
            }
        }
    }

    private func pickPreferredClientPrimaryWindow(candidates: [WindowTopologyItem], bundleID: String) -> WindowTopologyItem? {
        guard !candidates.isEmpty else { return nil }
        let appName = remoteApps.first(where: { $0.bundle_id == bundleID })?.name ?? ""
        return candidates.max { a, b in
            let aMainApp = (a.icon_png_b64 ?? "").isEmpty
            let bMainApp = (b.icon_png_b64 ?? "").isEmpty
            if aMainApp != bMainApp { return !aMainApp && bMainApp }

            if !appName.isEmpty {
                let aTitle = a.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let bTitle = b.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let aExact = aTitle == appName
                let bExact = bTitle == appName
                if aExact != bExact { return !aExact && bExact }
                let aPrefix = aTitle.hasPrefix(appName)
                let bPrefix = bTitle.hasPrefix(appName)
                if aPrefix != bPrefix { return !aPrefix && bPrefix }
            }

            return (a.width * a.height) < (b.width * b.height)
        }
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
            if let bid = windowToBundleID.removeValue(forKey: winID),
               !windowToBundleID.values.contains(bid) {
                primaryWindowByBundleID.removeValue(forKey: bid)
                openedBundleIDs.remove(bid)
                onRemoveDockIcon?(dockKey(for: bid))
            }
        }

        // Bind primary windows first so child/secondary windows can inherit parent_window_id's bundle ID.
        for item in remoteWindows where item.kind == 0 {
            bindBundleID(for: item)
        }
        for item in remoteWindows where item.kind != 0 {
            bindBundleID(for: item)
        }

        // Elect one effective primary window per bundle so the bundle-level Dock icon (`dockKey(for: bid)`)
        // and per-window Dock icons (`dockKey(for: "win-...")`) never duplicate the same window — even if an
        // older remote Host sends all remaining windows of an app with `kind == 1`.
        let prevPrimaryByBundle = primaryWindowByBundleID
        let normalByBundle = Dictionary(grouping: remoteWindows.filter { $0.kind == 0 || $0.kind == 1 }) { item in
            windowToBundleID[item.window_id] ?? ""
        }
        for existingBid in Array(primaryWindowByBundleID.keys) {
            if (normalByBundle[existingBid] ?? []).isEmpty {
                primaryWindowByBundleID.removeValue(forKey: existingBid)
            }
        }
        for (bid, normals) in normalByBundle where !bid.isEmpty && bid != MultiWindowCaptureManager.fullDesktopBundleID {
            if let explicitPrimary = normals.first(where: { $0.kind == 0 }) {
                primaryWindowByBundleID[bid] = explicitPrimary.window_id
            } else if let curID = primaryWindowByBundleID[bid],
                      let curItem = normals.first(where: { $0.window_id == curID }) {
                let curHasCustomIcon = !(curItem.icon_png_b64 ?? "").isEmpty
                let hasStandardMainWindow = normals.contains { ($0.icon_png_b64 ?? "").isEmpty }
                if curHasCustomIcon && hasStandardMainWindow,
                   let promoted = pickPreferredClientPrimaryWindow(candidates: normals, bundleID: bid) {
                    primaryWindowByBundleID[bid] = promoted.window_id
                }
            } else if let elected = pickPreferredClientPrimaryWindow(candidates: normals, bundleID: bid) {
                primaryWindowByBundleID[bid] = elected.window_id
            }
        }

        for item in remoteWindows {
            let prevItem = knownWindows[item.window_id]
            knownWindows[item.window_id] = item
            let dockTitle = displayWindowTitle(item.title)
            let bid = windowToBundleID[item.window_id]
            let isNormal = item.kind == 0 || item.kind == 1
            let isEffectivePrimary: Bool
            if let bid, bid != MultiWindowCaptureManager.fullDesktopBundleID, isNormal {
                isEffectivePrimary = primaryWindowByBundleID[bid] == item.window_id
            } else {
                isEffectivePrimary = item.kind == 0
            }

            if isEffectivePrimary {
                // Ensure no secondary `win-<id>` Dock proxy coexists with the bundle-level Dock icon.
                onRemoveDockIcon?(dockKey(for: "win-\(item.window_id)"))
                if let bid, bid != MultiWindowCaptureManager.fullDesktopBundleID {
                    let key = dockKey(for: bid)
                    let prevPrimaryID = prevPrimaryByBundle[bid]
                    openedBundleIDs.insert(bid)
                    if let b64 = item.icon_png_b64, !b64.isEmpty {
                        let icon = resolveCompositedIcon(for: item)
                        onEnsureDockIcon?(key, dockTitle, icon)
                        if b64 != prevItem?.icon_png_b64 || prevPrimaryID != item.window_id {
                            onUpdateDockIcon?(key, icon)
                        }
                        // Helper/Mini-Program running as the sole primary window: keep its Dock title synced too.
                        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onUpdateDockTitle?(key, dockTitle)
                        }
                    } else if bid.localizedCaseInsensitiveContains("AppEx") {
                        let icon = resolveCompositedIcon(for: item)
                        onEnsureDockIcon?(key, dockTitle, icon)
                        if !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onUpdateDockTitle?(key, dockTitle)
                        }
                    } else {
                        let appSummary = remoteApps.first(where: { $0.bundle_id == bid })
                        let canonicalTitle = (appSummary?.name.isEmpty == false) ? appSummary!.name : dockTitle
                        let canonicalIcon = compositedIcons[bid] ?? resolveCompositedIcon(for: item)
                        onEnsureDockIcon?(key, canonicalTitle, canonicalIcon)
                        if !(prevItem?.icon_png_b64 ?? "").isEmpty || (prevPrimaryID != nil && prevPrimaryID != item.window_id) {
                            onUpdateDockIcon?(key, canonicalIcon)
                        }
                    }
                }
            } else if item.kind == 1 {
                let icon = resolveCompositedIcon(for: item)
                let key = dockKey(for: "win-\(item.window_id)")
                onEnsureDockIcon?(key, dockTitle, icon)
                if let b64 = item.icon_png_b64, !b64.isEmpty, b64 != prevItem?.icon_png_b64 {
                    onUpdateDockIcon?(key, icon)
                }
                if prevItem != nil && item.title != prevItem?.title && !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onUpdateDockTitle?(key, dockTitle)
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
                    primaryWindowByBundleID.removeValue(forKey: bid)
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
            primaryWindowByBundleID.removeAll()
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

        let title = displayWindowTitle(info?.title ?? "")
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
        controller.setAudioMuted(isAudioMuted)
        controller.onToggleAudioMute = { [weak self] in
            guard let self else { return }
            self.isAudioMuted.toggle()
        }
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
                self.windowToBundleID.removeValue(forKey: childID)
                self.onRemoveDockIcon?(self.dockKey(for: "win-\(childID)"))
                if let childCtrl = self.proxyWindows.removeValue(forKey: childID) {
                    childCtrl.closeProgrammatically()
                }
            }

            self.bridge.stopRemoteSession(windowID: closedID)
            if let bid = self.windowToBundleID.removeValue(forKey: closedID) {
                if self.primaryWindowByBundleID[bid] == closedID {
                    self.primaryWindowByBundleID.removeValue(forKey: bid)
                }
                if !self.windowToBundleID.values.contains(bid) {
                    self.primaryWindowByBundleID.removeValue(forKey: bid)
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
        controller.updateWindowTitle(displayWindowTitle(item.title))
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
        if let primaryID = primaryWindowByBundleID[subKey],
           let primaryCtrl = proxyWindows[primaryID] {
            primaryCtrl.window?.makeKeyAndOrderFront(nil)
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
        primaryWindowByBundleID.removeValue(forKey: subKey)
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

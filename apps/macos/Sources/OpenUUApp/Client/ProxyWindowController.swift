import AppKit
import AVFoundation
import Foundation

/// Native macOS proxy window that renders the remote app like a local Coherence window,
/// forwarding mouse/scroll/keyboard events and supporting native local Chinese IME input.
@MainActor
final class ProxyWindowController: NSWindowController, NSWindowDelegate {
    let renderer: VideoDisplayRenderer
    private let bridge: OpenUUBridge
    private let interactiveView: ProxyInteractiveView
    private var currentWindowID: UInt32 = 0
    private var hasAutoSized = false
    private(set) var isFloatingPopover = false
    private(set) var isOverlayPreview = false
    var remoteLogicalSize: CGSize { interactiveView.remoteLogicalSize }
    private var popoverPlacement: (parentFrame: NSRect, relX: CGFloat, relY: CGFloat, fallbackSize: CGSize)?
    var onWindowClosedByUser: ((UInt32) -> Void)?
    var onWindowMovedByUser: (() -> Void)?
    var onToggleAudioMute: (() -> Void)? {
        get { interactiveView.onToggleAudioMute }
        set { interactiveView.onToggleAudioMute = newValue }
    }
    var onBeforePasteShortcut: (() -> Void)? {
        get { interactiveView.onBeforePasteShortcut }
        set { interactiveView.onBeforePasteShortcut = newValue }
    }
    private var isClosingProgrammatically = false
    private var isLiveResizing = false
    private var isApplyingProgrammaticFrame = false
    private var lastRemoteResizeSentAt: CFAbsoluteTime = 0
    private var lastUserResizeEndedAt: CFAbsoluteTime = 0
    private var settleAspectTask: Task<Void, Never>?

    init(
        bridge: OpenUUBridge,
        renderer: VideoDisplayRenderer = VideoDisplayRenderer(),
        title: String = "OpenUU Remote App",
        origin: NSPoint = NSPoint(x: 200, y: 200),
        onDebugLog: ((String) -> Void)? = nil
    ) {
        self.bridge = bridge
        self.renderer = renderer
        self.interactiveView = ProxyInteractiveView(bridge: bridge, renderer: renderer, onDebugLog: onDebugLog)

        let window = NSWindow(
            contentRect: NSRect(x: origin.x, y: origin.y, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = interactiveView
        super.init(window: window)
        window.delegate = self
        interactiveView.updateTitle(title)
    }

    func updateWindowTitle(_ title: String) {
        window?.title = title
        interactiveView.updateTitle(title)
    }

    func closeProgrammatically() {
        isClosingProgrammatically = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        if !isClosingProgrammatically, currentWindowID != 0 {
            onWindowClosedByUser?(currentWindowID)
        }
    }

    func windowDidMove(_ notification: Notification) {
        if !isFloatingPopover {
            onWindowMovedByUser?()
        }
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        guard !isFloatingPopover else { return }
        isLiveResizing = true
        settleAspectTask?.cancel()
        settleAspectTask = nil
    }

    func windowDidResize(_ notification: Notification) {
        guard !isFloatingPopover, isLiveResizing, !isApplyingProgrammaticFrame,
              let win = window, currentWindowID != 0,
              currentWindowID != MultiWindowCaptureManager.fullDesktopWindowID else {
            return
        }
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastRemoteResizeSentAt < 0.075 {
            return
        }
        lastRemoteResizeSentAt = now
        let size = win.contentLayoutRect.size
        bridge.sendResizeWindow(windowID: currentWindowID, width: Float(size.width), height: Float(size.height))
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard !isFloatingPopover, let win = window, currentWindowID != 0 else { return }
        isLiveResizing = false
        lastUserResizeEndedAt = CFAbsoluteTimeGetCurrent()
        if currentWindowID != MultiWindowCaptureManager.fullDesktopWindowID {
            let finalSize = win.contentLayoutRect.size
            bridge.sendResizeWindow(windowID: currentWindowID, width: Float(finalSize.width), height: Float(finalSize.height))
        }

        // After giving Host ~280ms to resize and send updated frames, check whether Host matched our size.
        // If Host hit its max (already maximized) or min size (or is non-resizable), snap local preview
        // window to the remote aspect ratio so pure zoomed/scaled preview never looks distorted.
        settleAspectTask?.cancel()
        settleAspectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(280))
            guard let self, !Task.isCancelled, !self.isLiveResizing, let win = self.window else { return }
            let remote = self.interactiveView.remoteLogicalSize
            guard remote.width > 10, remote.height > 10 else { return }
            let local = win.contentLayoutRect.size
            // If Host resized to match our dragged size (within 6pt), we are crisp 1:1 — nothing to adjust.
            if abs(local.width - remote.width) <= 6 && abs(local.height - remote.height) <= 6 {
                return
            }
            let remoteAspect = remote.width / remote.height
            let localAspect = local.width / max(1, local.height)
            guard abs(localAspect - remoteAspect) > 0.015 else { return }

            // Preserve width (or fit height to screen) and keep the top-left anchor stable.
            var fittedW = local.width
            var fittedH = round(fittedW / remoteAspect)
            if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
                let maxH = max(200, visible.height - 20)
                if fittedH > maxH {
                    fittedH = maxH
                    fittedW = round(fittedH * remoteAspect)
                }
            }
            let topY = win.frame.maxY
            let newFrame = NSRect(x: win.frame.minX, y: topY - fittedH, width: fittedW, height: fittedH)
            self.isApplyingProgrammaticFrame = true
            win.setFrame(newFrame, display: true, animate: true)
            self.isApplyingProgrammaticFrame = false
        }
    }

    func configureFloatingPopover(isFloating: Bool, isOverlayPreview: Bool) {
        self.isFloatingPopover = isFloating
        self.isOverlayPreview = isOverlayPreview
        interactiveView.isFloatingPopover = isFloating
        guard let win = window else { return }
        if isFloating {
            // Secondary hover preview popovers (e.g. WeChat sticker hover preview above the emoji picker)
            // sit at `.popUpMenu` level (above `.floating`) and ignore local mouse events so hovering inside
            // the emoji picker underneath is never interrupted.
            win.level = isOverlayPreview ? .popUpMenu : .floating
            win.ignoresMouseEvents = isOverlayPreview
        } else {
            win.level = .normal
            win.ignoresMouseEvents = false
        }
    }

    func updatePopoverPlacement(parentFrame: NSRect, relX: CGFloat, relY: CGFloat, fallbackSize: CGSize) {
        popoverPlacement = (parentFrame, relX, relY, fallbackSize)
        guard isFloatingPopover, let win = window else { return }
        let targetW = hasAutoSized ? interactiveView.remoteLogicalSize.width : max(50, fallbackSize.width)
        let targetH = hasAutoSized ? interactiveView.remoteLogicalSize.height : max(50, fallbackSize.height)
        let x = parentFrame.minX + relX
        let y = parentFrame.maxY - relY - targetH
        let newFrame = NSRect(x: x, y: y, width: targetW, height: targetH)
        if abs(win.frame.minX - newFrame.minX) > 0.5 ||
           abs(win.frame.minY - newFrame.minY) > 0.5 ||
           abs(win.frame.width - newFrame.width) > 0.5 ||
           abs(win.frame.height - newFrame.height) > 0.5 {
            win.setFrame(newFrame, display: true)
        }
        if isOverlayPreview {
            win.orderFront(nil)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func syncRemoteFrameSize(windowID: UInt32, width: UInt16, height: UInt16) {
        currentWindowID = windowID
        interactiveView.remoteWindowID = windowID
        let logicalW = max(50, CGFloat(width) / 2.0)
        let logicalH = max(50, CGFloat(height) / 2.0)
        let sizeChanged = abs(interactiveView.remoteLogicalSize.width - logicalW) > 2 ||
                          abs(interactiveView.remoteLogicalSize.height - logicalH) > 2
        interactiveView.remoteLogicalSize = CGSize(width: logicalW, height: logicalH)

        let recentlyResizedByUser = isLiveResizing || (CFAbsoluteTimeGetCurrent() - lastUserResizeEndedAt < 0.7)
        if (!hasAutoSized || (sizeChanged && !recentlyResizedByUser)), let win = window {
            hasAutoSized = true
            var targetW = logicalW
            var targetH = logicalH
            isApplyingProgrammaticFrame = true
            if isFloatingPopover, let placement = popoverPlacement {
                let x = placement.parentFrame.minX + placement.relX
                let y = placement.parentFrame.maxY - placement.relY - targetH
                win.setFrame(NSRect(x: x, y: y, width: targetW, height: targetH), display: true)
            } else if let visible = (win.screen ?? NSScreen.main)?.visibleFrame {
                let maxW = max(320, visible.width - 40)
                let maxH = max(240, visible.height - 40)
                if targetW > maxW || targetH > maxH {
                    let scale = min(maxW / targetW, maxH / targetH)
                    targetW = floor(targetW * scale)
                    targetH = floor(targetH * scale)
                }
                let clampedX = min(max(win.frame.origin.x, visible.minX + 16), visible.maxX - targetW - 16)
                let clampedY = min(max(win.frame.origin.y, visible.minY + 16), visible.maxY - targetH - 16)
                win.setFrame(NSRect(x: clampedX, y: clampedY, width: targetW, height: targetH), display: true)
            } else {
                win.setContentSize(NSSize(width: targetW, height: targetH))
            }
            isApplyingProgrammaticFrame = false
            if isOverlayPreview {
                win.orderFront(nil)
            } else {
                win.makeKeyAndOrderFront(nil)
            }
        }
    }

    func presentFrame(_ packet: EncodedVideoPacket) {
        syncRemoteFrameSize(windowID: packet.windowID, width: packet.width, height: packet.height)
        renderer.enqueue(packet: packet)
    }

    func applyCursor(kind: String) {
        interactiveView.applyRemoteCursor(kind: kind)
    }

    func setDebugHUDVisible(_ visible: Bool) {
        interactiveView.setDebugHUDVisible(visible)
    }

    func setAudioMuted(_ muted: Bool) {
        interactiveView.setAudioMuted(muted)
    }

    func deliverDragOutItems(_ items: [DragOutItemDescriptor]) -> Bool {
        interactiveView.deliverDragOutItems(items)
    }
}

@MainActor
final class ProxyInteractiveView: NSView, @preconcurrency NSTextInputClient, NSDraggingSource {
    private let bridge: OpenUUBridge
    private let renderer: VideoDisplayRenderer
    private let onDebugLog: ((String) -> Void)?
    var onBeforePasteShortcut: (() -> Void)?
    var onToggleAudioMute: (() -> Void)?
    var remoteWindowID: UInt32 = 0 {
        didSet {
            hoverBar.setFullDesktopMode(remoteWindowID == MultiWindowCaptureManager.fullDesktopWindowID)
        }
    }
    var remoteLogicalSize: CGSize = CGSize(width: 960, height: 680)
    var isFloatingPopover: Bool = false {
        didSet {
            if isFloatingPopover {
                setHoverBarVisible(false)
                debugHUD.isHidden = true
            } else {
                debugHUD.isHidden = !isDebugHUDEnabled
            }
        }
    }
    private var markedTextStorage = NSAttributedString()
    private var currentRemoteCursor: NSCursor = .arrow
    private var isMouseInside = false
    private var trackingArea: NSTrackingArea?
    private let hoverBar = HoverTitlebarView()
    private let debugHUD = DebugStatsHUDView()
    private let dropOverlay = FileDropOverlayView()
    private var isDebugHUDEnabled = false
    private var lastTelemetry: VideoStreamTelemetry?
    private var hudIdleTimer: Timer?
    private var isHoverBarVisible = false
    private var lastHoverSentAt: CFAbsoluteTime = 0
    private var pendingDragOutItems: [DragOutItemDescriptor] = []
    private var activeDraggedOutBlobIDs: [String] = []
    private var lastDragEvent: NSEvent?
    private var isLocalLeftMouseDown = false
    private var didStartLocalDragOut = false

    init(bridge: OpenUUBridge, renderer: VideoDisplayRenderer, onDebugLog: ((String) -> Void)? = nil) {
        self.bridge = bridge
        self.renderer = renderer
        self.onDebugLog = onDebugLog
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        renderer.configureOnMainActor()
        layer?.addSublayer(renderer.displayLayer)

        debugHUD.isHidden = true
        addSubview(debugHUD)

        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        registerForDraggedTypes([.fileURL])

        renderer.onTelemetryUpdated = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastTelemetry = snapshot
                if self.isDebugHUDEnabled && !self.isFloatingPopover {
                    self.debugHUD.update(with: snapshot, isIdle: false)
                }
            }
        }

        hoverBar.alphaValue = 0
        hoverBar.isHidden = true
        hoverBar.onCloseClicked = { [weak self] in
            self?.window?.close()
        }
        hoverBar.onCloseRemoteClicked = { [weak self] in
            guard let self, self.remoteWindowID != 0,
                  self.remoteWindowID != MultiWindowCaptureManager.fullDesktopWindowID else { return }
            self.bridge.sendKey(windowID: self.remoteWindowID, keyCode: 13 /* W */, isDown: true, isRepeat: false, modifiers: 8 /* Cmd */)
            self.bridge.sendKey(windowID: self.remoteWindowID, keyCode: 13 /* W */, isDown: false, isRepeat: false, modifiers: 8 /* Cmd */)
        }
        hoverBar.onMuteClicked = { [weak self] in
            self?.onToggleAudioMute?()
        }
        addSubview(hoverBar)
    }

    func updateTitle(_ title: String) {
        hoverBar.setTitle(title)
    }

    func setAudioMuted(_ muted: Bool) {
        hoverBar.setAudioMuted(muted)
    }

    func setDebugHUDVisible(_ visible: Bool) {
        isDebugHUDEnabled = visible
        let shouldShow = visible && !isFloatingPopover
        debugHUD.isHidden = !shouldShow
        hudIdleTimer?.invalidate()
        hudIdleTimer = nil
        if shouldShow {
            if let snap = lastTelemetry {
                let isIdle = (CFAbsoluteTimeGetCurrent() - snap.updatedAt) >= 0.65
                debugHUD.update(with: snap, isIdle: isIdle)
            }
            hudIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isDebugHUDEnabled, !self.isFloatingPopover, let snap = self.lastTelemetry else { return }
                    if CFAbsoluteTimeGetCurrent() - snap.updatedAt >= 0.65 {
                        self.debugHUD.update(with: snap, isIdle: true)
                    }
                }
            }
        }
    }

    private func setHoverBarVisible(_ visible: Bool) {
        guard visible != isHoverBarVisible else { return }
        isHoverBarVisible = visible
        if visible {
            hoverBar.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                hoverBar.animator().alphaValue = 1.0
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                hoverBar.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, !self.isHoverBarVisible else { return }
                    self.hoverBar.isHidden = true
                }
            })
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    func applyRemoteCursor(kind: String) {
        let cursor: NSCursor
        switch kind {
        case "ibeam": cursor = .iBeam
        case "pointing_hand": cursor = .pointingHand
        case "resize_lr": cursor = .resizeLeftRight
        case "resize_ud": cursor = .resizeUpDown
        case "resize_left": cursor = .resizeLeft
        case "resize_right": cursor = .resizeRight
        case "resize_up": cursor = .resizeUp
        case "resize_down": cursor = .resizeDown
        case "open_hand": cursor = .openHand
        case "closed_hand": cursor = .closedHand
        case "crosshair": cursor = .crosshair
        default: cursor = .arrow
        }
        currentRemoteCursor = cursor
        if isMouseInside {
            cursor.set()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        currentRemoteCursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        setHoverBarVisible(false)
        NSCursor.arrow.set()
        if remoteWindowID != 0 {
            bridge.sendMouse(windowID: remoteWindowID, x: 0, y: 0, type: 4, modifiers: 0)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        if isMouseInside {
            currentRemoteCursor.set()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let scale = window?.backingScaleFactor, scale > 0 {
            renderer.displayLayer.contentsScale = scale
        }
        renderer.displayLayer.frame = bounds
        CATransaction.commit()

        let barWidth = min(max(310, bounds.width * 0.58), 440)
        let barHeight: CGFloat = 28
        hoverBar.frame = NSRect(
            x: (bounds.width - barWidth) / 2,
            y: bounds.height - barHeight - 6,
            width: barWidth,
            height: barHeight
        )
        debugHUD.frame = NSRect(x: 10, y: 10, width: 368, height: 62)
        dropOverlay.frame = bounds
    }

    // MARK: - NSDraggingDestination (Drag-and-Drop Files/Images into Remote Window)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !isFloatingPopover, remoteWindowID != 0 else { return [] }
        // Never allow a drag-out initiated from this same proxy window to loop back into itself!
        if (sender.draggingSource as? ProxyInteractiveView) === self {
            return []
        }
        let urls = extractRegularFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        dropOverlay.setCount(urls.count, targetTitle: window?.title)
        dropOverlay.isHidden = false
        return .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dropOverlay.isHidden = true
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        dropOverlay.isHidden = true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropOverlay.isHidden = true
        guard !isFloatingPopover, remoteWindowID != 0 else { return false }
        if (sender.draggingSource as? ProxyInteractiveView) === self {
            return false
        }
        let urls = extractRegularFileURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }

        let loc = convert(sender.draggingLocation, from: nil)
        let normX = bounds.width > 0 ? (loc.x / bounds.width) : 0.5
        let normY = bounds.height > 0 ? (1.0 - (loc.y / bounds.height)) : 0.5
        let rx = Float(normX * remoteLogicalSize.width)
        let ry = Float(normY * remoteLogicalSize.height)

        let maxBytes: Int64 = 512 * 1024 * 1024
        var sentCount = 0
        for url in urls {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            if size > maxBytes {
                onDebugLog?("跳过超大文件 (>512MB): \(url.lastPathComponent)")
                continue
            }
            bridge.sendFileBlob(windowID: remoteWindowID, x: rx, y: ry, fileURL: url)
            sentCount += 1
        }
        if sentCount > 0 {
            onDebugLog?("正在发送 \(sentCount) 个文件到远端窗口...")
            return true
        }
        return false
    }

    private func extractRegularFileURLs(from pb: NSPasteboard) -> [URL] {
        guard let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return []
        }
        let fm = FileManager.default
        return urls.filter { url in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
    }

    private func remotePoint(from event: NSEvent) -> (Float, Float) {
        let local = convert(event.locationInWindow, from: nil)
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        // AppKit origin is bottom-left; macOS CGEvent / SCWindow origin is top-left.
        // Clamp to [0, 1] so dragging past the Client proxy window edge never leaks onto the Host's own desktop!
        let normX = min(max(local.x / bounds.width, 0.0), 1.0)
        let normY = min(max(1.0 - (local.y / bounds.height), 0.0), 1.0)
        return (Float(normX * remoteLogicalSize.width), Float(normY * remoteLogicalSize.height))
    }

    private func modifierMask(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.shift) { mask |= 1 }
        if flags.contains(.control) { mask |= 2 }
        if flags.contains(.option) { mask |= 4 }
        if flags.contains(.command) { mask |= 8 }
        return mask
    }

    override func mouseMoved(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        let nearTop = !isFloatingPopover && (bounds.height - local.y) <= 34
        setHoverBarVisible(nearTop)
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastHoverSentAt >= 0.032 else { return }
        lastHoverSentAt = now
        let (x, y) = remotePoint(from: event)
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 0, modifiers: modifierMask(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        isLocalLeftMouseDown = true
        didStartLocalDragOut = false
        pendingDragOutItems.removeAll()
        activeDraggedOutBlobIDs.removeAll()
        lastDragEvent = event
        let (x, y) = remotePoint(from: event)
        onDebugLog?(String(format: "发送点击 (%.0f, %.0f) win=%u", x, y, remoteWindowID))
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 1, button: 0, clickCount: UInt32(event.clickCount), modifiers: modifierMask(event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        isLocalLeftMouseDown = false
        lastDragEvent = nil
        if didStartLocalDragOut {
            didStartLocalDragOut = false
            pendingDragOutItems.removeAll()
            return
        }
        if !pendingDragOutItems.isEmpty {
            let unclaimed = pendingDragOutItems
            pendingDragOutItems.removeAll()
            for item in unclaimed {
                DragOutTransferCoordinator.shared.abandonUnclaimedDragOut(blobID: item.blobID)
            }
        }
        let (x, y) = remotePoint(from: event)
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 2, button: 0, clickCount: UInt32(event.clickCount), modifiers: modifierMask(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) {
        lastDragEvent = event
        if didStartLocalDragOut {
            return
        }
        let local = convert(event.locationInWindow, from: nil)
        // As soon as Host notifies drag-out metadata (or finishes streaming) and cursor reaches the window edge,
        // hand off immediately to a native local macOS NSDraggingSession onto Client Desktop / Finder!
        if !pendingDragOutItems.isEmpty && !bounds.insetBy(dx: 2, dy: 2).contains(local) {
            beginNativeLocalDragOut(with: pendingDragOutItems, event: event)
            return
        }
        let (x, y) = remotePoint(from: event)
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 3, button: 0, modifiers: modifierMask(event.modifierFlags))
    }

    /// Receives drag-out file descriptor(s) from Host as soon as the user begins dragging inside the remote window.
    /// Returns `true` if this view accepted the drag-out (either queued while still inside window or started immediately).
    func deliverDragOutItems(_ descriptors: [DragOutItemDescriptor]) -> Bool {
        guard !descriptors.isEmpty, isLocalLeftMouseDown, !didStartLocalDragOut else {
            return false
        }
        for desc in descriptors where !pendingDragOutItems.contains(where: { $0.blobID == desc.blobID }) {
            pendingDragOutItems.append(desc)
        }
        if let ev = lastDragEvent {
            let local = convert(ev.locationInWindow, from: nil)
            if !bounds.insetBy(dx: 2, dy: 2).contains(local) {
                beginNativeLocalDragOut(with: pendingDragOutItems, event: ev)
            }
        }
        return true
    }

    private func beginNativeLocalDragOut(with descriptors: [DragOutItemDescriptor], event: NSEvent) {
        guard !didStartLocalDragOut, !descriptors.isEmpty else { return }
        let localPt = convert(event.locationInWindow, from: nil)
        var dragItems: [NSDraggingItem] = []
        var claimedIDs: [String] = []
        for (idx, desc) in descriptors.enumerated() {
            if let item = DragOutTransferCoordinator.shared.makeDraggingItem(
                for: desc,
                localPoint: localPt,
                offsetIndex: idx
            ) {
                dragItems.append(item)
                claimedIDs.append(desc.blobID)
            }
        }
        guard !dragItems.isEmpty else { return }

        didStartLocalDragOut = true
        activeDraggedOutBlobIDs = claimedIDs
        pendingDragOutItems.removeAll()

        // Cancel the remote Host-side drag safely: move the remote drag cursor to the non-drop-target top-left
        // titlebar corner `(12, 12)` and send Esc BEFORE releasing `leftMouseUp` 45ms later, so WeChat never
        // treats the release as dropping the file back into the active conversation or opening a file preview!
        if remoteWindowID != 0 {
            let winID = remoteWindowID
            let b = bridge
            b.sendMouse(windowID: winID, x: 12, y: 12, type: 3, button: 0, modifiers: 0)
            b.sendKey(windowID: winID, keyCode: 53 /* Esc */, isDown: true, isRepeat: false, modifiers: 0)
            b.sendKey(windowID: winID, keyCode: 53 /* Esc */, isDown: false, isRepeat: false, modifiers: 0)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(45))
                b.sendKey(windowID: winID, keyCode: 53 /* Esc */, isDown: true, isRepeat: false, modifiers: 0)
                b.sendKey(windowID: winID, keyCode: 53 /* Esc */, isDown: false, isRepeat: false, modifiers: 0)
                b.sendMouse(windowID: winID, x: 12, y: 12, type: 2, button: 0, clickCount: 0, modifiers: 0)
            }
        }

        onDebugLog?("已接管拖出 \(dragItems.count) 个文件，可松手放到本机桌面/访达")
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        return .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        // AppKit consumes the final mouseUp inside NSDraggingSession, so reset drag state cleanly here!
        let finishedIDs = activeDraggedOutBlobIDs
        activeDraggedOutBlobIDs.removeAll()
        isLocalLeftMouseDown = false
        didStartLocalDragOut = false
        lastDragEvent = nil
        pendingDragOutItems.removeAll()
        DragOutTransferCoordinator.shared.noteDraggingSessionEnded(blobIDs: finishedIDs, operation: operation)
    }

    override func rightMouseDown(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 1, button: 1, clickCount: UInt32(event.clickCount), modifiers: modifierMask(event.modifierFlags))
    }

    override func rightMouseUp(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        bridge.sendMouse(windowID: remoteWindowID, x: x, y: y, type: 2, button: 1, clickCount: UInt32(event.clickCount), modifiers: modifierMask(event.modifierFlags))
    }

    override func scrollWheel(with event: NSEvent) {
        let (x, y) = remotePoint(from: event)
        bridge.sendScroll(
            windowID: remoteWindowID,
            x: x,
            y: y,
            deltaX: Float(event.scrollingDeltaX),
            deltaY: Float(event.scrollingDeltaY),
            isContinuous: event.hasPreciseScrollingDeltas,
            modifiers: modifierMask(event.modifierFlags)
        )
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags
        // Shortcuts (Cmd/Ctrl) and control keys bypass IME and go straight as KeyEvents.
        let isShortcut = mods.contains(.command) || mods.contains(.control)
        let isControlKey = [36, 48, 51, 53, 123, 124, 125, 126].contains(Int(event.keyCode))
        if isShortcut || (isControlKey && !hasMarkedText()) {
            // Flush any brand-new local clipboard content BEFORE forwarding Cmd+V so paste is always up-to-date.
            if mods.contains(.command) && event.keyCode == 9 /* V */ {
                onBeforePasteShortcut?()
            }
            bridge.sendKey(
                windowID: remoteWindowID,
                keyCode: UInt32(event.keyCode),
                isDown: true,
                isRepeat: event.isARepeat,
                modifiers: modifierMask(mods)
            )
            return
        }
        // Route normal typing through macOS local Chinese/English IME!
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        let mods = event.modifierFlags
        let isShortcut = mods.contains(.command) || mods.contains(.control)
        let isControlKey = [36, 48, 51, 53, 123, 124, 125, 126].contains(Int(event.keyCode))
        if isShortcut || isControlKey {
            bridge.sendKey(
                windowID: remoteWindowID,
                keyCode: UInt32(event.keyCode),
                isDown: false,
                isRepeat: false,
                modifiers: modifierMask(mods)
            )
        }
    }

    // MARK: - NSTextInputClient (Native Local Chinese IME Support)

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedTextStorage = NSAttributedString()
        let text: String
        if let str = string as? String {
            text = str
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        if !text.isEmpty {
            bridge.sendTextCommit(windowID: remoteWindowID, text: text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attr = string as? NSAttributedString {
            markedTextStorage = attr
        } else if let str = string as? String {
            markedTextStorage = NSAttributedString(string: str)
        }
    }

    func unmarkText() {
        markedTextStorage = NSAttributedString()
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
    func markedRange() -> NSRange {
        markedTextStorage.length > 0 ? NSRange(location: 0, length: markedTextStorage.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { markedTextStorage.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let win = window else { return .zero }
        let mouseScreen = NSEvent.mouseLocation
        return NSRect(x: mouseScreen.x, y: mouseScreen.y, width: 1, height: 18).intersection(win.frame).isEmpty
            ? NSRect(x: win.frame.midX, y: win.frame.minY + 40, width: 1, height: 18)
            : NSRect(x: mouseScreen.x, y: mouseScreen.y, width: 1, height: 18)
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

/// Translucent floating titlebar capsule that appears only when hovering the top edge of a proxy window.
/// Dragging anywhere on the pill moves the window; includes buttons to close the remote window (Cmd+W) or close the local proxy window.
@MainActor
private final class HoverTitlebarView: NSVisualEffectView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeRemoteButton = NSButton()
    private let muteButton = NSButton()
    private let closeButton = NSButton()
    var onCloseClicked: (() -> Void)?
    var onCloseRemoteClicked: (() -> Void)?
    var onMuteClicked: (() -> Void)?

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 13
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .center
        addSubview(titleLabel)

        closeRemoteButton.bezelStyle = .inline
        closeRemoteButton.isBordered = false
        closeRemoteButton.title = " 关对端窗"
        closeRemoteButton.image = NSImage(systemSymbolName: "rectangle.badge.xmark", accessibilityDescription: "关闭对端软件窗口")
        closeRemoteButton.imagePosition = .imageLeading
        closeRemoteButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        closeRemoteButton.toolTip = "关闭被控端上的这个软件窗口 (⌘W)"
        closeRemoteButton.contentTintColor = .systemRed
        closeRemoteButton.target = self
        closeRemoteButton.action = #selector(handleCloseRemote)
        addSubview(closeRemoteButton)

        muteButton.bezelStyle = .inline
        muteButton.isBordered = false
        muteButton.title = ""
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "切换远端声音")
        muteButton.imagePosition = .imageOnly
        muteButton.toolTip = "远端声音已开启（点击静音）"
        muteButton.contentTintColor = .systemGreen
        muteButton.target = self
        muteButton.action = #selector(handleMute)
        addSubview(muteButton)

        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.title = " 关投屏"
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "仅关闭本机投屏窗口")
        closeButton.imagePosition = .imageLeading
        closeButton.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        closeButton.toolTip = "仅关闭本机投屏窗口（不关闭被控端软件）"
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setTitle(_ title: String) {
        titleLabel.stringValue = title
    }

    func setAudioMuted(_ muted: Bool) {
        muteButton.image = NSImage(
            systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: muted ? "取消静音远端声音" : "静音远端声音"
        )
        muteButton.contentTintColor = muted ? .secondaryLabelColor : .systemGreen
        muteButton.toolTip = muted ? "远端声音已静音（点击开启声音）" : "远端声音已开启（点击静音）"
    }

    func setFullDesktopMode(_ isDesktop: Bool) {
        closeRemoteButton.isHidden = isDesktop
        closeButton.title = isDesktop ? " 退出远程" : " 关投屏"
        closeButton.toolTip = isDesktop
            ? "退出整台电脑远程控制（不会关闭被控端任何软件）"
            : "仅关闭本机投屏窗口（不关闭被控端软件）"
        closeButton.contentTintColor = isDesktop ? .systemRed : .secondaryLabelColor
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let leftBtnW: CGFloat = closeRemoteButton.isHidden ? 0 : 74
        let muteBtnW: CGFloat = 24
        let rightBtnW: CGFloat = 64
        let btnH: CGFloat = 20
        if !closeRemoteButton.isHidden {
            closeRemoteButton.frame = NSRect(x: 8, y: (bounds.height - btnH) / 2, width: leftBtnW, height: btnH)
        }
        closeButton.frame = NSRect(x: bounds.width - rightBtnW - 8, y: (bounds.height - btnH) / 2, width: rightBtnW, height: btnH)
        muteButton.frame = NSRect(x: closeButton.frame.minX - muteBtnW - 4, y: (bounds.height - btnH) / 2, width: muteBtnW, height: btnH)
        let titleStartX = closeRemoteButton.isHidden ? 12 : (leftBtnW + 14)
        let titleEndX = muteButton.frame.minX - 6
        titleLabel.frame = NSRect(x: titleStartX, y: (bounds.height - 15) / 2, width: max(40, titleEndX - titleStartX), height: 15)
    }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func handleClose() {
        onCloseClicked?()
    }

    @objc private func handleCloseRemote() {
        onCloseRemoteClicked?()
    }

    @objc private func handleMute() {
        onMuteClicked?()
    }
}

/// Click-through translucent debug HUD in the bottom-left corner of the remote proxy window.
/// Displays live FPS, bitrate, actual H.264 encoded resolution & dynamic scale factor (e.g. 2.0x Retina vs 1.25x Motion Boost),
/// hardware VTDecompressionSession decode latency, and burst frame skip stats.
@MainActor
private final class DebugStatsHUDView: NSView {
    private let textLabel = NSTextField(labelWithString: "等待视频流...")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor

        textLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        textLabel.textColor = NSColor(calibratedRed: 0.45, green: 0.98, blue: 0.65, alpha: 1.0)
        textLabel.maximumNumberOfLines = 3
        textLabel.lineBreakMode = .byTruncatingTail
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        textLabel.frame = bounds.insetBy(dx: 8, dy: 6)
    }

    func update(with s: VideoStreamTelemetry, isIdle: Bool) {
        let fpsText = isIdle ? "0 FPS (静止省流)" : "收\(s.fps)/采\(s.hostFPS) FPS"
        let bitrateText = isIdle ? "0.00 Mbps" : String(format: "%.2f Mbps", s.bitrateMbps)
        let gapText = isIdle ? "间隔 -" : "最大间隔 \(s.maxGapMs)ms"
        let scaleMode = s.scaleRatio < 1.65 ? "动态加速" : "Retina超清"
        let line1 = "● \(fpsText) | \(bitrateText) | \(gapText)"
        let line2 = String(
            format: "%@: %d×%d (%.2fx %@) | 解码 %.2fms",
            s.codecName,
            s.encodedWidth,
            s.encodedHeight,
            s.scaleRatio,
            scaleMode,
            s.avgDecodeMs
        )
        let frameKB = max(1, s.lastFrameBytes / 1024)
        let frameKind = s.isLastKeyframe ? "IDR" : "P"
        let line3 = String(
            format: "逻辑: %d×%d pt | 帧: %dKB(%@)",
            s.logicalWidth,
            s.logicalHeight,
            frameKB,
            frameKind
        )
        textLabel.stringValue = "\(line1)\n\(line2)\n\(line3)"
    }
}

/// Translucent drop-zone overlay shown while dragging files/images over a remote proxy window.
@MainActor
private final class FileDropOverlayView: NSView {
    private let pill = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "松手发送文件到远端窗口")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.14).cgColor
        layer?.borderColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        layer?.borderWidth = 2.5
        layer?.cornerRadius = 10

        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 14
        pill.layer?.masksToBounds = true
        addSubview(pill)

        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.alignment = .center
        pill.addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setCount(_ count: Int, targetTitle: String? = nil) {
        let trimmed = (targetTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let targetDesc = trimmed.isEmpty ? "远端窗口" : "「\(trimmed)」"
        label.stringValue = count > 1 ? "松手发送 \(count) 个文件到\(targetDesc)" : "松手发送文件到\(targetDesc)"
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let fittingW = ceil(label.intrinsicContentSize.width) + 32
        let pw: CGFloat = min(max(220, fittingW), max(220, bounds.width - 40))
        let ph: CGFloat = 42
        pill.frame = NSRect(x: (bounds.width - pw) / 2, y: (bounds.height - ph) / 2, width: pw, height: ph)
        label.frame = NSRect(x: 12, y: (ph - 20) / 2, width: pw - 24, height: 20)
    }
}

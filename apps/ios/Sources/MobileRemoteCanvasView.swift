import SwiftUI
import UIKit

struct MobileRemoteCanvasView: UIViewRepresentable {
    let renderer: IOSVideoDisplayRenderer
    let aspectRatio: CGFloat
    let touchMode: TouchControlMode
    let videoFitMode: VideoFitMode
    let isImmersive: Bool
    let cursorPos: CGPoint
    let cursorKind: String
    let activePopovers: [WindowTopologyItem]
    let parentLogicalSize: CGSize
    let popoverRenderers: [UInt32: IOSVideoDisplayRenderer]
    let resetToken: Int
    let zoomCommandScale: CGFloat
    let zoomCommandToken: Int

    let onZoomChanged: (CGFloat) -> Void
    let onCursorPosChanged: (CGPoint) -> Void
    let onMouseEvent: (_ nx: CGFloat, _ ny: CGFloat, _ type: UInt8, _ button: UInt32, _ clickCount: UInt32) -> Void
    let onScrollEvent: (_ nx: CGFloat, _ ny: CGFloat, _ dx: Float, _ dy: Float) -> Void
    let onGestureBadgeChanged: (String?) -> Void
    let onToggleKeyboard: () -> Void
    let onToggleToolbar: () -> Void

    func makeUIView(context: Context) -> RemoteCanvasContainerView {
        let view = RemoteCanvasContainerView(renderer: renderer)
        applyCallbacks(to: view)
        view.updateConfiguration(
            aspectRatio: aspectRatio,
            touchMode: touchMode,
            videoFitMode: videoFitMode,
            isImmersive: isImmersive,
            cursorPos: cursorPos,
            cursorKind: cursorKind,
            activePopovers: activePopovers,
            parentLogicalSize: parentLogicalSize,
            popoverRenderers: popoverRenderers,
            resetToken: resetToken,
            zoomCommandScale: zoomCommandScale,
            zoomCommandToken: zoomCommandToken
        )
        return view
    }

    func updateUIView(_ uiView: RemoteCanvasContainerView, context: Context) {
        applyCallbacks(to: uiView)
        uiView.updateConfiguration(
            aspectRatio: aspectRatio,
            touchMode: touchMode,
            videoFitMode: videoFitMode,
            isImmersive: isImmersive,
            cursorPos: cursorPos,
            cursorKind: cursorKind,
            activePopovers: activePopovers,
            parentLogicalSize: parentLogicalSize,
            popoverRenderers: popoverRenderers,
            resetToken: resetToken,
            zoomCommandScale: zoomCommandScale,
            zoomCommandToken: zoomCommandToken
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: RemoteCanvasContainerView,
        context: Context
    ) -> CGSize? {
        if let w = proposal.width, let h = proposal.height, w.isFinite, h.isFinite {
            return CGSize(width: w, height: h)
        }
        let width = (proposal.width?.isFinite == true) ? proposal.width! : uiView.bounds.width
        let height = (proposal.height?.isFinite == true) ? proposal.height! : uiView.bounds.height
        return CGSize(width: width, height: height)
    }

    private func applyCallbacks(to view: RemoteCanvasContainerView) {
        view.onZoomChanged = onZoomChanged
        view.onCursorPosChanged = onCursorPosChanged
        view.onMouseEvent = onMouseEvent
        view.onScrollEvent = onScrollEvent
        view.onGestureBadgeChanged = onGestureBadgeChanged
        view.onToggleKeyboard = onToggleKeyboard
        view.onToggleToolbar = onToggleToolbar
    }
}

/// Recognizes "Hold 1st finger stationary + Tap 2nd finger" as a secondary (Right) click.
private final class HoldTapSecondaryClickRecognizer: UIGestureRecognizer {
    private var primaryTouch: UITouch?
    private var primaryStartPoint: CGPoint = .zero
    private var primaryBeganAt: CFAbsoluteTime = 0
    private var secondaryTouch: UITouch?
    private var secondaryStartPoint: CGPoint = .zero
    private var secondaryBeganAt: CFAbsoluteTime = 0

    private(set) var primaryLocationInView: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        let now = CFAbsoluteTimeGetCurrent()

        if primaryTouch == nil {
            guard touches.count == 1, let first = touches.first else {
                state = .failed
                return
            }
            primaryTouch = first
            primaryStartPoint = first.location(in: view)
            primaryBeganAt = now
            return
        }

        if secondaryTouch == nil {
            guard touches.count == 1, let second = touches.first, now - primaryBeganAt >= 0.05 else {
                state = .failed
                return
            }
            secondaryTouch = second
            secondaryStartPoint = second.location(in: view)
            secondaryBeganAt = now
            return
        }

        state = .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        if let prim = primaryTouch, touches.contains(prim) {
            let p = prim.location(in: view)
            if hypot(p.x - primaryStartPoint.x, p.y - primaryStartPoint.y) > 20 {
                state = .failed
                return
            }
        }
        if let sec = secondaryTouch, touches.contains(sec) {
            let p = sec.location(in: view)
            if hypot(p.x - secondaryStartPoint.x, p.y - secondaryStartPoint.y) > 20 {
                state = .failed
                return
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        let now = CFAbsoluteTimeGetCurrent()

        if let sec = secondaryTouch, touches.contains(sec) {
            if let prim = primaryTouch, !touches.contains(prim), now - secondaryBeganAt <= 0.32 {
                primaryLocationInView = prim.location(in: view)
                state = .recognized
            } else {
                state = .failed
            }
            return
        }

        if let prim = primaryTouch, touches.contains(prim) {
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = .failed
    }

    override func reset() {
        super.reset()
        primaryTouch = nil
        secondaryTouch = nil
        primaryStartPoint = .zero
        secondaryStartPoint = .zero
        primaryBeganAt = 0
        secondaryBeganAt = 0
    }
}

final class RemoteCanvasContainerView: UIView, UIGestureRecognizerDelegate {
    private let renderer: IOSVideoDisplayRenderer
    private let videoHostView = UIView()
    private let cursorView = UIImageView()

    private var aspectRatio: CGFloat = 16.0 / 10.0
    private var touchMode: TouchControlMode = .directTouch
    private var videoFitMode: VideoFitMode = .fit
    private var isImmersive: Bool = false
    private var cursorPos: CGPoint = CGPoint(x: 0.5, y: 0.5)
    private var cursorKind: String = "arrow"
    private var lastResetToken: Int = -1
    private var lastZoomCommandToken: Int = -1

    // Floating kind==2 popover video overlays
    private var activePopovers: [WindowTopologyItem] = []
    private var parentLogicalSize: CGSize = CGSize(width: 960, height: 600)
    private var popoverRenderers: [UInt32: IOSVideoDisplayRenderer] = [:]
    private var popoverViews: [UInt32: UIView] = [:]

    private var zoomScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero
    private var pinchStartScale: CGFloat = 1.0
    private var isActivelyPinching: Bool = false

    private var lastSingleTapEndedAt: CFAbsoluteTime = 0
    private var lastSingleTapPoint: CGPoint = .zero
    private var isDraggingRemoteMouse: Bool = false
    private var isDoubleTapHoldDragging: Bool = false

    private var longPressStartLocation: CGPoint = .zero
    private var longPressLastLocation: CGPoint = .zero
    private var isLongPressDragging: Bool = false
    private var suppressLongPressRightClick: Bool = false

    private var longPressRecognizer: UILongPressGestureRecognizer!
    private var pinchRecognizer: UIPinchGestureRecognizer!
    private var twoFingerPanRecognizer: UIPanGestureRecognizer!
    private var holdTapSecondaryRecognizer: HoldTapSecondaryClickRecognizer!
    private var badgeClearWorkItem: DispatchWorkItem?

    var onZoomChanged: ((CGFloat) -> Void)?
    var onCursorPosChanged: ((CGPoint) -> Void)?
    var onMouseEvent: ((_ nx: CGFloat, _ ny: CGFloat, _ type: UInt8, _ button: UInt32, _ clickCount: UInt32) -> Void)?
    var onScrollEvent: ((_ nx: CGFloat, _ ny: CGFloat, _ dx: Float, _ dy: Float) -> Void)?
    var onGestureBadgeChanged: ((String?) -> Void)?
    var onToggleKeyboard: (() -> Void)?
    var onToggleToolbar: (() -> Void)?

    private static let minZoom: CGFloat = 1.0
    private static let maxZoom: CGFloat = 5.0
    private static let trackpadSensitivity: CGFloat = 1.35
    private static let obsidianBg = UIColor(red: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1.0)
    private static let popoverBorderColor = UIColor(red: 63.0 / 255.0, green: 63.0 / 255.0, blue: 70.0 / 255.0, alpha: 1.0)
    private static let popoverSurfaceColor = UIColor(red: 22.0 / 255.0, green: 22.0 / 255.0, blue: 26.0 / 255.0, alpha: 1.0)

    init(renderer: IOSVideoDisplayRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        backgroundColor = Self.obsidianBg
        clipsToBounds = true
        isMultipleTouchEnabled = true

        videoHostView.backgroundColor = .black
        videoHostView.clipsToBounds = true
        videoHostView.layer.cornerRadius = 4
        addSubview(videoHostView)

        attachDisplayLayerIfNeeded()

        cursorView.contentMode = .scaleAspectFit
        cursorView.tintColor = .white
        cursorView.layer.shadowColor = UIColor.black.cgColor
        cursorView.layer.shadowOpacity = 0.85
        cursorView.layer.shadowRadius = 2.5
        cursorView.layer.shadowOffset = CGSize(width: 0, height: 1)
        cursorView.isUserInteractionEnabled = false
        cursorView.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        videoHostView.addSubview(cursorView)

        setupGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.size != bounds.size {
                setNeedsLayout()
                layoutIfNeeded()
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            attachDisplayLayerIfNeeded()
            setNeedsLayout()
            layoutIfNeeded()
        }
    }

    private func attachDisplayLayerIfNeeded() {
        renderer.configureOnMainActor(videoFitMode: videoFitMode)
        if renderer.displayLayer.superlayer !== videoHostView.layer {
            renderer.displayLayer.removeFromSuperlayer()
            videoHostView.layer.insertSublayer(renderer.displayLayer, at: 0)
        }
        if videoHostView.bounds.width > 1 && videoHostView.bounds.height > 1 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.displayLayer.frame = videoHostView.bounds
            CATransaction.commit()
        }
    }

    private func setupGestures() {
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.numberOfTouchesRequired = 1
        singleTap.delegate = self

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
        twoFingerTap.numberOfTapsRequired = 1
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.delegate = self

        let holdTapSecondary = HoldTapSecondaryClickRecognizer(
            target: self,
            action: #selector(handleHoldTapSecondaryClick(_:))
        )
        holdTapSecondary.cancelsTouchesInView = false
        holdTapSecondary.delegate = self
        holdTapSecondaryRecognizer = holdTapSecondary

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.30
        longPress.allowableMovement = 14
        longPress.numberOfTouchesRequired = 1
        longPress.delegate = self
        longPressRecognizer = longPress

        let oneFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleOneFingerPan(_:)))
        oneFingerPan.minimumNumberOfTouches = 1
        oneFingerPan.maximumNumberOfTouches = 1
        oneFingerPan.delegate = self

        let twoFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        twoFingerPanRecognizer = twoFingerPan

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        pinchRecognizer = pinch

        let threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
        threeFingerTap.numberOfTapsRequired = 1
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.delegate = self

        let threeFingerSwipeUp = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
        threeFingerSwipeUp.numberOfTouchesRequired = 3
        threeFingerSwipeUp.direction = .up
        threeFingerSwipeUp.delegate = self

        let threeFingerSwipeDown = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe(_:)))
        threeFingerSwipeDown.numberOfTouchesRequired = 3
        threeFingerSwipeDown.direction = .down
        threeFingerSwipeDown.delegate = self

        [
            singleTap, twoFingerTap, holdTapSecondary, longPress,
            oneFingerPan, twoFingerPan, pinch,
            threeFingerTap, threeFingerSwipeUp, threeFingerSwipeDown
        ].forEach { addGestureRecognizer($0) }
    }

    func updateConfiguration(
        aspectRatio: CGFloat,
        touchMode: TouchControlMode,
        videoFitMode: VideoFitMode,
        isImmersive: Bool,
        cursorPos: CGPoint,
        cursorKind: String,
        activePopovers: [WindowTopologyItem],
        parentLogicalSize: CGSize,
        popoverRenderers: [UInt32: IOSVideoDisplayRenderer],
        resetToken: Int,
        zoomCommandScale: CGFloat,
        zoomCommandToken: Int
    ) {
        let validAspect = aspectRatio.isFinite && aspectRatio > 0.1 ? aspectRatio : (16.0 / 10.0)
        let aspectChanged = abs(self.aspectRatio - validAspect) > 0.005
        let fitModeChanged = (self.videoFitMode != videoFitMode)
        let immersiveChanged = (self.isImmersive != isImmersive)

        self.aspectRatio = validAspect
        self.touchMode = touchMode
        self.videoFitMode = videoFitMode
        self.isImmersive = isImmersive
        self.cursorPos = cursorPos
        self.activePopovers = activePopovers
        self.parentLogicalSize = parentLogicalSize
        self.popoverRenderers = popoverRenderers

        if window != nil && renderer.displayLayer.superlayer !== videoHostView.layer {
            attachDisplayLayerIfNeeded()
            setNeedsLayout()
        }

        if fitModeChanged {
            renderer.setVideoFitMode(videoFitMode)
        }

        if immersiveChanged {
            backgroundColor = isImmersive ? .black : Self.obsidianBg
            videoHostView.layer.cornerRadius = isImmersive ? 0 : 4
        }

        if self.cursorKind != cursorKind {
            self.cursorKind = cursorKind
            updateCursorGlyph()
        } else if cursorView.image == nil {
            updateCursorGlyph()
        }

        if resetToken != lastResetToken {
            lastResetToken = resetToken
            if zoomScale != 1.0 || panOffset != .zero {
                zoomScale = 1.0
                panOffset = .zero
                applyVideoTransform()
            }
        } else if zoomCommandToken != lastZoomCommandToken {
            lastZoomCommandToken = zoomCommandToken
            let clamped = min(max(zoomCommandScale, Self.minZoom), Self.maxZoom)
            if abs(zoomScale - clamped) > 0.005 {
                zoomScale = clamped
                if zoomScale <= 1.01 {
                    zoomScale = 1.0
                    panOffset = .zero
                } else {
                    clampPanOffset()
                }
                UIView.animate(withDuration: 0.16) {
                    self.applyVideoTransform()
                }
            }
        }

        cursorView.isHidden = (touchMode != .trackpad)
        if aspectChanged || fitModeChanged || immersiveChanged {
            setNeedsLayout()
        } else {
            syncPopovers()
            layoutCursorOverlay()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let fitted = (videoFitMode == .fill)
            ? aspectFillRect(aspect: aspectRatio, in: bounds)
            : aspectFitRect(aspect: aspectRatio, in: bounds)
        videoHostView.transform = .identity
        videoHostView.frame = fitted
        if renderer.displayLayer.superlayer === videoHostView.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            renderer.displayLayer.frame = videoHostView.bounds
            CATransaction.commit()
        }
        syncPopovers()
        clampPanOffset()
        applyVideoTransform()
        layoutCursorOverlay()
    }

    private func syncPopovers() {
        let activeIDs = Set(activePopovers.map(\.window_id))
        for (winID, view) in popoverViews where !activeIDs.contains(winID) {
            view.removeFromSuperview()
            popoverViews.removeValue(forKey: winID)
        }

        let hostW = videoHostView.bounds.width
        let hostH = videoHostView.bounds.height
        let parentW = max(parentLogicalSize.width, 1)
        let parentH = max(parentLogicalSize.height, 1)

        for pop in activePopovers {
            guard let popRenderer = popoverRenderers[pop.window_id] else { continue }
            let popView: UIView
            if let existing = popoverViews[pop.window_id] {
                popView = existing
            } else {
                let v = UIView()
                v.isUserInteractionEnabled = false
                v.backgroundColor = Self.popoverSurfaceColor
                v.layer.cornerRadius = 6
                v.layer.borderWidth = 1
                v.layer.borderColor = Self.popoverBorderColor.cgColor
                v.layer.shadowColor = UIColor.black.cgColor
                v.layer.shadowOpacity = 0.48
                v.layer.shadowRadius = 8
                v.layer.shadowOffset = CGSize(width: 0, height: 4)
                v.layer.masksToBounds = false
                videoHostView.insertSubview(v, belowSubview: cursorView)
                popoverViews[pop.window_id] = v
                popView = v
            }

            if popRenderer.displayLayer.superlayer !== popView.layer {
                popRenderer.configureOnMainActor(videoFitMode: .fit)
                popRenderer.displayLayer.removeFromSuperlayer()
                popRenderer.displayLayer.cornerRadius = 6
                popRenderer.displayLayer.masksToBounds = true
                popView.layer.addSublayer(popRenderer.displayLayer)
            }

            guard hostW > 1, hostH > 1 else { continue }
            let wFrac = min(max(CGFloat(pop.width) / parentW, 0.06), 1.0)
            let hFrac = min(max(CGFloat(pop.height) / parentH, 0.05), 1.0)
            let xFrac = min(max(CGFloat(pop.rel_x) / parentW, 0), max(0, 1.0 - wFrac))
            let yFrac = min(max(CGFloat(pop.rel_y) / parentH, 0), max(0, 1.0 - hFrac))

            popView.frame = CGRect(
                x: xFrac * hostW,
                y: yFrac * hostH,
                width: wFrac * hostW,
                height: hFrac * hostH
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            popRenderer.displayLayer.frame = popView.bounds
            CATransaction.commit()
        }

        // Always keep virtual cursor floating above all popovers
        videoHostView.bringSubviewToFront(cursorView)
    }

    private func aspectFitRect(aspect: CGFloat, in container: CGRect) -> CGRect {
        guard container.width > 1, container.height > 1 else { return container }
        let containerAspect = container.width / container.height
        let targetW: CGFloat = containerAspect > aspect ? container.height * aspect : container.width
        let targetH: CGFloat = containerAspect > aspect ? container.height : container.width / aspect
        return CGRect(
            x: (container.width - targetW) * 0.5,
            y: (container.height - targetH) * 0.5,
            width: targetW,
            height: targetH
        )
    }

    private func aspectFillRect(aspect: CGFloat, in container: CGRect) -> CGRect {
        guard container.width > 1, container.height > 1 else { return container }
        let containerAspect = container.width / container.height
        let targetW: CGFloat = containerAspect > aspect ? container.width : container.height * aspect
        let targetH: CGFloat = containerAspect > aspect ? container.width / aspect : container.height
        return CGRect(
            x: (container.width - targetW) * 0.5,
            y: (container.height - targetH) * 0.5,
            width: targetW,
            height: targetH
        )
    }

    private func clampPanOffset() {
        let scaledW = videoHostView.bounds.width * zoomScale
        let scaledH = videoHostView.bounds.height * zoomScale
        if zoomScale <= 1.01 && videoFitMode == .fit {
            panOffset = .zero
            return
        }
        let extraMargin: CGFloat = zoomScale > 1.01 ? 48 : 0
        let maxX = max(0, (scaledW - bounds.width) * 0.5 + extraMargin)
        let maxY = max(0, (scaledH - bounds.height) * 0.5 + extraMargin)
        panOffset.x = min(max(panOffset.x, -maxX), maxX)
        panOffset.y = min(max(panOffset.y, -maxY), maxY)
    }

    private func applyVideoTransform() {
        videoHostView.transform = CGAffineTransform(translationX: panOffset.x, y: panOffset.y)
            .scaledBy(x: zoomScale, y: zoomScale)
    }

    private func updateCursorGlyph() {
        let symbolName: String
        switch cursorKind {
        case "ibeam": symbolName = "text.cursor"
        case "pointing_hand": symbolName = "hand.point.up.left.fill"
        default: symbolName = "cursorarrow"
        }
        let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        cursorView.image = UIImage(systemName: symbolName, withConfiguration: cfg)
    }

    private func layoutCursorOverlay() {
        let w = videoHostView.bounds.width
        let h = videoHostView.bounds.height
        guard w > 1, h > 1 else { return }
        let px = min(max(cursorPos.x, 0), 1) * w
        let py = min(max(cursorPos.y, 0), 1) * h
        if cursorKind == "ibeam" {
            cursorView.center = CGPoint(x: px, y: py)
        } else {
            cursorView.frame = CGRect(x: px - 3, y: py - 2, width: 22, height: 22)
        }
    }

    private func normalizedPoint(from gesture: UIGestureRecognizer) -> CGPoint {
        normalizedPoint(atSelfPoint: gesture.location(in: self))
    }

    private func normalizedPoint(atSelfPoint ptInSelf: CGPoint) -> CGPoint {
        let pt = convert(ptInSelf, to: videoHostView)
        let w = max(videoHostView.bounds.width, 1)
        let h = max(videoHostView.bounds.height, 1)
        return CGPoint(x: min(max(pt.x / w, 0), 1), y: min(max(pt.y / h, 0), 1))
    }

    private func moveTrackpadCursor(by delta: CGPoint) {
        let w = max(videoHostView.bounds.width, 1)
        let h = max(videoHostView.bounds.height, 1)
        cursorPos = CGPoint(
            x: min(max(cursorPos.x + (delta.x * Self.trackpadSensitivity) / w, 0), 1),
            y: min(max(cursorPos.y + (delta.y * Self.trackpadSensitivity) / h, 0), 1)
        )
        layoutCursorOverlay()
        autoPanViewportForCursorIfNeeded()
        onCursorPosChanged?(cursorPos)
    }

    private func autoPanViewportForCursorIfNeeded() {
        guard zoomScale > 1.03 else { return }
        let w = videoHostView.bounds.width
        let h = videoHostView.bounds.height
        guard w > 1, h > 1, bounds.width > 1, bounds.height > 1 else { return }

        let ptInSelf = videoHostView.convert(CGPoint(x: cursorPos.x * w, y: cursorPos.y * h), to: self)
        let margin = min(max(min(bounds.width, bounds.height) * 0.14, 32), 64)

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if ptInSelf.x < margin { dx = (margin - ptInSelf.x) * 0.7 }
        else if ptInSelf.x > bounds.width - margin { dx = -(ptInSelf.x - (bounds.width - margin)) * 0.7 }
        if ptInSelf.y < margin { dy = (margin - ptInSelf.y) * 0.7 }
        else if ptInSelf.y > bounds.height - margin { dy = -(ptInSelf.y - (bounds.height - margin)) * 0.7 }

        if abs(dx) > 0.2 || abs(dy) > 0.2 {
            panOffset.x += dx
            panOffset.y += dy
            clampPanOffset()
            applyVideoTransform()
        }
    }

    private func showBadge(_ text: String?, autoClearAfter seconds: TimeInterval? = nil) {
        badgeClearWorkItem?.cancel()
        badgeClearWorkItem = nil
        onGestureBadgeChanged?(text)
        if let seconds, text != nil {
            let item = DispatchWorkItem { [weak self] in
                self?.onGestureBadgeChanged?(nil)
            }
            badgeClearWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        }
    }

    private func emitRightClick(at target: CGPoint, haptic: Bool = true) {
        if haptic {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        onMouseEvent?(target.x, target.y, 0, 1, 0)
        onMouseEvent?(target.x, target.y, 1, 1, 1)
        onMouseEvent?(target.x, target.y, 2, 1, 1)
        showBadge("右键", autoClearAfter: 0.55)
    }

    // MARK: - Gesture Handlers

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let screenPt = gesture.location(in: self)
        let isDoubleClick = (now - lastSingleTapEndedAt < 0.34
            && hypot(screenPt.x - lastSingleTapPoint.x, screenPt.y - lastSingleTapPoint.y) < 38)
        let clickCount: UInt32 = isDoubleClick ? 2 : 1
        lastSingleTapEndedAt = now
        lastSingleTapPoint = screenPt

        let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
        onMouseEvent?(target.x, target.y, 0, 0, 0)
        onMouseEvent?(target.x, target.y, 1, 0, clickCount)
        onMouseEvent?(target.x, target.y, 2, 0, clickCount)
    }

    @objc private func handleTwoFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
        emitRightClick(at: target, haptic: true)
    }

    @objc private func handleHoldTapSecondaryClick(_ gesture: HoldTapSecondaryClickRecognizer) {
        guard gesture.state == .recognized else { return }
        suppressLongPressRightClick = true
        if longPressRecognizer.state == .began || longPressRecognizer.state == .changed {
            longPressRecognizer.isEnabled = false
            longPressRecognizer.isEnabled = true
        }
        let target: CGPoint = (touchMode == .trackpad)
            ? cursorPos
            : normalizedPoint(atSelfPoint: gesture.primaryLocationInView)
        emitRightClick(at: target, haptic: true)
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            suppressLongPressRightClick = false
            isLongPressDragging = false
            longPressStartLocation = gesture.location(in: self)
            longPressLastLocation = longPressStartLocation
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            showBadge("拖拽中 / 抬起右键")

        case .changed:
            guard !suppressLongPressRightClick else { return }
            let currentLoc = gesture.location(in: self)
            if !isLongPressDragging {
                guard hypot(currentLoc.x - longPressStartLocation.x, currentLoc.y - longPressStartLocation.y) > 6.0 else { return }
                isLongPressDragging = true
                showBadge("左键拖拽中")
                let startTarget: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(atSelfPoint: longPressStartLocation)
                onMouseEvent?(startTarget.x, startTarget.y, 0, 0, 0)
                onMouseEvent?(startTarget.x, startTarget.y, 1, 0, 1)
                let delta = CGPoint(x: currentLoc.x - longPressStartLocation.x, y: currentLoc.y - longPressStartLocation.y)
                longPressLastLocation = currentLoc
                emitDragMove(currentLoc: currentLoc, delta: delta)
            } else {
                let delta = CGPoint(x: currentLoc.x - longPressLastLocation.x, y: currentLoc.y - longPressLastLocation.y)
                longPressLastLocation = currentLoc
                emitDragMove(currentLoc: currentLoc, delta: delta)
            }

        case .ended, .cancelled, .failed:
            if isLongPressDragging {
                isLongPressDragging = false
                let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
                onMouseEvent?(target.x, target.y, 2, 0, 1)
                showBadge(nil)
            } else if gesture.state == .ended && !suppressLongPressRightClick {
                let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
                emitRightClick(at: target, haptic: false)
            } else {
                showBadge(nil)
            }
            suppressLongPressRightClick = false

        default:
            break
        }
    }

    private func emitDragMove(currentLoc: CGPoint, delta: CGPoint) {
        if touchMode == .trackpad {
            moveTrackpadCursor(by: delta)
            onMouseEvent?(cursorPos.x, cursorPos.y, 3, 0, 1)
        } else {
            let pt = normalizedPoint(atSelfPoint: currentLoc)
            onMouseEvent?(pt.x, pt.y, 3, 0, 1)
        }
    }

    @objc private func handleOneFingerPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            let now = CFAbsoluteTimeGetCurrent()
            let startPt = gesture.location(in: self)
            if now - lastSingleTapEndedAt < 0.30
                && hypot(startPt.x - lastSingleTapPoint.x, startPt.y - lastSingleTapPoint.y) < 44 {
                isDoubleTapHoldDragging = true
                lastSingleTapEndedAt = 0
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showBadge("双击拖拽中")
                let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
                onMouseEvent?(target.x, target.y, 0, 0, 0)
                onMouseEvent?(target.x, target.y, 1, 0, 1)
                gesture.setTranslation(.zero, in: self)
                return
            }

            isDoubleTapHoldDragging = false
            switch touchMode {
            case .directTouch:
                if zoomScale > 1.03 {
                    isDraggingRemoteMouse = false
                } else {
                    let pt = normalizedPoint(from: gesture)
                    isDraggingRemoteMouse = true
                    onMouseEvent?(pt.x, pt.y, 0, 0, 0)
                    onMouseEvent?(pt.x, pt.y, 1, 0, 1)
                }
            case .trackpad:
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                moveTrackpadCursor(by: delta)
                onMouseEvent?(cursorPos.x, cursorPos.y, 0, 0, 0)
            }

        case .changed:
            if isDoubleTapHoldDragging {
                if touchMode == .trackpad {
                    let delta = gesture.translation(in: self)
                    gesture.setTranslation(.zero, in: self)
                    moveTrackpadCursor(by: delta)
                    onMouseEvent?(cursorPos.x, cursorPos.y, 3, 0, 1)
                } else {
                    let pt = normalizedPoint(from: gesture)
                    onMouseEvent?(pt.x, pt.y, 3, 0, 1)
                }
                return
            }

            switch touchMode {
            case .directTouch:
                if zoomScale > 1.03 && !isDraggingRemoteMouse {
                    let delta = gesture.translation(in: self)
                    gesture.setTranslation(.zero, in: self)
                    panOffset.x += delta.x
                    panOffset.y += delta.y
                    clampPanOffset()
                    applyVideoTransform()
                } else if isDraggingRemoteMouse {
                    let pt = normalizedPoint(from: gesture)
                    onMouseEvent?(pt.x, pt.y, 3, 0, 1)
                }
            case .trackpad:
                let delta = gesture.translation(in: self)
                gesture.setTranslation(.zero, in: self)
                moveTrackpadCursor(by: delta)
                onMouseEvent?(cursorPos.x, cursorPos.y, 0, 0, 0)
            }

        case .ended, .cancelled, .failed:
            if isDoubleTapHoldDragging {
                isDoubleTapHoldDragging = false
                let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
                onMouseEvent?(target.x, target.y, 2, 0, 1)
                showBadge(nil)
            } else if isDraggingRemoteMouse {
                isDraggingRemoteMouse = false
                let pt = normalizedPoint(from: gesture)
                onMouseEvent?(pt.x, pt.y, 2, 0, 1)
            }

        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .changed else { return }
        let delta = gesture.translation(in: self)
        gesture.setTranslation(.zero, in: self)

        let pinchDelta = abs(pinchRecognizer.scale - 1.0)
        if isActivelyPinching || (pinchRecognizer.state == .changed && pinchDelta > 0.06) {
            return
        }

        let target: CGPoint = (touchMode == .trackpad) ? cursorPos : normalizedPoint(from: gesture)
        let scale: Float = 1.6
        onScrollEvent?(target.x, target.y, Float(delta.x) * scale, Float(delta.y) * scale)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchStartScale = zoomScale
            isActivelyPinching = false
        case .changed:
            if abs(gesture.scale - 1.0) > 0.06 {
                isActivelyPinching = true
            }
            guard isActivelyPinching else { return }
            zoomScale = min(max(pinchStartScale * gesture.scale, Self.minZoom), Self.maxZoom)
            clampPanOffset()
            applyVideoTransform()
            onZoomChanged?(zoomScale)
        case .ended, .cancelled, .failed:
            isActivelyPinching = false
            if zoomScale < 1.04 {
                zoomScale = 1.0
                panOffset = .zero
                UIView.animate(withDuration: 0.18) { self.applyVideoTransform() }
                onZoomChanged?(1.0)
            }
        default:
            break
        }
    }

    @objc private func handleThreeFingerTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onToggleKeyboard?()
    }

    @objc private func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        onToggleToolbar?()
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        if (gestureRecognizer === pinchRecognizer && otherGestureRecognizer === twoFingerPanRecognizer)
            || (gestureRecognizer === twoFingerPanRecognizer && otherGestureRecognizer === pinchRecognizer) {
            return true
        }
        if (gestureRecognizer === holdTapSecondaryRecognizer && otherGestureRecognizer === longPressRecognizer)
            || (gestureRecognizer === longPressRecognizer && otherGestureRecognizer === holdTapSecondaryRecognizer) {
            return true
        }
        return false
    }
}

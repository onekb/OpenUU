import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// Injects remote mouse, scroll, keyboard, and Unicode IME text events into the target macOS window.
final class InputInjector: @unchecked Sendable {
    private var targetWindowID: CGWindowID = 0
    private var targetPID: pid_t = 0
    private var fallbackFrame: CGRect = .zero
    private var virtualDisplayID: CGDirectDisplayID = 0
    private var windowContentInsets: [CGWindowID: CGPoint] = [:]
    private let injectQueue = DispatchQueue(label: "ren.onekb.openuu.input", qos: .userInteractive)
    private var savedHostCursorPosition: CGPoint?
    private var lastKnownHostCursorPosition: CGPoint?
    private var pendingCursorRestore: DispatchWorkItem?
    private var isRemoteMouseButtonDown: Bool = false
    private var lastMouseDownPostedAt: CFAbsoluteTime = 0
    private var lastMouseEventPoint: CGPoint?
    private var dragPasteboardBaselineCount: Int = 0
    private var dragOutEmittedForCurrentDrag: Bool = false
    private var suppressedCmdWKeyUpWindowID: CGWindowID = 0
    private var lastHoverTime: CFAbsoluteTime = 0
    private var lastCursorKind: String = ""
    var silentMode: Bool = true
    var hoverCursorSync: Bool = true
    var onDebugLog: ((String) -> Void)?
    var onCursorKindChanged: ((String) -> Void)?
    var onWindowResized: ((UInt32) -> Void)?
    var onNormalWindowInteracted: ((UInt32) -> Void)?
    var onDragOutFilesDetected: (([URL]) -> Void)?

    static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        if prompt {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }

    func setVirtualDisplayID(_ displayID: CGDirectDisplayID) {
        injectQueue.async { [weak self] in
            self?.virtualDisplayID = displayID
        }
    }

    func setContentInset(for windowID: CGWindowID, inset: CGPoint) {
        injectQueue.async { [weak self] in
            self?.windowContentInsets[windowID] = inset
        }
    }

    func setTargetWindow(_ window: SCWindow?) {
        injectQueue.async { [weak self] in
            guard let self else { return }
            guard let window else {
                self.targetWindowID = 0
                self.targetPID = 0
                self.fallbackFrame = .zero
                return
            }
            self.targetWindowID = window.windowID
            self.targetPID = window.owningApplication?.processID ?? 0
            self.fallbackFrame = window.frame
        }
    }

    /// Dynamically resolve the owning PID, live screen-space frame, and window layer for ANY windowID.
    private func resolveWindowTarget(for windowID: CGWindowID) -> (pid: pid_t, frame: CGRect, layer: Int)? {
        let lookupID = windowID != 0 ? windowID : targetWindowID
        guard lookupID != 0,
              let infoList = CGWindowListCopyWindowInfo([.optionIncludingWindow], lookupID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict) else {
            if targetPID != 0 {
                return (targetPID, fallbackFrame, 0)
            }
            return nil
        }
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? targetPID
        if ownerPID == 0 { return nil }
        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        return (pid_t(ownerPID), rect, layer)
    }

    private func activeVirtualDisplayBounds() -> CGRect? {
        guard virtualDisplayID != 0 else { return nil }
        let bounds = CGDisplayBounds(virtualDisplayID)
        guard bounds.width > 0, bounds.height > 0, CGDisplayCopyDisplayMode(virtualDisplayID) != nil else {
            return nil
        }
        return bounds
    }

    private func isPointOnVirtualDisplay(_ point: CGPoint) -> Bool {
        guard let vBounds = activeVirtualDisplayBounds() else { return false }
        return vBounds.contains(point)
    }

    private func captureHostCursorBeforeWarp() {
        pendingCursorRestore?.cancel()
        pendingCursorRestore = nil

        if let cur = CGEvent(source: nil)?.location, !isPointOnVirtualDisplay(cur) {
            lastKnownHostCursorPosition = cur
            if savedHostCursorPosition == nil {
                savedHostCursorPosition = cur
            }
        } else if savedHostCursorPosition == nil {
            let main = CGDisplayBounds(CGMainDisplayID())
            savedHostCursorPosition = lastKnownHostCursorPosition ?? CGPoint(x: main.midX, y: main.midY)
        }
    }

    private func targetAppHasOpenFloatingPopover() -> Bool {
        guard targetPID != 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == targetPID else { return false }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer > 0 && layer <= 1000 else { return false }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
                return false
            }
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return false }
            if layer >= 100 {
                // Native NSMenu context menus (including single-item Copy/Paste ~52x26pt)
                return rect.width >= 42 && rect.height >= 22 && (rect.width >= 50 || rect.height >= 36)
            }
            // Custom app popovers (e.g. WeChat emoji picker / sticker hover preview); exclude tiny idle
            // placeholder overlays (~50x24pt) kept permanently on-screen at layer 3 by WeChat!
            return rect.width >= 84 && rect.height >= 48
        }
    }

    private func scheduleHostCursorRestore(delayMs: Int = 25, forceEvenIfPopoverOpen: Bool = false) {
        guard silentMode || activeVirtualDisplayBounds() != nil else {
            savedHostCursorPosition = nil
            return
        }
        pendingCursorRestore?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCursorRestore = nil
            guard !self.isRemoteMouseButtonDown, let target = self.savedHostCursorPosition else { return }
            // If a floating popover (e.g. WeChat emoji picker / sticker hover preview) is currently open,
            // do NOT warp the cursor away yet — warping off the virtual display sends `mouseExited` to the
            // popover and prevents or dismisses the sticker hover preview! Re-check until the popover closes.
            if !forceEvenIfPopoverOpen && self.targetAppHasOpenFloatingPopover() {
                self.scheduleHostCursorRestore(delayMs: 350, forceEvenIfPopoverOpen: false)
                return
            }
            self.savedHostCursorPosition = nil
            CGWarpMouseCursorPosition(target)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        pendingCursorRestore = item
        injectQueue.asyncAfter(deadline: .now() + .milliseconds(delayMs), execute: item)
    }

    func handleControlEvent(_ msg: ControlEventMessage) {
        injectQueue.async { [weak self] in
            self?.processControlEvent(msg)
        }
    }

    /// Pastes one or more received dropped files into the target window via NSPasteboard + Cmd+V.
    func pasteDroppedFiles(windowID: CGWindowID, fileURLs: [URL]) {
        guard !fileURLs.isEmpty else { return }
        injectQueue.async { [weak self] in
            guard let self, AXIsProcessTrusted() else { return }
            guard let resolved = self.resolveWindowTarget(for: windowID) else { return }
            self.targetWindowID = windowID
            self.targetPID = resolved.pid
            self.fallbackFrame = resolved.frame

            let switched = self.bringTargetWindowToFront(
                windowID: windowID,
                rawFrame: resolved.frame,
                windowLayer: resolved.layer,
                clickPoint: nil
            )
            if switched {
                usleep(70_000)
            } else {
                usleep(20_000)
            }

            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 9 /* V */, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 9 /* V */, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                if self.silentMode {
                    down.postToPid(resolved.pid)
                    usleep(12_000)
                    up.postToPid(resolved.pid)
                } else {
                    down.post(tap: .cghidEventTap)
                    usleep(12_000)
                    up.post(tap: .cghidEventTap)
                }
            }
            let names = fileURLs.map(\.lastPathComponent).joined(separator: ", ")
            self.onDebugLog?("已粘贴拖入文件: \(names)")
        }
    }

    private func processControlEvent(_ msg: ControlEventMessage) {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            onDebugLog?("拦截：未授予辅助功能权限，无法执行远程点击/输入")
            return
        }

        let effectiveWinID = CGWindowID(msg.window_id ?? targetWindowID)
        if effectiveWinID == MultiWindowCaptureManager.fullDesktopWindowID {
            processFullDesktopControlEvent(msg)
            return
        }
        guard let resolved = resolveWindowTarget(for: effectiveWinID) else {
            onDebugLog?("收到远程输入，但目标窗口不存在 (win=\(effectiveWinID))")
            return
        }
        self.targetWindowID = effectiveWinID
        self.targetPID = resolved.pid
        self.fallbackFrame = resolved.frame
        if msg.type == "mouse" && (msg.event_type == 1 || msg.event_type == 2 || msg.event_type == 3) ||
            msg.type == "scroll" || msg.type == "key" || msg.type == "text_commit" {
            let isInteractiveWindow = resolved.layer == 0 ||
                (resolved.layer <= 25 && resolved.frame.width >= 140 && resolved.frame.height >= 120)
            onNormalWindowInteracted?(isInteractiveWindow ? effectiveWinID : 0)
        }
        let inset = windowContentInsets[effectiveWinID] ?? .zero

        switch msg.type {
        case "mouse":
            let relX = CGFloat(msg.x ?? 0)
            let relY = CGFloat(msg.y ?? 0)
            let eventType = msg.event_type ?? 0
            let button = msg.button ?? 0
            let clickCount = Int64(msg.click_count ?? 1)
            let flags = cgFlags(from: msg.modifiers ?? 0)
            injectMouse(
                windowID: effectiveWinID,
                rawFrame: resolved.frame,
                inset: inset,
                windowLayer: resolved.layer,
                relX: relX,
                relY: relY,
                type: eventType,
                button: button,
                clickCount: clickCount,
                flags: flags
            )

        case "scroll":
            let relX = CGFloat(msg.x ?? 0)
            let relY = CGFloat(msg.y ?? 0)
            let prepared = prepareWindowAndClickPoint(
                windowID: effectiveWinID,
                rawFrame: resolved.frame,
                inset: inset,
                windowLayer: resolved.layer,
                relX: relX,
                relY: relY,
                allowRelocate: true
            )
            let point = prepared.point
            let dx = Int32(msg.delta_x ?? 0)
            let dy = Int32(msg.delta_y ?? 0)
            let units: CGScrollEventUnit = (msg.is_continuous ?? true) ? .pixel : .line
            captureHostCursorBeforeWarp()
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                ev.location = point
                ev.post(tap: .cghidEventTap)
            }
            scheduleHostCursorRestore(delayMs: 20)

        case "key":
            let rawModifiers = msg.modifiers ?? 0
            let flags = cgFlags(from: rawModifiers)
            let keyCode = Self.normalizedInjectedKeyCode(CGKeyCode(msg.key_code ?? 0), flags: flags)
            let isDown = msg.is_down ?? true
            let isRepeat = msg.is_repeat ?? false

            // 1. Explicit "Close Remote Window" button (HoverBar 「关对端窗」 / Dock / mobile tab close -> bit 256):
            //    Close ONLY `effectiveWinID` via its own AX Close button (never blindly sending ⌘W to WeChat's main window).
            if (rawModifiers & 256) != 0 && keyCode == 13 /* W */ {
                if isDown {
                    closeSpecificRemoteWindow(
                        windowID: effectiveWinID,
                        pid: resolved.pid,
                        rawFrame: resolved.frame,
                        windowLayer: resolved.layer
                    )
                }
                return
            }

            // 2. Keyboard `⌘W` (`keyCode == 13`, `.maskCommand` without Ctrl/Opt/Shift):
            //    Posting `⌘W` via `postToPid` while an app is inactive (`keyWindow == nil`) or while another window of
            //    the same app is focused causes AppKit/WeChat to route `performClose:` to `mainWindow` (closing WeChat's
            //    main window instead of the image viewer!). Ensure `effectiveWinID` is active & focused first; if a
            //    sibling window still holds focus, close `effectiveWinID` directly via AX Close / Esc instead of `⌘W`.
            let isPlainCmdW = keyCode == 13 /* W */ &&
                flags.contains(.maskCommand) &&
                !flags.contains(.maskShift) &&
                !flags.contains(.maskAlternate) &&
                !flags.contains(.maskControl)
            if isPlainCmdW {
                if !isDown {
                    if suppressedCmdWKeyUpWindowID == effectiveWinID {
                        suppressedCmdWKeyUpWindowID = 0
                        return
                    }
                } else {
                    let hasSibling = AXWindowLookup.hasOtherNormalOnScreenWindow(pid: resolved.pid, excluding: effectiveWinID)
                    let focusedOK = activateAndFocusSpecificWindow(
                        windowID: effectiveWinID,
                        pid: resolved.pid,
                        rawFrame: resolved.frame,
                        windowLayer: resolved.layer
                    )
                    if hasSibling && !focusedOK {
                        suppressedCmdWKeyUpWindowID = effectiveWinID
                        closeSpecificRemoteWindow(
                            windowID: effectiveWinID,
                            pid: resolved.pid,
                            rawFrame: resolved.frame,
                            windowLayer: resolved.layer
                        )
                        return
                    }
                }
                if let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) {
                    ev.flags = flags
                    ev.post(tap: .cghidEventTap)
                }
                return
            }

            // Give a just-arrived pre-paste ClipboardSync 15ms to commit to NSPasteboard on main thread.
            if isDown && keyCode == 9 /* V */ && flags.contains(.maskCommand) {
                usleep(15_000)
            }
            if let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) {
                ev.flags = flags
                if isRepeat {
                    ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                }
                let isSystemGlobalShortcut =
                    (flags.contains(.maskCommand) && (keyCode == 49 /* Space */ || keyCode == 48 /* Tab */)) ||
                    (flags.contains(.maskControl) && (keyCode == 123 || keyCode == 124 || keyCode == 125 || keyCode == 126)) ||
                    (flags.contains(.maskCommand) && flags.contains(.maskShift) && (keyCode == 20 || keyCode == 21 || keyCode == 23))
                let requiresHIDTap =
                    isSystemGlobalShortcut ||
                    (keyCode == 53 && (isRemoteMouseButtonDown || targetAppHasOpenFloatingPopover()))
                if silentMode && !requiresHIDTap {
                    if isDown && !isRepeat {
                        ensureWindowFocusedInsideApp(
                            windowID: effectiveWinID,
                            pid: resolved.pid,
                            rawFrame: resolved.frame,
                            windowLayer: resolved.layer
                        )
                    }
                    ev.postToPid(targetPID)
                } else {
                    if !isRemoteMouseButtonDown && !isSystemGlobalShortcut {
                        let changed = bringTargetWindowToFront(windowID: effectiveWinID, rawFrame: resolved.frame, windowLayer: resolved.layer, clickPoint: nil)
                        if changed && isDown {
                            usleep(35_000)
                        }
                    }
                    ev.post(tap: .cghidEventTap)
                }
            }

        case "text_commit":
            guard let text = msg.text, !text.isEmpty else { return }
            onDebugLog?("注入文本: \(text)")
            ensureWindowFocusedInsideApp(
                windowID: effectiveWinID,
                pid: resolved.pid,
                rawFrame: resolved.frame,
                windowLayer: resolved.layer
            )
            injectUnicodeText(text)

        case "resize_window":
            guard let w = msg.width, let h = msg.height, w >= 80, h >= 80 else { return }
            resizeRemoteWindow(
                windowID: effectiveWinID,
                pid: resolved.pid,
                rawFrame: resolved.frame,
                windowLayer: resolved.layer,
                targetWidth: CGFloat(w),
                targetHeight: CGFloat(h)
            )

        default:
            break
        }
    }

    /// Direct full-screen desktop input injection (mouse, scroll, keyboard, Unicode IME) onto the Host main display.
    private func processFullDesktopControlEvent(_ msg: ControlEventMessage) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let flags = cgFlags(from: msg.modifiers ?? 0)

        switch msg.type {
        case "mouse":
            let type = msg.event_type ?? 0
            guard type != 4 else { return }
            let point = CGPoint(
                x: mainBounds.origin.x + CGFloat(msg.x ?? 0),
                y: mainBounds.origin.y + CGFloat(msg.y ?? 0)
            )
            let button = msg.button ?? 0
            let clickCount = Int64(msg.click_count ?? 1)
            let cgButton: CGMouseButton = button == 1 ? .right : (button == 2 ? .center : .left)
            let cgType: CGEventType
            switch (type, cgButton) {
            case (0, _): cgType = .mouseMoved
            case (1, .right): cgType = .rightMouseDown
            case (2, .right): cgType = .rightMouseUp
            case (3, .right): cgType = .rightMouseDragged
            case (1, .center): cgType = .otherMouseDown
            case (2, .center): cgType = .otherMouseUp
            case (3, .center): cgType = .otherMouseDragged
            case (1, _): cgType = .leftMouseDown
            case (2, _): cgType = .leftMouseUp
            case (3, _): cgType = .leftMouseDragged
            default: cgType = .mouseMoved
            }
            var dx: Int64 = 0
            var dy: Int64 = 0
            if type == 1 {
                lastMouseEventPoint = point
            } else if type == 3 {
                if let prev = lastMouseEventPoint {
                    dx = Int64((point.x - prev.x).rounded())
                    dy = Int64((point.y - prev.y).rounded())
                }
                lastMouseEventPoint = point
            } else if type == 2 {
                lastMouseEventPoint = nil
            }
            if let ev = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: point, mouseButton: cgButton) {
                ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
                if type == 3 {
                    ev.setIntegerValueField(.mouseEventDeltaX, value: dx)
                    ev.setIntegerValueField(.mouseEventDeltaY, value: dy)
                }
                ev.flags = flags
                ev.post(tap: .cghidEventTap)
            }
            if type == 0 || type == 1 || type == 2 {
                inspectAndEmitCursorShape()
            }

        case "scroll":
            let point = CGPoint(
                x: mainBounds.origin.x + CGFloat(msg.x ?? 0),
                y: mainBounds.origin.y + CGFloat(msg.y ?? 0)
            )
            let dx = Int32(msg.delta_x ?? 0)
            let dy = Int32(msg.delta_y ?? 0)
            let units: CGScrollEventUnit = (msg.is_continuous ?? true) ? .pixel : .line
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                ev.location = point
                ev.post(tap: .cghidEventTap)
            }

        case "key":
            let keyCode = Self.normalizedInjectedKeyCode(CGKeyCode(msg.key_code ?? 0), flags: flags)
            let isDown = msg.is_down ?? true
            let isRepeat = msg.is_repeat ?? false
            if isDown && keyCode == 9 && flags.contains(.maskCommand) {
                usleep(15_000)
            }
            if let ev = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) {
                ev.flags = flags
                if isRepeat {
                    ev.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
                }
                ev.post(tap: .cghidEventTap)
            }

        case "text_commit":
            guard let text = msg.text, !text.isEmpty else { return }
            let utf16 = Array(text.utf16)
            var idx = 0
            while idx < utf16.count {
                let end = min(idx + 16, utf16.count)
                var slice = Array(utf16[idx..<end])
                if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                   let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                    down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                    up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
                idx = end
            }

        default:
            break
        }
    }

    private func resizeRemoteWindow(
        windowID: CGWindowID,
        pid: pid_t,
        rawFrame: CGRect,
        windowLayer: Int,
        targetWidth: CGFloat,
        targetHeight: CGFloat
    ) {
        guard windowLayer <= 25,
              let matched = AXWindowLookup.find(pid: pid, windowID: windowID, frame: rawFrame) else {
            return
        }
        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(matched, kAXSizeAttribute as CFString, &isSettable) == .success,
           !isSettable.boolValue {
            return
        }

        let displayBounds = containingDisplayBounds(for: rawFrame)
        let maxW = max(200, displayBounds.width - 12)
        let maxH = max(160, displayBounds.height - 28)
        var desiredSize = CGSize(
            width: max(160, min(targetWidth, maxW)),
            height: max(120, min(targetHeight, maxH))
        )
        if abs(desiredSize.width - rawFrame.width) < 4 && abs(desiredSize.height - rawFrame.height) < 4 {
            return
        }

        // If growing would push the right/bottom edge outside the containing display (e.g. off Virtual Display
        // onto the main display), pull the window origin inside the display first.
        var desiredOrigin = rawFrame.origin
        var needsMove = false
        if desiredOrigin.x + desiredSize.width > displayBounds.maxX - 4 {
            desiredOrigin.x = max(displayBounds.minX + 4, displayBounds.maxX - desiredSize.width - 4)
            needsMove = true
        }
        if desiredOrigin.y + desiredSize.height > displayBounds.maxY - 4 {
            desiredOrigin.y = max(displayBounds.minY + 24, displayBounds.maxY - desiredSize.height - 4)
            needsMove = true
        }
        if needsMove, let posVal = AXValueCreate(.cgPoint, &desiredOrigin) {
            AXUIElementSetAttributeValue(matched, kAXPositionAttribute as CFString, posVal)
        }

        if let sizeVal = AXValueCreate(.cgSize, &desiredSize) {
            AXUIElementSetAttributeValue(matched, kAXSizeAttribute as CFString, sizeVal)
            onWindowResized?(windowID)
            injectQueue.asyncAfter(deadline: .now() + .milliseconds(45)) { [weak self] in
                self?.onWindowResized?(windowID)
            }
        }
    }

    private func containingDisplayBounds(for frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let vBounds = activeVirtualDisplayBounds(), vBounds.contains(center) {
            return vBounds
        }
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        if displayCount > 0 {
            var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
            CGGetActiveDisplayList(displayCount, &displays, &displayCount)
            for id in displays.prefix(Int(displayCount)) {
                let b = CGDisplayBounds(id)
                if b.contains(center) {
                    return b
                }
            }
        }
        return CGDisplayBounds(CGMainDisplayID())
    }

    /// Ensures the target window lies inside the active Virtual Display (in Scheme C) or inside a reachable physical
    /// display (in Scheme A), then computes the global click point.
    private func prepareWindowAndClickPoint(
        windowID: CGWindowID,
        rawFrame: CGRect,
        inset: CGPoint,
        windowLayer: Int,
        relX: CGFloat,
        relY: CGFloat,
        allowRelocate: Bool
    ) -> (rawFrame: CGRect, contentFrame: CGRect, point: CGPoint) {
        var currentRaw = rawFrame

        let isRelocatableWindow = windowLayer == 0 || (windowLayer <= 25 && currentRaw.width >= 140 && currentRaw.height >= 120)
        if allowRelocate, let vBounds = activeVirtualDisplayBounds() {
            // Scheme C: normal windows MUST stay completely inside the virtual display so no part of the window
            // overflows onto the adjacent main display (where WindowServer clips it and clicks hit main-screen apps).
            if isRelocatableWindow && !vBounds.insetBy(dx: -2, dy: -2).contains(currentRaw) {
                currentRaw = relocateWindowIntoVirtualDisplay(windowID: windowID, currentRaw: currentRaw, vBounds: vBounds)
            }
        }

        var contentFrame = CGRect(
            x: currentRaw.origin.x + inset.x,
            y: currentRaw.origin.y + inset.y,
            width: currentRaw.width - inset.x,
            height: currentRaw.height - inset.y
        )
        var clickPoint = CGPoint(x: contentFrame.origin.x + relX, y: contentFrame.origin.y + relY)

        if let vBounds = activeVirtualDisplayBounds() {
            // Strictly clamp clickPoint inside the virtual display so a click in Scheme C never leaks onto the main screen.
            let safe = vBounds.insetBy(dx: 2, dy: 2)
            clickPoint.x = min(max(clickPoint.x, safe.minX), safe.maxX)
            clickPoint.y = min(max(clickPoint.y, safe.minY), safe.maxY)
        } else if allowRelocate && isRelocatableWindow && !isPointOnAnyDisplay(clickPoint) {
            let nudged = nudgeWindowIntoDisplayBounds(windowID: windowID, for: clickPoint, rawFrame: currentRaw)
            currentRaw = nudged.rawFrame
            contentFrame = CGRect(
                x: currentRaw.origin.x + inset.x,
                y: currentRaw.origin.y + inset.y,
                width: currentRaw.width - inset.x,
                height: currentRaw.height - inset.y
            )
            clickPoint = CGPoint(x: contentFrame.origin.x + relX, y: contentFrame.origin.y + relY)
        }

        return (currentRaw, contentFrame, clickPoint)
    }

    /// Clamps (and if necessary shrinks) a normal window so it lies completely inside the virtual display.
    private func relocateWindowIntoVirtualDisplay(windowID: CGWindowID, currentRaw: CGRect, vBounds: CGRect) -> CGRect {
        let topMargin: CGFloat = 40
        let sideMargin: CGFloat = 16
        let area = CGRect(
            x: vBounds.minX + sideMargin,
            y: vBounds.minY + topMargin,
            width: vBounds.width - sideMargin * 2,
            height: vBounds.height - topMargin - sideMargin
        )
        guard let axWin = AXWindowLookup.find(pid: targetPID, windowID: windowID, frame: currentRaw) else {
            return currentRaw
        }
        var size = currentRaw.size
        if size.width > area.width || size.height > area.height {
            size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
            AXWindowLookup.setSize(axWin, size)
            if let actual = AXWindowLookup.frame(of: axWin)?.size {
                size = actual
            }
        }
        var origin = currentRaw.origin
        if !vBounds.contains(CGPoint(x: currentRaw.midX, y: currentRaw.midY)) {
            origin = CGPoint(x: area.minX + 44, y: area.minY + 20)
        }
        origin.x = min(max(origin.x, area.minX), area.maxX - size.width)
        origin.y = min(max(origin.y, area.minY), area.maxY - size.height)
        AXWindowLookup.setPosition(axWin, origin)
        usleep(35_000)
        return AXWindowLookup.cgBounds(of: windowID) ?? AXWindowLookup.frame(of: axWin) ?? CGRect(origin: origin, size: size)
    }

    /// Returns the topmost on-screen normal/popover window at `point` (front-to-back WindowServer Z-order).
    private func topmostWindowAtPoint(_ point: CGPoint) -> (windowID: CGWindowID, pid: pid_t, layer: Int)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in list {
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer >= 0 && layer <= 105 else { continue }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
                continue
            }
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point) else {
                continue
            }
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0
            if wid != 0 && pid != 0 {
                return (wid, pid_t(pid), layer)
            }
        }
        return nil
    }

    /// Brings the target app and specific captured window (`windowID`) to the front using Accessibility API.
    /// Returns `true` if WindowServer focus / Z-order was changed (so caller can wait briefly before clicking).
    @discardableResult
    private func bringTargetWindowToFront(windowID: CGWindowID, rawFrame: CGRect, windowLayer: Int, clickPoint: CGPoint?) -> Bool {
        let pid = targetPID
        let wasActive = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let topAtPoint = clickPoint.flatMap { topmostWindowAtPoint($0) }

        // If the click point lands on an already-open floating popover/menu (layer > 0) of the target app,
        // NEVER raise a layer-0 main window (doing so would dismiss the popover right before the click lands!).
        if let top = topAtPoint, top.pid == pid, top.layer > 0 {
            if !wasActive {
                let appAX = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                NSRunningApplication(processIdentifier: pid)?.activate()
                return true
            }
            return false
        }

        // If the target app is already active AND the exact target window is already the topmost window at `clickPoint`,
        // do not re-raise (avoids dismissing open popovers/menus when clicking back inside the window).
        if wasActive, let top = topAtPoint, top.windowID == windowID {
            return false
        }

        let appAX = AXUIElementCreateApplication(pid)
        if !wasActive {
            AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        // Raise the exact AXWindow matching `windowID` (never blindly raising `windows[0]` when another windowID was clicked).
        var raisedWindow = false
        if windowLayer <= 25,
           let matched = AXWindowLookup.find(pid: pid, windowID: windowID, frame: rawFrame),
           (windowLayer == 0 || AXWindowLookup.isStandardOrDialogWindow(matched)) {
            AXUIElementSetAttributeValue(matched, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementSetAttributeValue(matched, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(matched, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(matched, kAXRaiseAction as CFString)
            raisedWindow = true
        }

        if !wasActive {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        return !wasActive || raisedWindow
    }

    /// Ensures `windowID` is the focused AX window inside `pid` (without stealing global foreground focus in `silentMode`)
    /// so `postToPid` keyboard events (`Esc`, `←/→`, `⌘C`, IME text) hit the right child/chat window rather than `windows[0]`.
    private func ensureWindowFocusedInsideApp(windowID: CGWindowID, pid: pid_t, rawFrame: CGRect, windowLayer: Int) {
        guard windowID != 0, windowLayer <= 25 else { return }
        if AXWindowLookup.focusedWindowID(pid: pid) == windowID {
            return
        }
        if let matched = AXWindowLookup.find(pid: pid, windowID: windowID, frame: rawFrame),
           (windowLayer == 0 || AXWindowLookup.isStandardOrDialogWindow(matched)) {
            AXWindowLookup.raise(matched)
            usleep(25_000)
        }
    }

    /// Activates `pid`, raises `windowID`, and polls up to ~90ms to verify `kAXFocusedWindowAttribute == windowID`.
    private func activateAndFocusSpecificWindow(windowID: CGWindowID, pid: pid_t, rawFrame: CGRect, windowLayer: Int) -> Bool {
        let matched = AXWindowLookup.find(pid: pid, windowID: windowID, frame: rawFrame)
        let wasActive = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        if !wasActive {
            AXWindowLookup.activateProcess(pid)
        }
        if let matched {
            AXWindowLookup.raise(matched)
        }
        for _ in 0..<6 {
            let activeNow = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
            if activeNow && AXWindowLookup.focusedWindowID(pid: pid) == windowID {
                return true
            }
            usleep(15_000)
        }
        let activeNow = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        return activeNow && AXWindowLookup.focusedWindowID(pid: pid) == windowID
    }

    /// Deterministically closes ONLY `windowID` without ever sending an unfocused `⌘W` that could close a sibling main window.
    private func closeSpecificRemoteWindow(windowID: CGWindowID, pid: pid_t, rawFrame: CGRect, windowLayer: Int) {
        if let matched = AXWindowLookup.find(pid: pid, windowID: windowID, frame: rawFrame),
           AXWindowLookup.pressCloseButton(of: matched) {
            usleep(65_000)
            if !AXWindowLookup.isWindowOnScreen(windowID) {
                onDebugLog?("已精准关闭远端窗口 win=\(windowID)")
                return
            }
        }

        let hasSibling = AXWindowLookup.hasOtherNormalOnScreenWindow(pid: pid, excluding: windowID)
        let focusedOK = activateAndFocusSpecificWindow(windowID: windowID, pid: pid, rawFrame: rawFrame, windowLayer: windowLayer)

        if focusedOK || !hasSibling {
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 13 /* W */, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 13 /* W */, keyDown: false) {
                down.flags = .maskCommand
                up.flags = .maskCommand
                down.post(tap: .cghidEventTap)
                usleep(12_000)
                up.post(tap: .cghidEventTap)
            }
            usleep(65_000)
            if !AXWindowLookup.isWindowOnScreen(windowID) {
                onDebugLog?("已通过 ⌘W 关闭远端焦点窗口 win=\(windowID)")
                return
            }
        }

        // Safe fallback (e.g. borderless/non-focusable image viewer or preview panel while WeChat main window is open):
        // send `Esc` (NEVER `⌘W`!), which dismisses image viewers/previews without ever closing WeChat's main window.
        if let down = CGEvent(keyboardEventSource: nil, virtualKey: 53 /* Esc */, keyDown: true),
           let up = CGEvent(keyboardEventSource: nil, virtualKey: 53 /* Esc */, keyDown: false) {
            down.flags = []
            up.flags = []
            if NSRunningApplication(processIdentifier: pid)?.isActive == true {
                down.post(tap: .cghidEventTap)
                usleep(12_000)
                up.post(tap: .cghidEventTap)
            } else {
                down.postToPid(pid)
                usleep(12_000)
                up.postToPid(pid)
            }
            onDebugLog?("已通过 Esc 安全关闭远端预览窗口 win=\(windowID)")
        }
    }

    private func isPointOnAnyDisplay(_ point: CGPoint) -> Bool {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        guard displayCount > 0 else { return true }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return displays.prefix(Int(displayCount)).contains { id in
            CGDisplayBounds(id).contains(point)
        }
    }

    /// Shifts a partially off-screen window minimally into its display so the requested click point becomes reachable.
    private func nudgeWindowIntoDisplayBounds(windowID: CGWindowID, for point: CGPoint, rawFrame: CGRect) -> (rawFrame: CGRect, point: CGPoint) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID()).insetBy(dx: 8, dy: 28)
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        if point.x < mainBounds.minX { dx = mainBounds.minX - point.x }
        else if point.x > mainBounds.maxX { dx = mainBounds.maxX - point.x }
        if point.y < mainBounds.minY { dy = mainBounds.minY - point.y }
        else if point.y > mainBounds.maxY { dy = mainBounds.maxY - point.y }

        let newOrigin = CGPoint(x: rawFrame.origin.x + dx, y: rawFrame.origin.y + dy)
        if let matched = AXWindowLookup.find(pid: targetPID, windowID: windowID, frame: rawFrame) {
            AXWindowLookup.setPosition(matched, newOrigin)
            usleep(25_000)
        }
        let updated = AXWindowLookup.cgBounds(of: windowID) ?? CGRect(origin: newOrigin, size: rawFrame.size)
        return (updated, CGPoint(x: point.x + dx, y: point.y + dy))
    }

    private func injectMouse(
        windowID: CGWindowID,
        rawFrame: CGRect,
        inset: CGPoint,
        windowLayer: Int,
        relX: CGFloat,
        relY: CGFloat,
        type: Int32,
        button: UInt32,
        clickCount: Int64,
        flags: CGEventFlags
    ) {
        // Remote cursor exited the Client proxy window (type == 4).
        if type == 4 {
            if !targetAppHasOpenFloatingPopover() {
                scheduleHostCursorRestore(delayMs: 15, forceEvenIfPopoverOpen: true)
            }
            return
        }

        // Handle hover moves (type == 0) for live cursor-shape sync AND floating popover hover tracking
        // (e.g., hovering a sticker inside WeChat's emoji picker to pop up the animated sticker preview).
        if type == 0 {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastHoverTime < 0.03 { return } // throttle to ~33Hz
            lastHoverTime = now

            let hasOpenPopover = (windowLayer > 0) || targetAppHasOpenFloatingPopover()
            // When no floating popover is open, respect silentMode / Virtual Display cursor isolation so normal
            // mouse movements over the main window never pull the host user's physical cursor away.
            // As soon as a floating popover (like WeChat's emoji panel) IS open, we MUST warp & post `.mouseMoved`
            // so AppKit's `NSTrackingArea` delivers `mouseEntered`/`mouseMoved` to each sticker cell!
            guard hasOpenPopover || (hoverCursorSync && !silentMode && activeVirtualDisplayBounds() == nil) else {
                return
            }

            let isTargetActive = NSRunningApplication(processIdentifier: targetPID)?.isActive ?? false
            if !isTargetActive && hasOpenPopover {
                let appAX = AXUIElementCreateApplication(targetPID)
                AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                NSRunningApplication(processIdentifier: targetPID)?.activate()
            } else if !isTargetActive {
                return
            }

            let prepared = prepareWindowAndClickPoint(
                windowID: windowID,
                rawFrame: rawFrame,
                inset: inset,
                windowLayer: windowLayer,
                relX: relX,
                relY: relY,
                allowRelocate: false
            )
            if hasOpenPopover {
                captureHostCursorBeforeWarp()
            }
            CGWarpMouseCursorPosition(prepared.point)
            CGAssociateMouseAndMouseCursorPosition(1)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: prepared.point, mouseButton: .left) {
                move.post(tap: .cghidEventTap)
            }
            inspectAndEmitCursorShape()
            if hasOpenPopover {
                scheduleHostCursorRestore(delayMs: 350, forceEvenIfPopoverOpen: false)
            }
            return
        }

        let cgButton: CGMouseButton = button == 1 ? .right : (button == 2 ? .center : .left)
        let cgType: CGEventType
        switch (type, cgButton) {
        case (0, _): cgType = .mouseMoved
        case (1, .right): cgType = .rightMouseDown
        case (2, .right): cgType = .rightMouseUp
        case (3, .right): cgType = .rightMouseDragged
        case (1, .center): cgType = .otherMouseDown
        case (2, .center): cgType = .otherMouseUp
        case (3, .center): cgType = .otherMouseDragged
        case (1, _): cgType = .leftMouseDown
        case (2, _): cgType = .leftMouseUp
        case (3, _): cgType = .leftMouseDragged
        default: cgType = .mouseMoved
        }

        let prepared = prepareWindowAndClickPoint(
            windowID: windowID,
            rawFrame: rawFrame,
            inset: inset,
            windowLayer: windowLayer,
            relX: relX,
            relY: relY,
            allowRelocate: type == 1
        )
        let clickPoint = prepared.point

        var dragDeltaX: Int64 = 0
        var dragDeltaY: Int64 = 0

        if type == 1 {
            // Auto-heal if a previous drag's mouseUp was swallowed so WindowServer/WeChat never stays stuck.
            if isRemoteMouseButtonDown {
                OpenUULogger.shared.warn("INPUT", "auto_heal stuck mouseDown before new click win=\(windowID)")
                if let strayUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: lastMouseEventPoint ?? clickPoint, mouseButton: .left) {
                    strayUp.post(tap: .cghidEventTap)
                }
                usleep(10_000)
            }
            isRemoteMouseButtonDown = true
            lastMouseEventPoint = clickPoint
            dragPasteboardBaselineCount = NSPasteboard(name: .drag).changeCount
            dragOutEmittedForCurrentDrag = false
            captureHostCursorBeforeWarp()

            let changedZOrder = bringTargetWindowToFront(
                windowID: windowID,
                rawFrame: prepared.rawFrame,
                windowLayer: windowLayer,
                clickPoint: clickPoint
            )
            onDebugLog?(String(format: "注入点击 (%.0f, %.0f) win=%u", clickPoint.x, clickPoint.y, windowID))
            if changedZOrder {
                // Give WindowServer 55ms to commit frontmost activation / window raise before hit-testing the click.
                usleep(55_000)
            }
            // Teleport cursor across display boundaries (required on macOS for secondary/virtual displays!)
            CGWarpMouseCursorPosition(clickPoint)
            CGAssociateMouseAndMouseCursorPosition(1)
            if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: clickPoint, mouseButton: cgButton) {
                move.post(tap: .cghidEventTap)
            }
            usleep(activeVirtualDisplayBounds() != nil ? 15_000 : 8_000)
        } else if type == 3 {
            pendingCursorRestore?.cancel()
            pendingCursorRestore = nil
            if let prev = lastMouseEventPoint {
                dragDeltaX = Int64((clickPoint.x - prev.x).rounded())
                dragDeltaY = Int64((clickPoint.y - prev.y).rounded())
            }
            lastMouseEventPoint = clickPoint
            // Do NOT call CGWarpMouseCursorPosition on every drag tick (it suppresses drag deltas and breaks
            // AppKit/WeChat drag initiation on Virtual Displays!). Only warp if the cursor drifted off-display.
            if isPointOnVirtualDisplay(clickPoint),
               let cur = CGEvent(source: nil)?.location,
               !isPointOnVirtualDisplay(cur) {
                CGWarpMouseCursorPosition(clickPoint)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        } else if type == 2 {
            isRemoteMouseButtonDown = false
            lastMouseEventPoint = nil
            pendingCursorRestore?.cancel()
            pendingCursorRestore = nil
            // When `mouseDown` slept 55ms+ to activate/raise the window, `mouseUp` is often already queued on
            // `injectQueue` <0.1ms behind it; enforce at least one 16ms runloop turn between down and up so
            // draggable items (such as WeChat image bubbles and web link cards) reliably complete click hit-testing.
            let elapsedSinceDown = CFAbsoluteTimeGetCurrent() - lastMouseDownPostedAt
            if elapsedSinceDown >= 0 && elapsedSinceDown < 0.016 {
                let remainUS = useconds_t(((0.016 - elapsedSinceDown) * 1_000_000).rounded())
                if remainUS > 0 {
                    usleep(remainUS)
                }
            }
            // Only re-warp before mouseUp if the host physical mouse actually drifted away from clickPoint.
            if let cur = CGEvent(source: nil)?.location,
               hypot(cur.x - clickPoint.x, cur.y - clickPoint.y) > 2.0 {
                CGWarpMouseCursorPosition(clickPoint)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        if let ev = CGEvent(mouseEventSource: nil, mouseType: cgType, mouseCursorPosition: clickPoint, mouseButton: cgButton) {
            ev.setIntegerValueField(.mouseEventClickState, value: clickCount)
            if type == 3 {
                ev.setIntegerValueField(.mouseEventDeltaX, value: dragDeltaX)
                ev.setIntegerValueField(.mouseEventDeltaY, value: dragDeltaY)
            }
            ev.flags = flags
            ev.post(tap: .cghidEventTap)
            if type == 1 {
                lastMouseDownPostedAt = CFAbsoluteTimeGetCurrent()
            }
        }

        // Detect when the remote app (e.g. WeChat) begins dragging file(s) or an image onto macOS's `.drag`
        // pasteboard so we can proactively stream them to the Client for native drag-out to Client Desktop/Finder!
        if type == 3, !dragOutEmittedForCurrentDrag {
            checkDragPasteboardForDragOut()
            // WeChat often populates `.drag` 15-150ms AFTER receiving `leftMouseDragged`; re-check shortly after
            // so fast drags to the window edge never miss the pasteboard write!
            injectQueue.asyncAfter(deadline: .now() + .milliseconds(35)) { [weak self] in
                self?.checkDragPasteboardForDragOut()
            }
            injectQueue.asyncAfter(deadline: .now() + .milliseconds(90)) { [weak self] in
                self?.checkDragPasteboardForDragOut()
            }
            injectQueue.asyncAfter(deadline: .now() + .milliseconds(180)) { [weak self] in
                self?.checkDragPasteboardForDragOut()
            }
        } else if type == 2 {
            dragOutEmittedForCurrentDrag = false
        }

        if type == 1 || type == 2 {
            inspectAndEmitCursorShape()
        }

        if type == 2 {
            // Wait 180ms AFTER mouseUp so the target app finishes click/double-click dispatch and spawning any
            // child window or popover before checking `targetAppHasOpenFloatingPopover()` and restoring the cursor.
            scheduleHostCursorRestore(delayMs: 180)
        }
    }

    private func inspectAndEmitCursorShape() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let kind = Self.classifySystemCursor()
            if kind != self.lastCursorKind {
                self.lastCursorKind = kind
                self.onCursorKindChanged?(kind)
            }
        }
    }

    @MainActor
    private static func classifySystemCursor() -> String {
        guard let current = NSCursor.currentSystem,
              let curData = current.image.tiffRepresentation else {
            return "arrow"
        }
        let candidates: [(String, NSCursor)] = [
            ("ibeam", .iBeam),
            ("pointing_hand", .pointingHand),
            ("resize_lr", .resizeLeftRight),
            ("resize_ud", .resizeUpDown),
            ("resize_left", .resizeLeft),
            ("resize_right", .resizeRight),
            ("resize_up", .resizeUp),
            ("resize_down", .resizeDown),
            ("open_hand", .openHand),
            ("closed_hand", .closedHand),
            ("crosshair", .crosshair),
            ("arrow", .arrow),
        ]
        for (name, cursor) in candidates {
            if cursor.image.tiffRepresentation == curData {
                return name
            }
        }
        // Heuristic fallback for custom app I-beam/hand cursors based on hotspot geometry
        let hs = current.hotSpot
        let sz = current.image.size
        if sz.width > 0 && sz.height > 0 {
            if abs(hs.x - sz.width / 2) < 3 && abs(hs.y - sz.height / 2) < 3 && sz.height >= sz.width {
                return "ibeam"
            }
        }
        return "arrow"
    }

    private func injectUnicodeText(_ text: String) {
        let utf16 = Array(text.utf16)
        let chunkSize = 16
        var idx = 0
        while idx < utf16.count {
            let end = min(idx + chunkSize, utf16.count)
            var slice = Array(utf16[idx..<end])
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: &slice)
                if silentMode {
                    down.postToPid(targetPID)
                    up.postToPid(targetPID)
                } else {
                    bringTargetWindowToFront(windowID: targetWindowID, rawFrame: fallbackFrame, windowLayer: 0, clickPoint: nil)
                    down.post(tap: .cghidEventTap)
                    up.post(tap: .cghidEventTap)
                }
            }
            idx = end
        }
    }

    private static func normalizedInjectedKeyCode(_ raw: CGKeyCode, flags: CGEventFlags) -> CGKeyCode {
        if raw == 76 /* Keypad Enter */ {
            return 36 /* Return */
        }
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            switch raw {
            case 69, 81: return 24 // Keypad + / = -> = (+)
            case 78: return 27     // Keypad -     -> -
            case 75: return 44     // Keypad /     -> /
            case 65: return 47     // Keypad .     -> .
            case 82: return 29     // Keypad 0     -> 0
            case 83: return 18     // Keypad 1     -> 1
            case 84: return 19     // Keypad 2     -> 2
            case 85: return 20     // Keypad 3     -> 3
            case 86: return 21     // Keypad 4     -> 4
            case 87: return 23     // Keypad 5     -> 5
            case 88: return 22     // Keypad 6     -> 6
            case 89: return 26     // Keypad 7     -> 7
            case 91: return 28     // Keypad 8     -> 8
            case 92: return 25     // Keypad 9     -> 9
            default: break
            }
        }
        return raw
    }

    private func cgFlags(from mask: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if (mask & 1) != 0 { flags.insert(.maskShift) }
        if (mask & 2) != 0 { flags.insert(.maskControl) }
        if (mask & 4) != 0 { flags.insert(.maskAlternate) }
        if (mask & 8) != 0 { flags.insert(.maskCommand) }
        return flags
    }

    private func checkDragPasteboardForDragOut() {
        guard isRemoteMouseButtonDown, !dragOutEmittedForCurrentDrag else { return }
        let dragPB = NSPasteboard(name: .drag)
        guard dragPB.changeCount != dragPasteboardBaselineCount else { return }

        let regularFiles = Self.extractRegularFileURLs(from: dragPB)
        if !regularFiles.isEmpty {
            dragOutEmittedForCurrentDrag = true
            let names = regularFiles.map(\.lastPathComponent).joined(separator: ", ")
            OpenUULogger.shared.info("DRAG", "detected files count=\(regularFiles.count) names=[\(names)]")
            onDragOutFilesDetected?(regularFiles)
            return
        }
        // Fallback: some apps (e.g. WeChat image bubbles) put raw PNG/TIFF image bytes on `.drag` instead of a fileURL.
        if let tempImgURL = Self.extractDraggedImageToTempFile(from: dragPB) {
            dragOutEmittedForCurrentDrag = true
            OpenUULogger.shared.info("DRAG", "detected raw image -> temp=\(tempImgURL.lastPathComponent)")
            onDragOutFilesDetected?([tempImgURL])
            return
        }
        let typeNames = (dragPB.types ?? []).map(\.rawValue).joined(separator: ", ")
        OpenUULogger.shared.debug("DRAG", "dragPB changed count=\(dragPB.changeCount) no file/img types=[\(typeNames)]")
    }

    private static func extractDraggedImageToTempFile(from pb: NSPasteboard) -> URL? {
        var pngData: Data?
        if let rawPNG = pb.data(forType: .png), !rawPNG.isEmpty {
            pngData = rawPNG
        } else if let rawTIFF = pb.data(forType: .tiff), !rawTIFF.isEmpty,
                  let rep = NSBitmapImageRep(data: rawTIFF),
                  let converted = rep.representation(using: .png, properties: [:]) {
            pngData = converted
        }
        guard let data = pngData, data.count <= 32 * 1024 * 1024 else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openuu-dragout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let url = dir.appendingPathComponent("image-\(ts).png")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }

    private static func extractRegularFileURLs(from pb: NSPasteboard) -> [URL] {
        var collected: [URL] = []
        var seen: Set<String> = []
        func appendIfValid(_ url: URL) {
            guard url.isFileURL else { return }
            let path = url.path
            guard seen.insert(path).inserted else { return }
            var isDir: ObjCBool = false
            let fm = FileManager.default
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return }
            let maxBytes: Int64 = 512 * 1024 * 1024
            let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            if size > 0 && size <= maxBytes {
                collected.append(url)
            }
        }

        if let paths = pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            for p in paths {
                appendIfValid(URL(fileURLWithPath: p))
            }
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            for u in urls {
                appendIfValid(u)
            }
        }
        if let items = pb.pasteboardItems {
            for item in items {
                if let str = item.string(forType: .fileURL), let u = URL(string: str) {
                    appendIfValid(u)
                }
            }
        }
        return collected
    }
}

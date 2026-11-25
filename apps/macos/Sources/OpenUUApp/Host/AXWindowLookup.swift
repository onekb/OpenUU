import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Exact AXUIElement <-> CGWindowID mapping helpers.
///
/// The old code matched AX windows by "position within N pt of the SCWindow frame" and otherwise fell back to
/// `windows[0]`. With several windows of one app (WeChat main window + chat/image windows) or content-inset
/// popovers this silently moved / raised the WRONG window. We now resolve the exact window via the long-standing
/// `_AXUIElementGetWindow` symbol (loaded dynamically, graceful fallback to strict frame matching, never `windows[0]`).
enum AXWindowLookup {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let getWindowFn: GetWindowFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW),
              let sym = dlsym(handle, "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let fn = getWindowFn else { return nil }
        var wid: CGWindowID = 0
        return fn(element, &wid) == .success && wid != 0 ? wid : nil
    }

    static func windows(pid: pid_t) -> [AXUIElement] {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appAX, kAXWindowsAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement] else {
            return []
        }
        return list
    }

    /// Returns `kAXWindowsAttribute` plus `kAXMainWindowAttribute` and `kAXFocusedWindowAttribute` (deduped)
    /// so floating `NSPanel` / child preview windows omitted from `kAXWindowsAttribute` are still discovered.
    static func allWindows(pid: pid_t) -> [AXUIElement] {
        var list = windows(pid: pid)
        let appAX = AXUIElementCreateApplication(pid)
        for attr in [kAXMainWindowAttribute as CFString, kAXFocusedWindowAttribute as CFString] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, attr, &ref) == .success,
               let raw = ref,
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                let el = raw as! AXUIElement
                if !list.contains(where: { CFEqual($0, el) }) {
                    list.append(el)
                }
            }
        }
        return list
    }

    /// Strictly returns `kAXFocusedWindowAttribute` ONLY (no `kAXMainWindowAttribute` fallback).
    /// Crucial before posting `⌘W`: floating/child preview windows (such as WeChat's Image Viewer) often cannot
    /// become `mainWindow`, so `kAXMainWindowAttribute` still points to WeChat's main window!
    static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let appAX = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(appAX, kAXFocusedWindowAttribute as CFString, &ref) == .success,
           let raw = ref,
           CFGetTypeID(raw) == AXUIElementGetTypeID(),
           let wid = windowID(of: raw as! AXUIElement),
           wid != 0 {
            return wid
        }
        return nil
    }

    static func focusedOrMainWindowID(pid: pid_t) -> CGWindowID? {
        let appAX = AXUIElementCreateApplication(pid)
        for attr in [kAXFocusedWindowAttribute as CFString, kAXMainWindowAttribute as CFString] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, attr, &ref) == .success,
               let raw = ref,
               CFGetTypeID(raw) == AXUIElementGetTypeID(),
               let wid = windowID(of: raw as! AXUIElement),
               wid != 0 {
                return wid
            }
        }
        return nil
    }

    /// Distinguishes genuine interactive child/preview windows (even when pinned Always-on-Top at `windowLayer == 3`,
    /// such as WeChat 4.0's pinned Image Viewer or Built-in Browser) from borderless transient popovers/menus.
    static func isStandardOrDialogWindow(_ element: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef) == .success,
           let subrole = subroleRef as? String,
           (subrole == (kAXStandardWindowSubrole as String) || subrole == (kAXDialogSubrole as String)) {
            return true
        }
        var closeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
           closeRef != nil {
            return true
        }
        return false
    }

    static func activateProcess(_ pid: pid_t) {
        let appAX = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appAX, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef, let sizeVal = sizeRef,
              CFGetTypeID(posVal) == AXValueGetTypeID(), CFGetTypeID(sizeVal) == AXValueGetTypeID() else {
            return nil
        }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    /// Finds the AX window for `windowID`. Falls back to a STRICT frame match (origin AND size within 3pt).
    /// Returns nil instead of guessing, so callers never move/raise an unrelated window.
    static func find(pid: pid_t, windowID: CGWindowID, frame: CGRect?) -> AXUIElement? {
        let list = allWindows(pid: pid)
        if windowID != 0, let exact = list.first(where: { self.windowID(of: $0) == windowID }) {
            return exact
        }
        guard let frame else { return nil }
        return list.first { win in
            guard let f = self.frame(of: win) else { return false }
            return abs(f.minX - frame.minX) < 3 && abs(f.minY - frame.minY) < 3 &&
                abs(f.width - frame.width) < 3 && abs(f.height - frame.height) < 3
        }
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ origin: CGPoint) -> Bool {
        var pt = origin
        guard let val = AXValueCreate(.cgPoint, &pt) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val) == .success
    }

    @discardableResult
    static func setSize(_ element: AXUIElement, _ size: CGSize) -> Bool {
        var sz = size
        guard let val = AXValueCreate(.cgSize, &sz) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val) == .success
    }

    static func isMinimized(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &ref) == .success,
              let num = ref as? NSNumber else {
            return false
        }
        return num.boolValue
    }

    static func raise(_ element: AXUIElement) {
        AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Presses the window's own Accessibility Close button (`kAXCloseButtonAttribute` -> `kAXPressAction`).
    /// Unlike `⌘W` (which AppKit routes through `keyWindow` -> `mainWindow` and can accidentally close WeChat's
    /// main window when a child/image window isn't key), `kAXPressAction` acts strictly on THIS window instance.
    @discardableResult
    static func pressCloseButton(of element: AXUIElement) -> Bool {
        var closeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
              let raw = closeRef,
              CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return false
        }
        let closeBtn = raw as! AXUIElement
        var enabledRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(closeBtn, kAXEnabledAttribute as CFString, &enabledRef) == .success,
           let enabled = enabledRef as? NSNumber,
           !enabled.boolValue {
            return false
        }
        return AXUIElementPerformAction(closeBtn, kAXPressAction as CFString) == .success
    }

    /// Returns `true` if `windowID` is still visible on-screen (alpha > 0.01).
    static func isWindowOnScreen(_ windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first else {
            return false
        }
        if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 {
            return false
        }
        return true
    }

    /// Returns `true` if `pid` owns at least one other visible normal/child window besides `windowID`.
    static func hasOtherNormalOnScreenWindow(pid: pid_t, excluding windowID: CGWindowID) -> Bool {
        guard pid != 0,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else { return false }
            let wid = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0
            guard wid != 0 && wid != windowID else { return false }
            if let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha <= 0.01 { return false }
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer >= 0 && layer <= 25 else { return false }
            guard let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return false }
            return rect.width >= 140 && rect.height >= 120
        }
    }

    /// Live CG bounds (top-left global coordinates, same space as SCWindow.frame / CGEvent.location).
    static func cgBounds(of windowID: CGWindowID) -> CGRect? {
        guard windowID != 0,
              let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]])?.first,
              let dict = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        return CGRect(dictionaryRepresentation: dict)
    }
}

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
        let list = windows(pid: pid)
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

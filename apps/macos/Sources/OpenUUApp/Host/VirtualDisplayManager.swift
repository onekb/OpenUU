import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Manages an optional software Virtual Display on macOS using Apple's `CGVirtualDisplay` SPI
/// loaded dynamically via Objective-C runtime (zero private headers, safe graceful fallback).
@MainActor
final class VirtualDisplayManager {
    private var virtualDisplayObject: AnyObject?
    private(set) var displayID: CGDirectDisplayID = 0 {
        didSet {
            if displayID != oldValue { onDisplayIDChanged?(displayID) }
        }
    }
    private struct MovedWindow {
        let pid: pid_t
        let originalFrame: CGRect
        var placedOrigin: CGPoint
    }
    private var movedWindows: [CGWindowID: MovedWindow] = [:]
    private var knownSharedPIDs: Set<pid_t> = []
    private let displayQueue = DispatchQueue(label: "ren.onekb.openuu.virtual-display")

    /// Notified (on the main actor) whenever the virtual display is created (id) or destroyed (0).
    var onDisplayIDChanged: ((CGDirectDisplayID) -> Void)?

    /// Top margin reserved for the virtual display's own menu bar ("Displays have separate Spaces" ON).
    static let placementTopMargin: CGFloat = 40
    static let placementSideMargin: CGFloat = 16

    var isActive: Bool {
        displayID != 0 && virtualDisplayObject != nil
    }

    /// Bounds are only reported once WindowServer has actually brought the display online WITH a valid mode.
    /// Measured on macOS 27: right after `applySettings:` returns, `CGDisplayBounds` is still empty for
    /// ~100-200 ms and `CGDisplayCopyDisplayMode` stays nil for up to ~1.5 s. AX moves issued in that window
    /// are silently ignored (the window simply stays on the main display).
    var displayBounds: CGRect? {
        guard displayID != 0 else { return nil }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0, CGDisplayCopyDisplayMode(displayID) != nil else { return nil }
        return bounds
    }

    /// Region of the virtual display where windows may be placed (below its menu bar, with small margins).
    var placementArea: CGRect? {
        guard let vb = displayBounds else { return nil }
        return CGRect(
            x: vb.minX + Self.placementSideMargin,
            y: vb.minY + Self.placementTopMargin,
            width: vb.width - Self.placementSideMargin * 2,
            height: vb.height - Self.placementTopMargin - Self.placementSideMargin
        )
    }

    func isWindowOnVirtualDisplay(_ frame: CGRect) -> Bool {
        guard let vb = displayBounds else { return false }
        return vb.insetBy(dx: -2, dy: -2).contains(frame)
    }

    /// Creates the display if needed and waits (WITHOUT blocking the main thread) until it is fully usable.
    func ensureVirtualDisplayReady(timeout: TimeInterval = 3.0) async -> Bool {
        guard ensureVirtualDisplay() else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while displayBounds == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return displayBounds != nil
    }

    /// Create a persistent 1920x1200 (2x HiDPI) virtual display if not already active.
    /// NOTE: returns as soon as the display object exists; use `ensureVirtualDisplayReady()` before moving windows.
    @discardableResult
    func ensureVirtualDisplay() -> Bool {
        if isActive { return true }

        guard let descClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
              let displayClass = NSClassFromString("CGVirtualDisplay") as? NSObject.Type,
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
              let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type else {
            return false
        }

        let desc = descClass.init()
        desc.setValue("OpenUU Virtual Display", forKey: "name")
        desc.setValue(NSNumber(value: 3840), forKey: "maxPixelsWide")
        desc.setValue(NSNumber(value: 2400), forKey: "maxPixelsHigh")
        desc.setValue(NSValue(size: NSSize(width: 600, height: 375)), forKey: "sizeInMillimeters")
        desc.setValue(NSNumber(value: 0x0001), forKey: "productID")
        desc.setValue(NSNumber(value: 0xC4A3), forKey: "vendorID")
        desc.setValue(NSNumber(value: 0x0001), forKey: "serialNum")
        // Required sRGB color primaries for CGVirtualDisplayDescriptor on macOS 14-27
        desc.setValue(NSValue(point: NSPoint(x: 0.3127, y: 0.3290)), forKey: "whitePoint")
        desc.setValue(NSValue(point: NSPoint(x: 0.64, y: 0.33)), forKey: "redPrimary")
        desc.setValue(NSValue(point: NSPoint(x: 0.30, y: 0.60)), forKey: "greenPrimary")
        desc.setValue(NSValue(point: NSPoint(x: 0.15, y: 0.06)), forKey: "bluePrimary")
        desc.setValue(displayQueue, forKey: "queue")

        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard let allocUnmanaged = displayClass.perform(NSSelectorFromString("alloc")) else {
            return false
        }
        guard displayClass.instancesRespond(to: initSel),
              let initIMP = class_getMethodImplementation(displayClass, initSel) else {
            allocUnmanaged.release()
            return false
        }
        // ObjC ARC ownership: `alloc` returns +1 (`allocUnmanaged`), `initWithDescriptor:`
        // consumes that +1 on `self` and returns a +1 object (or nil). Take retained ONCE.
        typealias InitDescFunc = @convention(c) (UnsafeMutableRawPointer, Selector, AnyObject) -> Unmanaged<AnyObject>?
        let initFn = unsafeBitCast(initIMP, to: InitDescFunc.self)
        guard let createdUnmanaged = initFn(allocUnmanaged.toOpaque(), initSel, desc),
              let created = createdUnmanaged.takeRetainedValue() as? NSObject else {
            return false
        }

        // Create 1920x1200 @ 60Hz HiDPI mode (width/height are UInt32!)
        let mode = createDisplayMode(modeClass: modeClass, width: 1920, height: 1200, refreshRate: 60.0)
        let settings = settingsClass.init()
        settings.setValue(NSNumber(value: 1), forKey: "hiDPI")
        if let mode {
            settings.setValue([mode], forKey: "modes")
        }

        let applySel = NSSelectorFromString("applySettings:")
        if created.responds(to: applySel),
           let applyIMP = created.method(for: applySel) {
            typealias ApplySettingsFunc = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
            let applyFn = unsafeBitCast(applyIMP, to: ApplySettingsFunc.self)
            _ = applyFn(created, applySel, settings)
        }

        if let idNum = created.value(forKey: "displayID") as? NSNumber, idNum.uint32Value != 0 {
            let vid = CGDirectDisplayID(idNum.uint32Value)
            self.virtualDisplayObject = created
            self.displayID = vid
            // Do NOT Thread.sleep here (this runs on the main actor): readiness is awaited asynchronously
            // by `ensureVirtualDisplayReady()`.
            return true
        }
        return false
    }

    func destroyVirtualDisplay() {
        let snapshot = movedWindows
        let pidsSnapshot = knownSharedPIDs
        let oldID = displayID
        returnAllWindowsToMainDisplay()
        virtualDisplayObject = nil
        displayID = 0

        // WindowServer performs an asynchronous display-reconfiguration pass when a CGVirtualDisplay is deallocated,
        // which can shift windows that were just moved back. Re-apply their saved main-display positions once the
        // virtual display has actually gone offline.
        Task { @MainActor in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(50))
                if oldID == 0 || CGDisplayIsOnline(oldID) == 0 {
                    break
                }
            }
            try? await Task.sleep(for: .milliseconds(120))
            Self.restoreWindows(snapshot, extraPIDs: pidsSnapshot, virtualDisplayID: oldID)
        }
    }

    /// Move (and if necessary shrink) a target window so it lies FULLY inside the virtual display.
    ///
    /// - Windows of the same app keep their original relative layout instead of all being stacked at the same
    ///   origin (stacked windows cover each other, so clicks meant for the main window hit a child window).
    /// - Windows larger than the virtual display are resized, otherwise the overflow lands on the neighbouring
    ///   physical display and clicks on that part go to whatever app is on the user's main screen.
    /// - Returns `true` only if the window is verified (read back via AX) to be fully on the virtual display.
    @discardableResult
    func moveWindowToVirtualDisplay(pid: pid_t, windowID: CGWindowID, currentFrame: CGRect) -> Bool {
        guard let area = placementArea else { return false }
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        knownSharedPIDs.insert(pid)

        if isWindowOnVirtualDisplay(currentFrame) {
            // Even if WindowServer auto-migrated this window onto the virtual display when it came online,
            // track it in `movedWindows` so `returnAllWindowsToMainDisplay()` brings it back to the main screen.
            if movedWindows[windowID] == nil {
                let cascade = CGFloat(movedWindows.count % 8) * 32
                let fallbackOriginal = CGRect(
                    x: mainBounds.minX + 120 + cascade,
                    y: mainBounds.minY + 100 + cascade,
                    width: currentFrame.width,
                    height: currentFrame.height
                )
                movedWindows[windowID] = MovedWindow(pid: pid, originalFrame: fallbackOriginal, placedOrigin: currentFrame.origin)
            }
            return true
        }
        guard let axWin = AXWindowLookup.find(pid: pid, windowID: windowID, frame: currentFrame) else {
            return false
        }

        // 1. Shrink oversized windows so they fit entirely on the virtual display.
        var size = currentFrame.size
        if size.width > area.width || size.height > area.height {
            size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
            AXWindowLookup.setSize(axWin, size)
            if let actual = AXWindowLookup.frame(of: axWin)?.size { size = actual }
        }

        // 2. Choose a target origin that preserves the layout relative to an already-moved window of this app.
        let existing = movedWindows[windowID]
        var target: CGPoint
        if let anchor = movedWindows.first(where: { $0.key != windowID && $0.value.pid == pid })?.value {
            target = CGPoint(
                x: anchor.placedOrigin.x + ((existing?.originalFrame.minX ?? currentFrame.minX) - anchor.originalFrame.minX),
                y: anchor.placedOrigin.y + ((existing?.originalFrame.minY ?? currentFrame.minY) - anchor.originalFrame.minY)
            )
        } else {
            let cascade = CGFloat(movedWindows.count % 8) * 28
            target = CGPoint(x: area.minX + 44 + cascade, y: area.minY + 20 + cascade)
        }
        target.x = min(max(target.x, area.minX), area.maxX - size.width)
        target.y = min(max(target.y, area.minY), area.maxY - size.height)

        AXWindowLookup.setPosition(axWin, target)
        let readBack = AXWindowLookup.frame(of: axWin)
        let placed = (readBack != nil && isWindowOnVirtualDisplay(readBack!)) ? readBack! : CGRect(origin: target, size: size)
        if existing == nil {
            movedWindows[windowID] = MovedWindow(pid: pid, originalFrame: currentFrame, placedOrigin: placed.origin)
        } else {
            movedWindows[windowID]?.placedOrigin = placed.origin
        }
        return isWindowOnVirtualDisplay(placed)
    }

    /// Return all previously moved windows ( plus any orphaned windows still on the Virtual Display or off-screen)
    /// back to visible positions on the main display.
    func returnAllWindowsToMainDisplay() {
        let snapshot = movedWindows
        let pidsSnapshot = knownSharedPIDs
        let currentVDID = displayID
        movedWindows.removeAll()
        Self.restoreWindows(snapshot, extraPIDs: pidsSnapshot, virtualDisplayID: currentVDID)
    }

    static func physicalDisplayBounds(excluding virtualDisplayID: CGDirectDisplayID) -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [CGDisplayBounds(CGMainDisplayID())] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let virtualScreenIDs: Set<CGDirectDisplayID> = Set(NSScreen.screens.compactMap { screen in
            guard screen.localizedName.contains("OpenUU Virtual Display"),
                  let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return CGDirectDisplayID(num.uint32Value)
        })
        let result = ids.prefix(Int(count)).compactMap { id -> CGRect? in
            if id == virtualDisplayID || virtualScreenIDs.contains(id) { return nil }
            let b = CGDisplayBounds(id)
            return b.width > 0 && b.height > 0 ? b : nil
        }
        return result.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : result
    }

    static func expandDescendantPIDs(from rootPIDs: Set<pid_t>) -> Set<pid_t> {
        guard !rootPIDs.isEmpty else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size: Int = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return rootPIDs }
        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (size / stride) + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actualSize = capacity * stride
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else { return rootPIDs }
        let count = actualSize / stride
        var ppidMap: [pid_t: pid_t] = [:]
        ppidMap.reserveCapacity(count)
        for i in 0..<count {
            let p = procs[i].kp_proc.p_pid
            let pp = procs[i].kp_eproc.e_ppid
            if p > 0 {
                ppidMap[p] = pp
            }
        }
        let myPID = ProcessInfo.processInfo.processIdentifier
        var matched = rootPIDs
        for candidate in ppidMap.keys where candidate > 1 && candidate != myPID {
            var cur = candidate
            for _ in 0..<8 {
                if matched.contains(cur) {
                    matched.insert(candidate)
                    break
                }
                guard let parent = ppidMap[cur], parent > 1, parent != cur else { break }
                cur = parent
            }
        }
        return matched
    }

    private static func allAXWindows(for pid: pid_t) -> [AXUIElement] {
        var list = AXWindowLookup.windows(pid: pid)
        let appAX = AXUIElementCreateApplication(pid)
        for attr in [kAXMainWindowAttribute as CFString, kAXFocusedWindowAttribute as CFString] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(appAX, attr, &ref) == .success,
               let win = ref,
               CFGetTypeID(win) == AXUIElementGetTypeID() {
                let axWin = win as! AXUIElement
                if !list.contains(where: { CFEqual($0, axWin) }) {
                    list.append(axWin)
                }
            }
        }
        return list
    }

    private static func restoreWindows(
        _ entries: [CGWindowID: MovedWindow],
        extraPIDs: Set<pid_t> = [],
        virtualDisplayID: CGDirectDisplayID = 0
    ) {
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let safeArea = CGRect(x: mainBounds.minX + 20, y: mainBounds.minY + 40,
                              width: mainBounds.width - 40, height: mainBounds.height - 60)
        let physicalBounds = physicalDisplayBounds(excluding: virtualDisplayID)
        let vBounds: CGRect? = {
            guard virtualDisplayID != 0 else { return nil }
            let b = CGDisplayBounds(virtualDisplayID)
            return b.width > 0 && b.height > 0 ? b : nil
        }()

        var handledAXWindows: [AXUIElement] = []

        // 1. Restore explicitly tracked `movedWindows` entries to their saved main-display frames.
        for (windowID, entry) in entries {
            let live = AXWindowLookup.cgBounds(of: windowID)
            if let axWin = AXWindowLookup.find(pid: entry.pid, windowID: windowID, frame: live) {
                if let liveSize = live?.size,
                   abs(liveSize.width - entry.originalFrame.width) > 2 || abs(liveSize.height - entry.originalFrame.height) > 2 {
                    AXWindowLookup.setSize(axWin, entry.originalFrame.size)
                }
                let size = AXWindowLookup.frame(of: axWin)?.size ?? entry.originalFrame.size
                // Ensure the target origin is inside the main display's safe area.
                let orig = mainBounds.contains(CGPoint(x: entry.originalFrame.midX, y: entry.originalFrame.midY))
                    ? entry.originalFrame.origin
                    : CGPoint(x: mainBounds.minX + 120, y: mainBounds.minY + 100)
                let origin = CGPoint(
                    x: min(max(orig.x, safeArea.minX), max(safeArea.minX, safeArea.maxX - size.width)),
                    y: min(max(orig.y, safeArea.minY), max(safeArea.minY, safeArea.maxY - size.height))
                )
                AXWindowLookup.setPosition(axWin, origin)
                handledAXWindows.append(axWin)
            }
        }

        // 2. Scan all windows system-wide to catch any window still sitting on the Virtual Display or off-screen
        //    (e.g., if `OpenUU.app` was restarted while WeChat was on the Virtual Display, or if `windowID` changed).
        var candidatePIDs = extraPIDs
        for entry in entries.values {
            candidatePIDs.insert(entry.pid)
        }
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            if bid == "com.tencent.xinWeChat" ||
               bid.hasPrefix("com.tencent.xinWeChat.") ||
               bid.localizedCaseInsensitiveContains("WeChatAppEx") {
                candidatePIDs.insert(app.processIdentifier)
            }
        }
        candidatePIDs = expandDescendantPIDs(from: candidatePIDs)
        if let cgList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] {
            let myPID = ProcessInfo.processInfo.processIdentifier
            for info in cgList {
                let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
                guard layer == 0,
                      let pidNum = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      pidNum > 0, pidNum != myPID,
                      let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict),
                      rect.width >= 120, rect.height >= 100 else {
                    continue
                }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let onVirtual = vBounds?.contains(center) ?? false
                let onPhysical = physicalBounds.contains { $0.contains(center) }
                if onVirtual || !onPhysical {
                    candidatePIDs.insert(pid_t(pidNum))
                }
            }
        }

        var cascadeIndex = 0
        for pid in candidatePIDs {
            let axList = allAXWindows(for: pid)
            for axWin in axList {
                if handledAXWindows.contains(where: { CFEqual($0, axWin) }) {
                    continue
                }
                guard let frame = AXWindowLookup.frame(of: axWin),
                      frame.width >= 100, frame.height >= 80 else {
                    continue
                }
                let center = CGPoint(x: frame.midX, y: frame.midY)
                let onVirtual = vBounds?.contains(center) ?? false
                let onPhysical = physicalBounds.contains { $0.contains(center) }
                if onVirtual || !onPhysical {
                    let cascade = CGFloat(cascadeIndex % 8) * 32
                    cascadeIndex += 1
                    let origin = CGPoint(
                        x: min(max(mainBounds.minX + 120 + cascade, safeArea.minX), max(safeArea.minX, safeArea.maxX - frame.width)),
                        y: min(max(mainBounds.minY + 100 + cascade, safeArea.minY), max(safeArea.minY, safeArea.maxY - frame.height))
                    )
                    AXWindowLookup.setPosition(axWin, origin)
                }
            }
        }
    }

    private func createDisplayMode(modeClass: NSObject.Type, width: UInt32, height: UInt32, refreshRate: Double) -> NSObject? {
        let sel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard let allocUnmanaged = modeClass.perform(NSSelectorFromString("alloc")) else {
            return nil
        }
        guard modeClass.instancesRespond(to: sel),
              let methodIMP = class_getMethodImplementation(modeClass, sel) else {
            allocUnmanaged.release()
            return nil
        }
        typealias InitFunc = @convention(c) (UnsafeMutableRawPointer, Selector, UInt32, UInt32, Double) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(methodIMP, to: InitFunc.self)
        return fn(allocUnmanaged.toOpaque(), sel, width, height, refreshRate)?.takeRetainedValue() as? NSObject
    }
}

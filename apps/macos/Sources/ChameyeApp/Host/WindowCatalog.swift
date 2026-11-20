import Foundation
import ScreenCaptureKit

struct ShareableWindowItem: Identifiable, Hashable, @unchecked Sendable {
    let window: SCWindow
    let windowID: UInt32
    let appName: String
    let bundleID: String
    let title: String
    let width: Int
    let height: Int

    var id: UInt32 { windowID }

    static func == (lhs: ShareableWindowItem, rhs: ShareableWindowItem) -> Bool {
        lhs.windowID == rhs.windowID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(windowID)
    }
}

enum WindowCatalog {
    static let weChatBundleID = "com.tencent.xinWeChat"

    static func fetchWindows() async throws -> [ShareableWindowItem] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let myPID = ProcessInfo.processInfo.processIdentifier
        let items: [ShareableWindowItem] = content.windows.compactMap { win in
            guard let app = win.owningApplication else { return nil }
            guard app.processID != myPID else { return nil }
            guard win.frame.width >= 100, win.frame.height >= 100 else { return nil }
            return ShareableWindowItem(
                window: win,
                windowID: win.windowID,
                appName: app.applicationName,
                bundleID: app.bundleIdentifier,
                title: win.title ?? app.applicationName,
                width: Int(win.frame.width),
                height: Int(win.frame.height)
            )
        }
        // Put WeChat windows at the very top for quick selection.
        return items.sorted { lhs, rhs in
            let lIsWeChat = lhs.bundleID == weChatBundleID
            let rIsWeChat = rhs.bundleID == weChatBundleID
            if lIsWeChat != rIsWeChat { return lIsWeChat }
            return lhs.appName < rhs.appName
        }
    }
}

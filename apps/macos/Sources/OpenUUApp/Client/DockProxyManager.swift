import AppKit
import Foundation

extension Notification.Name {
    static let openuuFocusApp = Notification.Name("ren.onekb.openuu.dock.focusApp")
    static let openuuCloseApp = Notification.Name("ren.onekb.openuu.dock.closeApp")
    static let openuuUpdateBadge = Notification.Name("ren.onekb.openuu.dock.updateBadge")
    static let openuuUpdateIcon = Notification.Name("ren.onekb.openuu.dock.updateIcon")
}

/// Manages per-remote-app Dock proxy processes so each opened remote app gets its own icon in the macOS Dock
/// (redrawn with the OpenUU badge in the top-right corner).
@MainActor
final class DockProxyManager {
    private var processes: [String: Process] = [:]
    private var latestBadges: [String: String] = [:]
    var onFocusAppRequested: ((String) -> Void)?
    var onCloseAppRequested: ((String) -> Void)?

    init() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .openuuFocusApp, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String else { return }
            Task { @MainActor in
                self?.onFocusAppRequested?(key)
            }
        }
        dnc.addObserver(forName: .openuuCloseApp, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String else { return }
            Task { @MainActor in
                self?.processes.removeValue(forKey: key)
                self?.onCloseAppRequested?(key)
            }
        }
    }

    func ensureDockIcon(for appKey: String, title: String, compositedIcon: NSImage) {
        if let proc = processes[appKey], proc.isRunning {
            return
        }
        guard let execPath = Bundle.main.executablePath ?? CommandLine.arguments.first,
              let iconPath = IconCompositor.saveTempPNG(compositedIcon, key: appKey) else {
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: execPath)
        proc.arguments = [
            "--dock-proxy",
            "--app-key", appKey,
            "--title", title,
            "--icon", iconPath,
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--badge", latestBadges[appKey] ?? "",
        ]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.processes.removeValue(forKey: appKey)
            }
        }
        do {
            try proc.run()
            processes[appKey] = proc
        } catch {
            // Non-fatal: fallback gracefully if child process launch fails
        }
    }

    func updateBadge(_ badgeText: String, for appKey: String) {
        latestBadges[appKey] = badgeText
        DistributedNotificationCenter.default().postNotificationName(
            .openuuUpdateBadge,
            object: appKey,
            userInfo: ["badge": badgeText],
            deliverImmediately: true
        )
    }

    func updateIcon(_ compositedIcon: NSImage, for appKey: String) {
        guard let proc = processes[appKey], proc.isRunning,
              let iconPath = IconCompositor.saveTempPNG(compositedIcon, key: "\(appKey)-\(Int(Date().timeIntervalSince1970 * 1000))") else {
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            .openuuUpdateIcon,
            object: appKey,
            userInfo: ["iconPath": iconPath],
            deliverImmediately: true
        )
    }

    func removeDockIcon(for appKey: String) {
        if let proc = processes.removeValue(forKey: appKey), proc.isRunning {
            proc.terminate()
        }
    }

    func terminateAll() {
        for proc in processes.values where proc.isRunning {
            proc.terminate()
        }
        processes.removeAll()
        latestBadges.removeAll()
    }
}

/// Lightweight AppKit entry point executed when OpenUU is launched with `--dock-proxy`.
@MainActor
final class DockProxyRunner: NSObject, NSApplicationDelegate {
    private let appKey: String
    private let title: String
    private let iconPath: String
    private let parentPID: pid_t
    private let initialBadge: String
    private var parentWatchTimer: Timer?
    private var hasLaunched = false

    init(appKey: String, title: String, iconPath: String, parentPID: pid_t, initialBadge: String) {
        self.appKey = appKey
        self.title = title
        self.iconPath = iconPath
        self.parentPID = parentPID
        self.initialBadge = initialBadge
    }

    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard args.contains("--dock-proxy") else { return false }

        func argValue(_ flag: String) -> String? {
            guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
            return args[idx + 1]
        }

        let appKey = argValue("--app-key") ?? "remote"
        let title = argValue("--title") ?? "OpenUU Remote"
        let iconPath = argValue("--icon") ?? ""
        let parentPID = pid_t(argValue("--parent-pid") ?? "0") ?? 0
        let initialBadge = argValue("--badge") ?? ""

        let app = NSApplication.shared
        let runner = DockProxyRunner(appKey: appKey, title: title, iconPath: iconPath, parentPID: parentPID, initialBadge: initialBadge)
        app.delegate = runner
        app.setActivationPolicy(.regular)
        if let img = NSImage(contentsOfFile: iconPath) {
            app.applicationIconImage = img
        }
        app.run()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let img = NSImage(contentsOfFile: iconPath) {
            NSApp.applicationIconImage = img
        }
        if !initialBadge.isEmpty {
            NSApp.dockTile.badgeLabel = initialBadge
            NSApp.dockTile.display()
        }
        hasLaunched = true

        DistributedNotificationCenter.default().addObserver(
            forName: .openuuUpdateBadge,
            object: appKey,
            queue: .main
        ) { note in
            let badge = (note.userInfo?["badge"] as? String) ?? ""
            Task { @MainActor in
                NSApp.dockTile.badgeLabel = badge.isEmpty ? nil : badge
                NSApp.dockTile.display()
            }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .openuuUpdateIcon,
            object: appKey,
            queue: .main
        ) { note in
            let path = (note.userInfo?["iconPath"] as? String) ?? ""
            Task { @MainActor in
                if let img = NSImage(contentsOfFile: path) {
                    NSApp.applicationIconImage = img
                    NSApp.dockTile.display()
                }
            }
        }

        // Auto-exit if parent OpenUU process terminates
        if parentPID > 0 {
            parentWatchTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                if kill(self.parentPID, 0) != 0 {
                    Task { @MainActor in
                        NSApp.terminate(nil)
                    }
                }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard hasLaunched else { return }
        DistributedNotificationCenter.default().postNotificationName(
            .openuuFocusApp,
            object: appKey,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DistributedNotificationCenter.default().postNotificationName(
            .openuuFocusApp,
            object: appKey,
            userInfo: nil,
            deliverImmediately: true
        )
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if parentPID > 0, kill(parentPID, 0) == 0 {
            DistributedNotificationCenter.default().postNotificationName(
                .openuuCloseApp,
                object: appKey,
                userInfo: nil,
                deliverImmediately: true
            )
        }
    }
}

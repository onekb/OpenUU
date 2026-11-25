import AppKit
import Foundation

extension Notification.Name {
    static let openuuFocusApp = Notification.Name("ren.onekb.openuu.dock.focusApp")
    static let openuuCloseApp = Notification.Name("ren.onekb.openuu.dock.closeApp")
    static let openuuUpdateBadge = Notification.Name("ren.onekb.openuu.dock.updateBadge")
    static let openuuUpdateIcon = Notification.Name("ren.onekb.openuu.dock.updateIcon")
}

/// Manages per-remote-app / per-remote-window Dock proxy processes so each opened remote window gets its own
/// native icon AND original window title in the macOS Dock (via lightweight symlink `.app` wrappers in Caches).
@MainActor
final class DockProxyManager {
    private struct ProxyEntry {
        let process: Process
        let title: String
        let slotDir: URL
        var iconPath: String
        let generation: UInt64
    }

    private var entries: [String: ProxyEntry] = [:]
    private var latestBadges: [String: String] = [:]
    private var latestIcons: [String: NSImage] = [:]
    private var pendingTitleTasks: [String: Task<Void, Never>] = [:]
    private var nextGeneration: UInt64 = 1
    private let cacheRoot: URL

    var onFocusAppRequested: ((String) -> Void)?
    var onCloseAppRequested: ((String) -> Void)?

    init() {
        let caches = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/OpenUU/DockProxies", isDirectory: true)
        self.cacheRoot = caches
        // Clean up any stale wrapper bundles left behind by previous app runs
        try? FileManager.default.removeItem(at: caches)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)

        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .openuuFocusApp, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String else { return }
            Task { @MainActor in
                self?.onFocusAppRequested?(key)
            }
        }
        dnc.addObserver(forName: .openuuCloseApp, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String else { return }
            let gen = (note.userInfo?["generation"] as? NSNumber)?.uint64Value
            Task { @MainActor in
                guard let self else { return }
                // Ignore termination notices from older proxy generations replaced during a live title update.
                if let gen, let current = self.entries[key], current.generation != gen {
                    return
                }
                if let removed = self.entries.removeValue(forKey: key) {
                    try? FileManager.default.removeItem(at: removed.slotDir)
                }
                self.pendingTitleTasks.removeValue(forKey: key)?.cancel()
                self.onCloseAppRequested?(key)
            }
        }
    }

    func ensureDockIcon(for appKey: String, title: String, compositedIcon: NSImage) {
        let cleanTitle = Self.sanitizedDockTitle(title)
        latestIcons[appKey] = compositedIcon

        if let existing = entries[appKey], existing.process.isRunning {
            if existing.title != cleanTitle {
                updateTitle(cleanTitle, for: appKey)
            }
            return
        }

        launchProxy(for: appKey, title: cleanTitle, icon: compositedIcon)
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
        latestIcons[appKey] = compositedIcon
        guard var existing = entries[appKey], existing.process.isRunning else {
            return
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let newIconURL = existing.slotDir.appendingPathComponent("icon-\(stamp).png")
        guard Self.writePNG(compositedIcon, to: newIconURL) else {
            return
        }
        let oldIconPath = existing.iconPath
        existing.iconPath = newIconURL.path
        entries[appKey] = existing

        DistributedNotificationCenter.default().postNotificationName(
            .openuuUpdateIcon,
            object: appKey,
            userInfo: ["iconPath": newIconURL.path],
            deliverImmediately: true
        )

        if oldIconPath != newIconURL.path {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                try? FileManager.default.removeItem(atPath: oldIconPath)
            }
        }
    }

    /// Seamlessly updates the Dock icon's hover title by swapping to a freshly named lightweight `.app` wrapper
    /// while preserving the latest composited icon and unread badge.
    func updateTitle(_ newTitle: String, for appKey: String) {
        let cleanTitle = Self.sanitizedDockTitle(newTitle)
        guard let existing = entries[appKey], existing.process.isRunning else { return }
        guard existing.title != cleanTitle else { return }

        pendingTitleTasks[appKey]?.cancel()
        pendingTitleTasks[appKey] = Task { @MainActor [weak self] in
            // Short debounce so rapid window title transitions during app/Mini-Program loading swap only once.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.pendingTitleTasks.removeValue(forKey: appKey)
            guard let oldEntry = self.entries[appKey], oldEntry.process.isRunning else { return }
            guard oldEntry.title != cleanTitle else { return }

            let icon = self.latestIcons[appKey]
                ?? NSImage(contentsOfFile: oldEntry.iconPath)
                ?? IconCompositor.compositeWithOpenUUBadge(nil)

            if self.launchProxy(for: appKey, title: cleanTitle, icon: icon) {
                try? await Task.sleep(for: .milliseconds(120))
                if oldEntry.process.isRunning {
                    oldEntry.process.terminate()
                }
                try? FileManager.default.removeItem(at: oldEntry.slotDir)
            }
        }
    }

    func removeDockIcon(for appKey: String) {
        pendingTitleTasks.removeValue(forKey: appKey)?.cancel()
        latestIcons.removeValue(forKey: appKey)
        if let entry = entries.removeValue(forKey: appKey) {
            if entry.process.isRunning {
                if NSApp.windows.contains(where: { ($0 is RemoteProxyNSWindow) && $0.isVisible }) {
                    MainPanelCoordinator.shared.markRemoteWindowFocusRequested()
                }
                entry.process.terminate()
            }
            try? FileManager.default.removeItem(at: entry.slotDir)
        }
    }

    func terminateAll() {
        for task in pendingTitleTasks.values {
            task.cancel()
        }
        pendingTitleTasks.removeAll()
        for entry in entries.values {
            if entry.process.isRunning {
                entry.process.terminate()
            }
        }
        entries.removeAll()
        latestBadges.removeAll()
        latestIcons.removeAll()
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    // MARK: - Lightweight Dynamic .app Bundle Wrapper

    @discardableResult
    private func launchProxy(for appKey: String, title: String, icon: NSImage) -> Bool {
        guard let execPath = Bundle.main.executablePath ?? CommandLine.arguments.first else {
            return false
        }
        let gen = nextGeneration
        nextGeneration += 1

        let fm = FileManager.default
        let safeKey = appKey.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
        let slotDir = cacheRoot.appendingPathComponent("\(safeKey)-g\(gen)", isDirectory: true)
        let bundleDir = slotDir.appendingPathComponent("\(title).app", isDirectory: true)
        let macosDir = bundleDir.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let symlinkExec = macosDir.appendingPathComponent("OpenUUProxy")
        let iconURL = slotDir.appendingPathComponent("icon.png")

        do {
            try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: symlinkExec.path, withDestinationPath: execPath)
            let plist = Self.buildInfoPlist(
                bundleID: "ren.onekb.openuu.dockproxy.\(safeKey).g\(gen)",
                displayName: title
            )
            try plist.write(
                to: bundleDir.appendingPathComponent("Contents/Info.plist"),
                atomically: true,
                encoding: .utf8
            )
        } catch {
            try? fm.removeItem(at: slotDir)
            return false
        }

        guard Self.writePNG(icon, to: iconURL) else {
            try? fm.removeItem(at: slotDir)
            return false
        }

        let proc = Process()
        proc.executableURL = symlinkExec
        proc.arguments = [
            "--dock-proxy",
            "--app-key", appKey,
            "--title", title,
            "--icon", iconURL.path,
            "--parent-pid", "\(ProcessInfo.processInfo.processIdentifier)",
            "--badge", latestBadges[appKey] ?? "",
            "--generation", "\(gen)",
        ]
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let current = self.entries[appKey], current.generation == gen {
                    self.entries.removeValue(forKey: appKey)
                    try? FileManager.default.removeItem(at: slotDir)
                }
            }
        }
        do {
            try proc.run()
            entries[appKey] = ProxyEntry(
                process: proc,
                title: title,
                slotDir: slotDir,
                iconPath: iconURL.path,
                generation: gen
            )
            return true
        } catch {
            try? fm.removeItem(at: slotDir)
            return false
        }
    }

    private static func sanitizedDockTitle(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "／")
            .replacingOccurrences(of: ":", with: "：")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") {
            s.removeFirst()
        }
        if s.count > 64 {
            s = String(s.prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? "远程窗口" : s
    }

    private static func xmlEscaped(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func buildInfoPlist(bundleID: String, displayName: String) -> String {
        let escapedName = xmlEscaped(displayName)
        let escapedBID = xmlEscaped(bundleID)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>OpenUUProxy</string>
            <key>CFBundleIdentifier</key>
            <string>\(escapedBID)</string>
            <key>CFBundleName</key>
            <string>\(escapedName)</string>
            <key>CFBundleDisplayName</key>
            <string>\(escapedName)</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleVersion</key>
            <string>1</string>
            <key>LSMinimumSystemVersion</key>
            <string>14.0</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func writePNG(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return false
        }
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
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
    private let generation: UInt64
    private var parentWatchTimer: Timer?
    private var hasLaunched = false

    init(appKey: String, title: String, iconPath: String, parentPID: pid_t, initialBadge: String, generation: UInt64) {
        self.appKey = appKey
        self.title = title
        self.iconPath = iconPath
        self.parentPID = parentPID
        self.initialBadge = initialBadge
        self.generation = generation
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
        let generation = UInt64(argValue("--generation") ?? "0") ?? 0

        let app = NSApplication.shared
        let runner = DockProxyRunner(
            appKey: appKey,
            title: title,
            iconPath: iconPath,
            parentPID: parentPID,
            initialBadge: initialBadge,
            generation: generation
        )
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
                userInfo: ["generation": NSNumber(value: generation)],
                deliverImmediately: true
            )
        }
    }
}

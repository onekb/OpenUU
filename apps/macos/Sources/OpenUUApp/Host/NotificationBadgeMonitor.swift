import AppKit
import ApplicationServices
import Foundation

/// Host-side monitor that watches:
/// 1) macOS Dock `AXStatusLabel` for unread badge numbers on shared apps (e.g. WeChat);
/// 2) macOS NotificationCenter banners via Accessibility API to forward rich message notifications.
/// Runs AX queries on a dedicated background serial queue to avoid blocking the main/UI thread.
final class NotificationBadgeMonitor: @unchecked Sendable {
    var onNotification: ((_ bundleID: String, _ title: String, _ subtitle: String, _ body: String) -> Void)?
    var onBadgeChanged: ((_ bundleID: String, _ badgeText: String) -> Void)?

    private let queue = DispatchQueue(label: "ren.onekb.openuu.notif-monitor", qos: .utility)
    private var badgeTimer: DispatchSourceTimer?
    private var bannerTimer: DispatchSourceTimer?
    private var isRunning = false
    private var isEnabled = true

    /// Map of shared bundleID -> display names (e.g. "com.tencent.xinWeChat" -> ["微信", "WeChat"]).
    private var watchedApps: [String: [String]] = [:]
    private var urlBundleIDCache: [String: String] = [:]
    private var lastBadgeByBundle: [String: String] = [:]
    private var lastBannerTimeByBundle: [String: CFAbsoluteTime] = [:]
    private var recentBannerFingerprints: [String: CFAbsoluteTime] = [:]

    func setEnabled(_ enabled: Bool) {
        queue.async { [weak self] in
            self?.isEnabled = enabled
        }
    }

    func updateWatchedApps(_ apps: [(bundleID: String, name: String)]) {
        queue.async { [weak self] in
            guard let self else { return }
            var map: [String: [String]] = [:]
            for app in apps where !app.bundleID.isEmpty {
                var aliases: [String] = []
                if !app.name.isEmpty { aliases.append(app.name) }
                if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first,
                   let locName = running.localizedName, !locName.isEmpty, !aliases.contains(locName) {
                    aliases.append(locName)
                }
                if app.bundleID == "com.tencent.xinWeChat" {
                    for alias in ["微信", "WeChat"] where !aliases.contains(alias) {
                        aliases.append(alias)
                    }
                }
                map[app.bundleID] = aliases
            }
            self.watchedApps = map
        }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isRunning else { return }
            self.isRunning = true
            self.lastBadgeByBundle.removeAll()
            self.recentBannerFingerprints.removeAll()

            let bTimer = DispatchSource.makeTimerSource(queue: self.queue)
            bTimer.schedule(deadline: .now() + .milliseconds(500), repeating: .seconds(2))
            bTimer.setEventHandler { [weak self] in
                self?.pollDockBadges()
            }
            bTimer.resume()
            self.badgeTimer = bTimer

            let nTimer = DispatchSource.makeTimerSource(queue: self.queue)
            nTimer.schedule(deadline: .now() + .milliseconds(600), repeating: .milliseconds(1200))
            nTimer.setEventHandler { [weak self] in
                self?.pollNotificationBanners()
            }
            nTimer.resume()
            self.bannerTimer = nTimer
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.badgeTimer?.cancel()
            self.badgeTimer = nil
            self.bannerTimer?.cancel()
            self.bannerTimer = nil
            self.lastBadgeByBundle.removeAll()
            self.recentBannerFingerprints.removeAll()
        }
    }

    // MARK: - 1. Dock Unread Badge Polling

    private func pollDockBadges() {
        guard isRunning, isEnabled, AXIsProcessTrusted() else { return }
        guard !watchedApps.isEmpty else { return }
        guard let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            return
        }

        let axDock = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard let children = axAttr(axDock, kAXChildrenAttribute) as? [AXUIElement] else { return }

        var observedBadges: [String: String] = [:]
        for list in children {
            guard let items = axAttr(list, kAXChildrenAttribute) as? [AXUIElement] else { continue }
            for item in items {
                let title = (axAttr(item, kAXTitleAttribute) as? String) ?? ""
                let url = axAttr(item, kAXURLAttribute) as? URL
                guard let bundleID = resolveWatchedBundleID(url: url, title: title) else { continue }
                let status = (axAttr(item, "AXStatusLabel") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                observedBadges[bundleID] = status
            }
        }

        let now = CFAbsoluteTimeGetCurrent()
        for (bundleID, aliases) in watchedApps {
            let newBadge = observedBadges[bundleID] ?? ""
            let oldBadge = lastBadgeByBundle[bundleID]
            guard oldBadge != newBadge else { continue }
            lastBadgeByBundle[bundleID] = newBadge
            onBadgeChanged?(bundleID, newBadge)

            // Fallback notification when Host Do-Not-Disturb suppresses NotificationCenter banners
            // but the unread badge count still increased.
            if let old = oldBadge, badgeIncreased(from: old, to: newBadge) {
                let lastBanner = lastBannerTimeByBundle[bundleID] ?? 0
                if now - lastBanner > 2.5 {
                    let appName = aliases.first ?? bundleID
                    let body = newBadge.isEmpty ? "收到新消息" : "收到新消息（当前未读: \(newBadge)）"
                    onNotification?(bundleID, appName, "", body)
                }
            }
        }
    }

    private func resolveWatchedBundleID(url: URL?, title: String) -> String? {
        if let url {
            let key = url.path
            if let cached = urlBundleIDCache[key] {
                if watchedApps[cached] != nil { return cached }
            } else if let bid = Bundle(url: url)?.bundleIdentifier {
                urlBundleIDCache[key] = bid
                if watchedApps[bid] != nil { return bid }
            }
        }
        if !title.isEmpty {
            for (bid, aliases) in watchedApps {
                if aliases.contains(where: { $0.caseInsensitiveCompare(title) == .orderedSame }) {
                    return bid
                }
            }
        }
        return nil
    }

    private func badgeIncreased(from old: String, to new: String) -> Bool {
        guard !new.isEmpty else { return false }
        if old.isEmpty { return true }
        let oldNum = Int(old.filter(\.isNumber)) ?? 0
        let newNum = Int(new.filter(\.isNumber)) ?? 0
        return newNum > oldNum
    }

    // MARK: - 2. NotificationCenter Banner Polling

    private func pollNotificationBanners() {
        guard isRunning, isEnabled, AXIsProcessTrusted() else { return }
        guard !watchedApps.isEmpty else { return }
        guard let ncApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.notificationcenterui").first else {
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        // Expire old dedup fingerprints (> 20s)
        recentBannerFingerprints = recentBannerFingerprints.filter { now - $0.value < 20.0 }

        let axNC = AXUIElementCreateApplication(ncApp.processIdentifier)
        guard let windows = axAttr(axNC, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return
        }

        for win in windows {
            let subrole = (axAttr(win, kAXSubroleAttribute) as? String) ?? ""
            let winDesc = (axAttr(win, kAXDescriptionAttribute) as? String) ?? ""
            // Collect visible text nodes inside the notification banner window
            var texts: [String] = []
            collectBannerTexts(from: win, depth: 0, maxDepth: 9, into: &texts)

            // Also include window description if it contains comma-separated summary (macOS 14-27 AXNotificationCenterBanner)
            let combinedSearch = ([winDesc, subrole] + texts).joined(separator: " ")
            guard let matched = matchWatchedApp(in: combinedSearch, texts: texts) else { continue }

            let cleanedTexts = deduplicateOrdered(texts.filter { !$0.isEmpty && $0.count <= 400 })
            guard !cleanedTexts.isEmpty || !winDesc.isEmpty else { continue }

            let (title, subtitle, body) = parseBannerFields(
                appName: matched.appName,
                texts: cleanedTexts,
                fallbackDesc: winDesc
            )
            guard !title.isEmpty || !body.isEmpty else { continue }

            let fingerprint = "\(matched.bundleID)|\(title)|\(subtitle)|\(body)"
            if recentBannerFingerprints[fingerprint] != nil {
                continue
            }
            recentBannerFingerprints[fingerprint] = now
            lastBannerTimeByBundle[matched.bundleID] = now
            onNotification?(matched.bundleID, title, subtitle, body)
        }
    }

    private func collectBannerTexts(from el: AXUIElement, depth: Int, maxDepth: Int, into result: inout [String]) {
        guard depth <= maxDepth else { return }
        let role = (axAttr(el, kAXRoleAttribute) as? String) ?? ""
        if role == kAXStaticTextRole as String {
            if let val = axAttr(el, kAXValueAttribute) as? String {
                let trimmed = val.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            } else if let title = axAttr(el, kAXTitleAttribute) as? String {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            }
        }
        if let children = axAttr(el, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                collectBannerTexts(from: child, depth: depth + 1, maxDepth: maxDepth, into: &result)
            }
        }
    }

    private func matchWatchedApp(in combined: String, texts: [String]) -> (bundleID: String, appName: String)? {
        for (bid, aliases) in watchedApps {
            for alias in aliases where !alias.isEmpty {
                if combined.localizedCaseInsensitiveContains(alias) {
                    return (bid, aliases.first ?? alias)
                }
            }
        }
        return nil
    }

    private func parseBannerFields(appName: String, texts: [String], fallbackDesc: String) -> (title: String, subtitle: String, body: String) {
        // Filter out standalone time stamps like "现在" / "now" or duplicate app name
        let filtered = texts.filter { t in
            let lower = t.lowercased()
            return lower != "now" && t != "现在" && t != "刚刚"
        }
        if filtered.count >= 3 {
            let firstIsApp = filtered[0].caseInsensitiveCompare(appName) == .orderedSame
            if firstIsApp {
                return (filtered[1], "", filtered[2...].joined(separator: " "))
            }
            return (filtered[0], filtered[1], filtered[2...].joined(separator: " "))
        } else if filtered.count == 2 {
            return (filtered[0], "", filtered[1])
        } else if filtered.count == 1 {
            return (appName, "", filtered[0])
        }
        let cleaned = fallbackDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        return (appName, "", cleaned)
    }

    private func deduplicateOrdered(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for item in items where seen.insert(item).inserted {
            out.append(item)
        }
        return out
    }

    private func axAttr(_ el: AXUIElement, _ key: String) -> AnyObject? {
        var val: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, key as CFString, &val)
        return err == .success ? val : nil
    }
}

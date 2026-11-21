import AppKit
import Foundation
import UserNotifications

/// Client-side native macOS notification presenter for forwarded remote app alerts (e.g., WeChat messages).
/// Clicking a notification focuses (or opens) the corresponding remote app window.
@MainActor
final class ClientNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    var isEnabled: Bool = true
    var onNotificationClicked: ((_ bundleID: String) -> Void)?

    private var hasConfiguredCenter = false
    private let iconCacheDir: URL = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("openuu-notif-icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var isBundledApp: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    func requestPermissionIfNeeded() {
        guard isBundledApp else { return }
        let center = UNUserNotificationCenter.current()
        if !hasConfiguredCenter {
            hasConfiguredCenter = true
            center.delegate = self
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func presentRemoteNotification(
        bundleID: String,
        appName: String,
        title: String,
        subtitle: String,
        body: String,
        icon: NSImage?
    ) {
        guard isEnabled, isBundledApp else { return }
        requestPermissionIfNeeded()

        let content = UNMutableNotificationContent()
        content.title = title.isEmpty ? appName : title
        if !subtitle.isEmpty {
            content.subtitle = subtitle
        } else if !appName.isEmpty && content.title != appName {
            content.subtitle = appName
        }
        content.body = body.isEmpty ? "收到新消息" : body
        content.sound = .default
        content.userInfo = ["bundle_id": bundleID]

        if let icon, let attachment = makeIconAttachment(icon: icon, bundleID: bundleID) {
            content.attachments = [attachment]
        }

        let id = "openuu-\(bundleID)-\(UUID().uuidString)"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func makeIconAttachment(icon: NSImage, bundleID: String) -> UNNotificationAttachment? {
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let safe = bundleID.replacingOccurrences(of: "/", with: "_")
        let url = iconCacheDir.appendingPathComponent("\(safe)-\(UUID().uuidString).png")
        do {
            try png.write(to: url)
            return try UNNotificationAttachment(identifier: "icon", url: url, options: nil)
        } catch {
            return nil
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let bundleID = response.notification.request.content.userInfo["bundle_id"] as? String ?? ""
        Task { @MainActor [weak self] in
            if !bundleID.isEmpty {
                self?.onNotificationClicked?(bundleID)
            }
        }
        completionHandler()
    }
}

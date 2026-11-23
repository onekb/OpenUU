import Combine
import Foundation
import SwiftUI
import UIKit

enum MobileAppVersion {
    static let fallback = "0.7.0"

    static var current: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return v.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback
    }

    static var display: String {
        current.hasPrefix("v") ? current : "v\(current)"
    }

    static func parseSemVer(_ raw: String) -> (Int, Int, Int)? {
        var clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while clean.hasPrefix("v") || clean.hasPrefix("V") {
            clean.removeFirst()
        }
        if let idx = clean.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            clean = String(clean[..<idx])
        }
        let parts = clean.split(separator: ".")
        guard let maj = parts.first.flatMap({ Int($0) }) else { return nil }
        let min = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let pat = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return (maj, min, pat)
    }

    static func isNewer(current: String, latest: String) -> Bool {
        guard let c = parseSemVer(current), let l = parseSemVer(latest) else { return false }
        if l.0 != c.0 { return l.0 > c.0 }
        if l.1 != c.1 { return l.1 > c.1 }
        return l.2 > c.2
    }
}

enum MobileUpdatePolicy: String, CaseIterable, Identifiable {
    case launchAndDaily = "launch_and_daily"
    case dailyOnly = "daily"
    case manualOnly = "manual"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchAndDaily: return "打开时与每天检查"
        case .dailyOnly: return "每天检查一次"
        case .manualOnly: return "仅手动检查"
        }
    }
}

struct MobileReleaseInfo: Equatable {
    let hasUpdate: Bool
    let currentVersion: String
    let latestVersion: String
    let tagName: String
    let title: String
    let releaseNotes: String
    let publishedAt: String
    let htmlURL: String
    let assetName: String
    let downloadURL: String
    let assetSizeBytes: Int64

    var formattedSize: String {
        guard assetSizeBytes > 0 else { return "" }
        return String(format: "%.1f MB", Double(assetSizeBytes) / 1_048_576.0)
    }

    var formattedDate: String {
        guard !publishedAt.isEmpty else { return "" }
        return String(publishedAt.prefix(10))
    }
}

private struct GithubReleaseResp: Decodable {
    let tag_name: String?
    let name: String?
    let body: String?
    let html_url: String?
    let published_at: String?
    let draft: Bool?
    let assets: [GithubAssetResp]?
}

private struct GithubAssetResp: Decodable {
    let name: String?
    let size: Int64?
    let browser_download_url: String?
}

@MainActor
final class MobileAppUpdater: ObservableObject {
    static let githubLatestAPI = "https://api.github.com/repos/onekb/OpenUU/releases/latest"
    static let githubReleasesPage = "https://github.com/onekb/OpenUU/releases/latest"

    private enum PrefKey {
        static let policy = "openuu.ios.updater.policy"
        static let lastCheckEpoch = "openuu.ios.updater.lastCheckEpoch"
        static let skippedVersion = "openuu.ios.updater.skippedVersion"
    }

    @Published var policy: MobileUpdatePolicy = MobileUpdatePolicy(
        rawValue: UserDefaults.standard.string(forKey: PrefKey.policy) ?? ""
    ) ?? .launchAndDaily {
        didSet {
            UserDefaults.standard.set(policy.rawValue, forKey: PrefKey.policy)
        }
    }

    @Published var isChecking: Bool = false
    @Published var releaseInfo: MobileReleaseInfo?
    @Published var statusSummary: String = "尚未检查"
    @Published var showingUpdateSheet: Bool = false

    var coordURLProvider: (() -> String)?
    var onLog: ((String) -> Void)?
    private var dailyTask: Task<Void, Never>?

    var hasAvailableUpdate: Bool {
        releaseInfo?.hasUpdate == true
    }

    init() {
        refreshLastCheckLabel()
    }

    deinit {
        dailyTask?.cancel()
    }

    func startScheduledChecks() {
        dailyTask?.cancel()
        dailyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            guard let self, !Task.isCancelled else { return }
            self.runScheduledCheckIfDue(isLaunch: true)

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6 * 3600))
                guard !Task.isCancelled else { break }
                self.runScheduledCheckIfDue(isLaunch: false)
            }
        }
    }

    private func runScheduledCheckIfDue(isLaunch: Bool) {
        switch policy {
        case .manualOnly:
            return
        case .launchAndDaily:
            if isLaunch || isDailyDue() {
                Task { await checkForUpdates(manual: false) }
            }
        case .dailyOnly:
            if isDailyDue() {
                Task { await checkForUpdates(manual: false) }
            }
        }
    }

    private func isDailyDue() -> Bool {
        let last = UserDefaults.standard.double(forKey: PrefKey.lastCheckEpoch)
        if last <= 0 { return true }
        return (Date().timeIntervalSince1970 - last) >= 24 * 3600
    }

    private func refreshLastCheckLabel() {
        let last = UserDefaults.standard.double(forKey: PrefKey.lastCheckEpoch)
        guard last > 0 else {
            statusSummary = "当前 \(MobileAppVersion.display)"
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        statusSummary = "上次检查 \(fmt.string(from: Date(timeIntervalSince1970: last)))"
    }

    func skipCurrentAvailableVersion() {
        guard let ver = releaseInfo?.latestVersion, !ver.isEmpty else { return }
        UserDefaults.standard.set(ver, forKey: PrefKey.skippedVersion)
        showingUpdateSheet = false
        onLog?("已忽略版本 v\(ver)")
    }

    func checkForUpdates(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        if manual {
            statusSummary = "正在检查..."
        }
        defer { isChecking = false }

        let coordBase = (coordURLProvider?() ?? OpenUUConstants.defaultCoordURL)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var urls: [String] = []
        if !coordBase.isEmpty {
            urls.append("\(coordBase)/v1/latest-release")
        }
        urls.append(Self.githubLatestAPI)

        var lastError = "连接更新服务失败"
        for u in urls {
            guard let url = URL(string: u) else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6.5)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("OpenUU-iOS/\(MobileAppVersion.current)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    lastError = "HTTP 状态异常"
                    continue
                }
                let dto = try JSONDecoder().decode(GithubReleaseResp.self, from: data)
                if dto.draft == true { continue }
                guard let rawTag = dto.tag_name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTag.isEmpty else {
                    continue
                }

                let curVer = MobileAppVersion.current
                let latestClean = rawTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let newer = MobileAppVersion.isNewer(current: curVer, latest: rawTag)
                let asset = (dto.assets ?? []).first {
                    ($0.name ?? "").lowercased().hasSuffix(".ipa") && ($0.browser_download_url?.isEmpty == false)
                }

                let info = MobileReleaseInfo(
                    hasUpdate: newer,
                    currentVersion: curVer,
                    latestVersion: latestClean,
                    tagName: rawTag.hasPrefix("v") ? rawTag : "v\(rawTag)",
                    title: (dto.name?.isEmpty == false ? dto.name! : "OpenUU \(rawTag)"),
                    releaseNotes: (dto.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    publishedAt: dto.published_at ?? "",
                    htmlURL: (dto.html_url?.isEmpty == false ? dto.html_url! : Self.githubReleasesPage),
                    assetName: asset?.name ?? "",
                    downloadURL: asset?.browser_download_url ?? "",
                    assetSizeBytes: asset?.size ?? 0
                )

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: PrefKey.lastCheckEpoch)
                self.releaseInfo = info

                if info.hasUpdate {
                    statusSummary = "发现新版本 \(info.tagName)"
                    onLog?("发现新版本 \(info.tagName)")
                    let skipped = UserDefaults.standard.string(forKey: PrefKey.skippedVersion) ?? ""
                    if manual || skipped != info.latestVersion {
                        showingUpdateSheet = true
                    }
                } else {
                    statusSummary = "已是最新 (\(MobileAppVersion.display))"
                    if manual {
                        showingUpdateSheet = true
                    }
                }
                return
            } catch {
                lastError = error.localizedDescription
            }
        }

        if manual {
            statusSummary = "检查失败：\(lastError)"
        }
    }

    func triggerOneClickDownloadIPA() {
        let target = (releaseInfo?.downloadURL.isEmpty == false)
            ? releaseInfo!.downloadURL
            : (releaseInfo?.htmlURL ?? Self.githubReleasesPage)
        if let url = URL(string: target) {
            UIApplication.shared.open(url)
        }
    }

    func triggerSideStoreInstall() {
        guard let dl = releaseInfo?.downloadURL, !dl.isEmpty,
              let encoded = dl.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let sideURL = URL(string: "sidestore://install?url=\(encoded)") else {
            triggerOneClickDownloadIPA()
            return
        }
        UIApplication.shared.open(sideURL) { ok in
            if !ok {
                self.triggerOneClickDownloadIPA()
            }
        }
    }
}

struct MobileUpdateSheet: View {
    @ObservedObject var updater: MobileAppUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = updater.releaseInfo
        let hasUpdate = info?.hasUpdate == true

        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    if UIImage(named: "BrandIcon") != nil {
                        Image("BrandIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    } else {
                        Image(systemName: "arrow.down.app.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(OpenUUTheme.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasUpdate ? "发现新版本 \(info?.tagName ?? "")" : "当前已是最新版本")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(OpenUUTheme.textPrimary)

                        let meta = [
                            "当前 \(MobileAppVersion.display)",
                            info?.formattedDate.isEmpty == false ? info!.formattedDate : nil,
                            info?.formattedSize.isEmpty == false ? info!.formattedSize : nil,
                        ].compactMap { $0 }.joined(separator: " · ")
                        Text(meta)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    }
                    Spacer()
                }

                Text("更新内容说明")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(OpenUUTheme.textSecondary)

                ScrollView {
                    Text(
                        (info?.releaseNotes.isEmpty == false)
                            ? info!.releaseNotes
                            : "暂无详细更新说明，可前往 GitHub Releases 查看完整变更记录。"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(OpenUUTheme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                .background(OpenUUTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                )

                if hasUpdate {
                    VStack(spacing: 9) {
                        Button {
                            updater.triggerOneClickDownloadIPA()
                        } label: {
                            Label("一键下载更新包 (.ipa)", systemImage: "arrow.down.circle.fill")
                                .font(.system(size: 14.5, weight: .semibold))
                                .foregroundStyle(OpenUUTheme.background)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(OpenUUTheme.primaryCTA, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)

                        HStack(spacing: 10) {
                            Button {
                                updater.triggerSideStoreInstall()
                            } label: {
                                Text("SideStore 一键安装")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OpenUUTheme.textPrimary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)

                            Button {
                                updater.skipCurrentAvailableVersion()
                            } label: {
                                Text("忽略此版本")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(OpenUUTheme.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .background(OpenUUTheme.elevated, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            .stroke(OpenUUTheme.hairline, lineWidth: 0.5)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Button {
                        Task { await updater.checkForUpdates(manual: true) }
                    } label: {
                        Text(updater.isChecking ? "正在检查..." : "重新检查更新")
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(OpenUUTheme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(OpenUUTheme.primaryCTA, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(updater.isChecking)
                }
            }
            .padding(18)
            .background(OpenUUTheme.background.ignoresSafeArea())
            .navigationTitle("版本更新")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let url = URL(string: info?.htmlURL ?? MobileAppUpdater.githubReleasesPage) {
                        Link("GitHub", destination: url)
                            .font(.subheadline)
                            .foregroundStyle(OpenUUTheme.textSecondary)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                        .foregroundStyle(OpenUUTheme.textPrimary)
                }
            }
        }
    }
}

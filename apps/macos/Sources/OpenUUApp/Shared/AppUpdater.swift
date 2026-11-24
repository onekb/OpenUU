import AppKit
import CryptoKit
import Foundation
import SwiftUI

enum AppVersion {
    static let fallback = "0.7.1"

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
        if let dashIdx = clean.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            clean = String(clean[..<dashIdx])
        }
        let parts = clean.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let minor = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        let patch = parts.count > 2 ? (Int(parts[2]) ?? 0) : 0
        return (major, minor, patch)
    }

    static func isNewer(current: String, latest: String) -> Bool {
        guard let c = parseSemVer(current), let l = parseSemVer(latest) else { return false }
        if l.0 != c.0 { return l.0 > c.0 }
        if l.1 != c.1 { return l.1 > c.1 }
        return l.2 > c.2
    }
}

enum UpdateCheckPolicy: String, CaseIterable, Identifiable {
    case launchAndDaily = "launch_and_daily"
    case dailyOnly = "daily"
    case manualOnly = "manual"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchAndDaily: return "打开时与每天自动检查（推荐）"
        case .dailyOnly: return "每天自动检查一次"
        case .manualOnly: return "仅手动检查"
        }
    }
}

struct ReleaseUpdateInfo: Equatable {
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
    let assetSha256: String

    var formattedSize: String {
        guard assetSizeBytes > 0 else { return "" }
        let mb = Double(assetSizeBytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb)
    }

    var formattedDate: String {
        guard !publishedAt.isEmpty else { return "" }
        return String(publishedAt.prefix(10))
    }
}

enum UpdateInstallPhase: Equatable {
    case idle
    case downloading(downloadedBytes: Int64, totalBytes: Int64)
    case installing(String)
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .downloading, .installing: return true
        case .idle, .failed: return false
        }
    }
}

private struct GithubReleaseDTO: Decodable {
    let tag_name: String?
    let name: String?
    let body: String?
    let html_url: String?
    let published_at: String?
    let draft: Bool?
    let assets: [GithubAssetDTO]?
}

private struct GithubAssetDTO: Decodable {
    let name: String?
    let size: Int64?
    let browser_download_url: String?
    let digest: String?
}

@MainActor
final class AppUpdater: NSObject, ObservableObject {
    static let githubLatestAPI = "https://api.github.com/repos/onekb/OpenUU/releases/latest"
    static let githubReleasesPage = "https://github.com/onekb/OpenUU/releases/latest"

    private enum PrefKey {
        static let checkPolicy = "openuu.updater.policy"
        static let lastCheckEpoch = "openuu.updater.lastCheckEpoch"
        static let skippedVersion = "openuu.updater.skippedVersion"
    }

    @Published var policy: UpdateCheckPolicy = UpdateCheckPolicy(
        rawValue: UserDefaults.standard.string(forKey: PrefKey.checkPolicy) ?? ""
    ) ?? .launchAndDaily {
        didSet {
            UserDefaults.standard.set(policy.rawValue, forKey: PrefKey.checkPolicy)
        }
    }

    @Published var isChecking: Bool = false
    @Published var releaseInfo: ReleaseUpdateInfo?
    @Published var statusSummary: String = "尚未检查更新"
    @Published var showingUpdateSheet: Bool = false
    @Published var installPhase: UpdateInstallPhase = .idle

    var coordURLProvider: (() -> String)?
    var onLog: ((String) -> Void)?

    private var dailyTimer: Timer?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?

    var hasAvailableUpdate: Bool {
        releaseInfo?.hasUpdate == true
    }

    override init() {
        super.init()
        refreshLastCheckLabel()
    }

    func startScheduledChecks() {
        dailyTimer?.invalidate()
        // Check every 6 hours whether >= 24h has elapsed since last check
        dailyTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runScheduledCheckIfDue(isLaunch: false)
            }
        }

        // Slight 2.2s delay after launch so UI renders instantaneously first
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(2200))
            self?.runScheduledCheckIfDue(isLaunch: true)
        }
    }

    private func runScheduledCheckIfDue(isLaunch: Bool) {
        switch policy {
        case .manualOnly:
            return
        case .launchAndDaily:
            if isLaunch || isDailyCheckDue() {
                Task { await checkForUpdates(manual: false) }
            }
        case .dailyOnly:
            if isDailyCheckDue() {
                Task { await checkForUpdates(manual: false) }
            }
        }
    }

    private func isDailyCheckDue() -> Bool {
        let last = UserDefaults.standard.double(forKey: PrefKey.lastCheckEpoch)
        if last <= 0 { return true }
        return (Date().timeIntervalSince1970 - last) >= 24 * 3600
    }

    private func refreshLastCheckLabel() {
        let last = UserDefaults.standard.double(forKey: PrefKey.lastCheckEpoch)
        guard last > 0 else {
            statusSummary = "当前版本 \(AppVersion.display)"
            return
        }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        statusSummary = "上次检查：\(fmt.string(from: Date(timeIntervalSince1970: last)))"
    }

    func skipCurrentAvailableVersion() {
        guard let latest = releaseInfo?.latestVersion, !latest.isEmpty else { return }
        UserDefaults.standard.set(latest, forKey: PrefKey.skippedVersion)
        showingUpdateSheet = false
        onLog?("[更新] 已忽略版本 v\(latest)")
    }

    func checkForUpdates(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        if manual {
            installPhase = .idle
            statusSummary = "正在检查新版本..."
        }
        defer { isChecking = false }

        let coordBase = (coordURLProvider?() ?? "https://openuu.1kb.ren")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var candidateURLs: [String] = []
        if !coordBase.isEmpty {
            candidateURLs.append("\(coordBase)/v1/latest-release")
        }
        candidateURLs.append(Self.githubLatestAPI)

        var lastError = "无法连接更新服务器"
        for urlStr in candidateURLs {
            guard let url = URL(string: urlStr) else { continue }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 6.5)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("OpenUU-macOS/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    lastError = "服务器返回异常状态"
                    continue
                }
                let dto = try JSONDecoder().decode(GithubReleaseDTO.self, from: data)
                if dto.draft == true { continue }
                guard let rawTag = dto.tag_name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawTag.isEmpty else {
                    continue
                }

                let curVer = AppVersion.current
                let latestClean = rawTag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let newer = AppVersion.isNewer(current: curVer, latest: rawTag)
                let asset = Self.pickMacOSAsset(dto.assets ?? [])
                let sha = (asset?.digest ?? "")
                    .replacingOccurrences(of: "sha256:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()

                let info = ReleaseUpdateInfo(
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
                    assetSizeBytes: asset?.size ?? 0,
                    assetSha256: sha
                )

                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: PrefKey.lastCheckEpoch)
                self.releaseInfo = info

                if info.hasUpdate {
                    statusSummary = "发现新版本 \(info.tagName)（当前 \(AppVersion.display)）"
                    onLog?("[更新] 发现新版本 \(info.tagName)")
                    let skipped = UserDefaults.standard.string(forKey: PrefKey.skippedVersion) ?? ""
                    if manual || skipped != info.latestVersion {
                        showingUpdateSheet = true
                    }
                } else {
                    statusSummary = "当前已是最新版本 (\(AppVersion.display))"
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
            statusSummary = "检查更新失败：\(lastError)"
            onLog?("[更新] 检查更新失败: \(lastError)")
        }
    }

    private static func pickMacOSAsset(_ assets: [GithubAssetDTO]) -> GithubAssetDTO? {
        #if arch(arm64)
        let preferredArch = "arm64"
        #else
        let preferredArch = "x86_64"
        #endif

        let valid = assets.filter { ($0.name?.isEmpty == false) && ($0.browser_download_url?.isEmpty == false) }
        if let exact = valid.first(where: {
            let n = ($0.name ?? "").lowercased()
            return n.hasSuffix(".dmg") && n.contains(preferredArch)
        }) {
            return exact
        }
        return valid.first(where: { ($0.name ?? "").lowercased().hasSuffix(".dmg") })
    }

    func openReleaseInBrowser() {
        let target = releaseInfo?.downloadURL.isEmpty == false
            ? releaseInfo!.downloadURL
            : (releaseInfo?.htmlURL ?? Self.githubReleasesPage)
        if let url = URL(string: target) {
            NSWorkspace.shared.open(url)
        }
    }

    func cancelDownload() {
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        installPhase = .idle
    }

    func performOneClickUpdate() {
        guard let info = releaseInfo, !installPhase.isBusy else { return }
        guard !info.downloadURL.isEmpty, let dlURL = URL(string: info.downloadURL) else {
            openReleaseInBrowser()
            return
        }

        installPhase = .downloading(downloadedBytes: 0, totalBytes: info.assetSizeBytes)
        onLog?("[更新] 开始下载更新包: \(info.assetName)")

        Task { @MainActor in
            do {
                let dmgURL = try await downloadDMGWithProgress(from: dlURL, expectedSha256: info.assetSha256)
                installPhase = .installing("正在校验并静默挂载更新镜像...")
                try await applyDMGAndRelaunch(dmgURL: dmgURL, tagName: info.tagName)
            } catch is CancellationError {
                installPhase = .idle
            } catch {
                let msg = error.localizedDescription
                installPhase = .failed("自动更新失败：\(msg)。你可点击右侧「浏览器下载」手动覆盖安装。")
                onLog?("[更新] 自动更新异常: \(msg)")
            }
        }
    }

    private func downloadDMGWithProgress(from url: URL, expectedSha256: String) async throws -> URL {
        let tempDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenUU-Update-\(UUID().uuidString).dmg")

        let downloadedTemp: URL = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            self.downloadContinuation = cont
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 600
            let session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            var req = URLRequest(url: url)
            req.setValue("OpenUU-macOS/\(AppVersion.current)", forHTTPHeaderField: "User-Agent")
            let task = session.downloadTask(with: req)
            self.activeDownloadTask = task
            task.resume()
        }

        try? FileManager.default.removeItem(at: tempDest)
        try FileManager.default.moveItem(at: downloadedTemp, to: tempDest)

        if !expectedSha256.isEmpty {
            let fileData = try Data(contentsOf: tempDest, options: .mappedIfSafe)
            let digest = SHA256.hash(data: fileData).map { String(format: "%02x", $0) }.joined()
            if digest.lowercased() != expectedSha256.lowercased() {
                try? FileManager.default.removeItem(at: tempDest)
                throw NSError(
                    domain: "OpenUUUpdater",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "安装包 SHA-256 校验不一致，已中止替换"]
                )
            }
        }

        return tempDest
    }

    private func applyDMGAndRelaunch(dmgURL: URL, tagName: String) async throws {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("openuu-mnt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attachRes = try await Task.detached(priority: .userInitiated) { () -> (Int32, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint.path, dmgURL.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            try p.run()
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (p.terminationStatus, out)
        }.value

        guard attachRes.0 == 0 else {
            throw NSError(
                domain: "OpenUUUpdater",
                code: Int(attachRes.0),
                userInfo: [NSLocalizedDescriptionKey: "挂载 DMG 失败: \(attachRes.1)"]
            )
        }

        let items = (try? FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
        guard let mountedApp = items.first(where: { $0.pathExtension == "app" }) else {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/hdiutil"), arguments: ["detach", mountPoint.path, "-quiet"])
            throw NSError(
                domain: "OpenUUUpdater",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "镜像内未找到 OpenUU.app"]
            )
        }

        let currentBundle = Bundle.main.bundleURL
        let targetAppURL: URL
        if currentBundle.pathExtension == "app" {
            targetAppURL = currentBundle
        } else {
            targetAppURL = URL(fileURLWithPath: "/Applications/OpenUU.app")
        }

        let parentDir = targetAppURL.deletingLastPathComponent().path
        if !FileManager.default.isWritableFile(atPath: parentDir) {
            // Reveal mounted DMG in Finder if target directory requires elevated permissions
            installPhase = .installing("已挂载更新镜像，正在打开安装目录...")
            NSWorkspace.shared.open(mountPoint)
            installPhase = .idle
            return
        }

        installPhase = .installing("正在替换 OpenUU (\(tagName)) 并自动重启...")
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("openuu-apply-update-\(pid).sh")

        let escapedSrc = mountedApp.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDst = targetAppURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedMnt = mountPoint.path.replacingOccurrences(of: "'", with: "'\\''")
        let escapedDmg = dmgURL.path.replacingOccurrences(of: "'", with: "'\\''")

        let script = """
        #!/bin/sh
        for _ in $(seq 1 40); do
          if ! kill -0 \(pid) 2>/dev/null; then
            break
          fi
          sleep 0.2
        done
        rm -rf '\(escapedDst)'
        /usr/bin/ditto '\(escapedSrc)' '\(escapedDst)'
        /usr/bin/xattr -cr '\(escapedDst)' >/dev/null 2>&1 || true
        /usr/bin/hdiutil detach '\(escapedMnt)' -quiet >/dev/null 2>&1 || true
        rm -rf '\(escapedMnt)' '\(escapedDmg)' "$0"
        /usr/bin/open '\(escapedDst)'
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
        launcher.arguments = [scriptURL.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        try launcher.run()

        try? await Task.sleep(for: .milliseconds(250))
        NSApp.terminate(nil)
    }
}

extension AppUpdater: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let total = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : (self.releaseInfo?.assetSizeBytes ?? 0)
            self.installPhase = .downloading(downloadedBytes: totalBytesWritten, totalBytes: total)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Must copy/move synchronously before URLSession deletes temporary `location`
        let safeCopy = FileManager.default.temporaryDirectory
            .appendingPathComponent("openuu-dl-\(UUID().uuidString).tmp")
        do {
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NSError(
                    domain: "OpenUUUpdater",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "下载返回 HTTP \(http.statusCode)"]
                )
            }
            try FileManager.default.moveItem(at: location, to: safeCopy)
            Task { @MainActor [weak self] in
                self?.activeDownloadTask = nil
                self?.downloadContinuation?.resume(returning: safeCopy)
                self?.downloadContinuation = nil
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.activeDownloadTask = nil
                self?.downloadContinuation?.resume(throwing: error)
                self?.downloadContinuation = nil
            }
        }
        session.finishTasksAndInvalidate()
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeDownloadTask = nil
                if (error as NSError).code == NSURLErrorCancelled {
                    self.downloadContinuation?.resume(throwing: CancellationError())
                } else {
                    self.downloadContinuation?.resume(throwing: error)
                }
                self.downloadContinuation = nil
            }
            session.finishTasksAndInvalidate()
        }
    }
}

// ============================================================================
// Software Update & Release Notes Sheet (macOS)
// ============================================================================

struct SoftwareUpdateSheet: View {
    @ObservedObject var updater: AppUpdater
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let info = updater.releaseInfo
        let hasUpdate = info?.hasUpdate == true

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: IconCompositor.brandSquircleIcon)
                    .resizable()
                    .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(hasUpdate ? "发现新版本 \(info?.tagName ?? "")" : "当前已是最新版本")
                            .font(.system(size: 16.5, weight: .bold))
                        Text("当前 \(AppVersion.display)")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(Capsule())
                    }

                    if let info {
                        let meta = [
                            !info.formattedDate.isEmpty ? "发布日期：\(info.formattedDate)" : nil,
                            !info.formattedSize.isEmpty ? "安装包：\(info.formattedSize)" : nil,
                        ].compactMap { $0 }.joined(separator: "  ·  ")
                        if !meta.isEmpty {
                            Text(meta)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("更新内容 (\(info?.tagName ?? AppVersion.display))")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    MarkdownReleaseNotesView(
                        markdown: (info?.releaseNotes.isEmpty == false)
                            ? info!.releaseNotes
                            : "暂无详细更新说明，可前往 GitHub Releases 页面查看完整提交记录。"
                    )
                    .padding(14)
                }
                .frame(height: 300)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.09), lineWidth: 1)
                )
            }

            switch updater.installPhase {
            case .idle:
                EmptyView()
            case .downloading(let done, let total):
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        ProgressView().controlSize(.small)
                        let doneMB = Double(done) / 1_048_576.0
                        if total > 0 {
                            let totalMB = Double(total) / 1_048_576.0
                            let pct = min(100, Int(Double(done) * 100.0 / Double(total)))
                            Text(String(format: "正在下载更新包：%.1f / %.1f MB (%d%%)", doneMB, totalMB, pct))
                                .font(.system(size: 12, design: .monospaced))
                        } else {
                            Text(String(format: "正在下载更新包：%.1f MB...", doneMB))
                                .font(.system(size: 12, design: .monospaced))
                        }
                        Spacer()
                        Button("取消下载") {
                            updater.cancelDownload()
                        }
                        .controlSize(.mini)
                    }
                    if total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                    }
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            case .installing(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            case .failed(let err):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            HStack(spacing: 10) {
                if hasUpdate {
                    Button("忽略此版本") {
                        updater.skipCurrentAvailableVersion()
                    }
                    .disabled(updater.installPhase.isBusy)
                }

                Button("前往 GitHub Releases") {
                    if let url = URL(string: info?.htmlURL ?? AppUpdater.githubReleasesPage) {
                        NSWorkspace.shared.open(url)
                    }
                }

                Spacer()

                Button(hasUpdate ? "稍后" : "关闭") {
                    dismiss()
                }
                .disabled(updater.installPhase.isBusy)

                if hasUpdate {
                    Button("浏览器下载") {
                        updater.openReleaseInBrowser()
                    }
                    .disabled(updater.installPhase.isBusy)

                    Button {
                        updater.performOneClickUpdate()
                    } label: {
                        Label("一键下载并重启更新", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.installPhase.isBusy)
                } else {
                    Button {
                        Task { await updater.checkForUpdates(manual: true) }
                    } label: {
                        Label(updater.isChecking ? "正在检查..." : "重新检查", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isChecking)
                }
            }
        }
        .padding(22)
        .frame(width: 580)
    }
}

// ============================================================================
// Structured GitHub-Flavored Markdown Renderer for Release Notes (macOS)
// ============================================================================

private enum MarkdownBlockNode: Identifiable {
    case heading(id: Int, level: Int, text: String)
    case divider(id: Int)
    case codeBlock(id: Int, language: String, code: String)
    case blockquote(id: Int, text: String)
    case table(id: Int, headers: [String], rows: [[String]])
    case listItem(id: Int, level: Int, marker: String, text: String)
    case paragraph(id: Int, text: String)

    var id: Int {
        switch self {
        case .heading(let id, _, _),
             .divider(let id),
             .codeBlock(let id, _, _),
             .blockquote(let id, _),
             .table(let id, _, _),
             .listItem(let id, _, _, _),
             .paragraph(let id, _):
            return id
        }
    }
}

struct MarkdownReleaseNotesView: View {
    let markdown: String

    var body: some View {
        let blocks = Self.parseBlocks(markdown)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks) { block in
                switch block {
                case .heading(_, let level, let text):
                    VStack(alignment: .leading, spacing: 4) {
                        Self.inlineText(
                            text,
                            baseFont: .system(
                                size: level == 1 ? 16 : (level == 2 ? 14.5 : (level == 3 ? 13.5 : 12.8)),
                                weight: .bold
                            )
                        )
                        .foregroundStyle(.primary)
                        if level <= 2 {
                            Divider().opacity(0.55)
                        }
                    }
                    .padding(.top, level <= 2 ? 4 : 2)

                case .divider:
                    Divider()
                        .padding(.vertical, 3)

                case .codeBlock(_, let lang, let code):
                    MarkdownCodeBlockCard(language: lang, code: code)

                case .blockquote(_, let text):
                    HStack(alignment: .top, spacing: 9) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.8))
                            .frame(width: 3)
                        Self.inlineText(text, baseFont: .system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                case .table(_, let headers, let rows):
                    MarkdownTableView(headers: headers, rows: rows)

                case .listItem(_, let level, let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker)
                            .font(.system(size: 12, weight: .semibold, design: marker.hasSuffix(".") ? .monospaced : .default))
                            .foregroundStyle(.secondary)
                            .frame(minWidth: marker.hasSuffix(".") ? 18 : 10, alignment: .trailing)
                        Self.inlineText(text, baseFont: .system(size: 12.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, CGFloat(level) * 15)

                case .paragraph(_, let text):
                    Self.inlineText(text, baseFont: .system(size: 12.5))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    fileprivate static func inlineText(_ raw: String, baseFont: Font) -> Text {
        if var attr = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            for run in attr.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attr[run.range].font = .system(size: 11.5, weight: .medium, design: .monospaced)
                    attr[run.range].backgroundColor = Color.primary.opacity(0.08)
                }
            }
            return Text(attr).font(baseFont)
        }
        return Text(raw).font(baseFont)
    }

    private static func parseBlocks(_ source: String) -> [MarkdownBlockNode] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var out: [MarkdownBlockNode] = []
        var nextID = 1
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            // 1. Fenced code block ```
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(cl)
                    i += 1
                }
                out.append(.codeBlock(id: nextID, language: lang, code: codeLines.joined(separator: "\n")))
                nextID += 1
                continue
            }

            // 2. Horizontal rule --- / *** / ___
            if (trimmed.hasPrefix("---") || trimmed.hasPrefix("***") || trimmed.hasPrefix("___")),
               trimmed.allSatisfy({ $0 == "-" || $0 == "*" || $0 == "_" || $0 == " " }),
               trimmed.filter({ $0 != " " }).count >= 3 {
                out.append(.divider(id: nextID))
                nextID += 1
                i += 1
                continue
            }

            // 3. Heading # .. ####
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let rest = trimmed.dropFirst(hashes.count)
                if hashes.count <= 6, rest.first == " " {
                    out.append(.heading(
                        id: nextID,
                        level: min(4, hashes.count),
                        text: rest.trimmingCharacters(in: .whitespaces)
                    ))
                    nextID += 1
                    i += 1
                    continue
                }
            }

            // 4. Markdown Table | ... |
            if trimmed.hasPrefix("|"), i + 1 < lines.count {
                let sepTrim = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if sepTrim.hasPrefix("|") && sepTrim.contains("-") &&
                   sepTrim.allSatisfy({ "|:- \t".contains($0) }) {
                    let headers = parseTableRow(trimmed)
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let rl = lines[i].trimmingCharacters(in: .whitespaces)
                        guard rl.hasPrefix("|") else { break }
                        rows.append(parseTableRow(rl))
                        i += 1
                    }
                    if !headers.isEmpty {
                        out.append(.table(id: nextID, headers: headers, rows: rows))
                        nextID += 1
                        continue
                    }
                }
            }

            // 5. Blockquote > ...
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count {
                    let ql = lines[i].trimmingCharacters(in: .whitespaces)
                    guard ql.hasPrefix(">") else { break }
                    let body = ql.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty {
                        quoteLines.append(body)
                    }
                    i += 1
                }
                if !quoteLines.isEmpty {
                    out.append(.blockquote(id: nextID, text: quoteLines.joined(separator: "\n")))
                    nextID += 1
                }
                continue
            }

            // 6. Unordered / Ordered List Item
            if let listMatch = parseListLine(line) {
                out.append(.listItem(
                    id: nextID,
                    level: listMatch.level,
                    marker: listMatch.marker,
                    text: listMatch.text
                ))
                nextID += 1
                i += 1
                continue
            }

            // 7. Paragraph (coalesce consecutive plain lines)
            var paraLines: [String] = [trimmed]
            i += 1
            while i < lines.count {
                let nl = lines[i]
                let nt = nl.trimmingCharacters(in: .whitespaces)
                if nt.isEmpty || nt.hasPrefix("#") || nt.hasPrefix("```") ||
                   nt.hasPrefix(">") || nt.hasPrefix("|") || nt.hasPrefix("---") ||
                   parseListLine(nl) != nil {
                    break
                }
                paraLines.append(nt)
                i += 1
            }
            out.append(.paragraph(id: nextID, text: paraLines.joined(separator: " ")))
            nextID += 1
        }

        return out
    }

    private static func parseTableRow(_ row: String) -> [String] {
        var s = row.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseListLine(_ rawLine: String) -> (level: Int, marker: String, text: String)? {
        var leadingSpaces = 0
        for ch in rawLine {
            if ch == " " { leadingSpaces += 1 }
            else if ch == "\t" { leadingSpaces += 2 }
            else { break }
        }
        let level = min(3, leadingSpaces / 2)
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) {
                let bullet = level == 0 ? "•" : (level == 1 ? "◦" : "▪")
                return (level, bullet, String(trimmed.dropFirst(prefix.count)))
            }
        }

        let digits = trimmed.prefix(while: \.isNumber)
        if !digits.isEmpty {
            let afterDigits = trimmed.dropFirst(digits.count)
            if afterDigits.hasPrefix(". ") {
                return (level, "\(digits).", String(afterDigits.dropFirst(2)))
            }
        }
        return nil
    }
}

private struct MarkdownCodeBlockCard: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(language.isEmpty ? "命令 / 代码" : language)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(code, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1400))
                        copied = false
                    }
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .buttonStyle(.borderless)
            }

            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.primary.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
        )
    }
}

private struct MarkdownTableView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(headers.indices, id: \.self) { col in
                    MarkdownReleaseNotesView.inlineText(headers[col], baseFont: .system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.065))

            ForEach(rows.indices, id: \.self) { rIdx in
                Divider().opacity(0.5)
                let row = rows[rIdx]
                HStack(alignment: .top, spacing: 8) {
                    ForEach(headers.indices, id: \.self) { col in
                        let cell = col < row.count ? row[col] : ""
                        MarkdownReleaseNotesView.inlineText(cell, baseFont: .system(size: 11.5))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(rIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.025))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.11), lineWidth: 0.8)
        )
    }
}

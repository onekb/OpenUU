using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Windows.Threading;

namespace OpenUU.Shared;

public static class AppVersion
{
    public const string Fallback = "0.7.3";

    public static string Current
    {
        get
        {
            var v = typeof(AppVersion).Assembly.GetName().Version;
            if (v != null && (v.Major > 0 || v.Minor > 0 || v.Build > 0))
                return $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
            return Fallback;
        }
    }

    public static string Display => $"v{Current}";

    public static (int Major, int Minor, int Patch)? ParseSemVer(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        string clean = raw.Trim().TrimStart('v', 'V');
        int suffixIdx = clean.IndexOfAny(new[] { '-', '+' });
        if (suffixIdx >= 0) clean = clean[..suffixIdx];
        var parts = clean.Split('.');
        if (parts.Length == 0 || !int.TryParse(parts[0], out int maj)) return null;
        int min = parts.Length > 1 && int.TryParse(parts[1], out int m) ? m : 0;
        int pat = parts.Length > 2 && int.TryParse(parts[2], out int p) ? p : 0;
        return (maj, min, pat);
    }

    public static bool IsNewer(string current, string latest)
    {
        var c = ParseSemVer(current);
        var l = ParseSemVer(latest);
        if (c == null || l == null) return false;
        if (l.Value.Major != c.Value.Major) return l.Value.Major > c.Value.Major;
        if (l.Value.Minor != c.Value.Minor) return l.Value.Minor > c.Value.Minor;
        return l.Value.Patch > c.Value.Patch;
    }
}

public enum UpdateCheckPolicy
{
    LaunchAndDaily = 0,
    DailyOnly = 1,
    ManualOnly = 2
}

public static class UpdateCheckPolicyExtensions
{
    public static string GetLabel(this UpdateCheckPolicy p) => p switch
    {
        UpdateCheckPolicy.LaunchAndDaily => "打开时与每天自动检查（推荐）",
        UpdateCheckPolicy.DailyOnly => "每天自动检查一次",
        UpdateCheckPolicy.ManualOnly => "仅手动检查",
        _ => "打开时与每天自动检查（推荐）"
    };

    public static string ToCode(this UpdateCheckPolicy p) => p switch
    {
        UpdateCheckPolicy.DailyOnly => "daily",
        UpdateCheckPolicy.ManualOnly => "manual",
        _ => "launch_and_daily"
    };

    public static UpdateCheckPolicy FromCode(string? raw) => (raw ?? "").Trim().ToLowerInvariant() switch
    {
        "daily" => UpdateCheckPolicy.DailyOnly,
        "manual" => UpdateCheckPolicy.ManualOnly,
        _ => UpdateCheckPolicy.LaunchAndDaily
    };
}

public sealed class ReleaseUpdateInfo
{
    public bool HasUpdate { get; init; }
    public string CurrentVersion { get; init; } = AppVersion.Current;
    public string LatestVersion { get; init; } = "";
    public string TagName { get; init; } = "";
    public string Title { get; init; } = "";
    public string ReleaseNotes { get; init; } = "";
    public string PublishedAt { get; init; } = "";
    public string HtmlUrl { get; init; } = AppUpdater.GithubReleasesPage;
    public string AssetName { get; init; } = "";
    public string DownloadUrl { get; init; } = "";
    public long AssetSizeBytes { get; init; }
    public string AssetSha256 { get; init; } = "";

    public string FormattedSize => AssetSizeBytes > 0
        ? $"{AssetSizeBytes / 1048576.0:F1} MB"
        : "";

    public string FormattedDate => PublishedAt.Length >= 10
        ? PublishedAt[..10]
        : PublishedAt;
}

internal sealed class GithubReleaseDto
{
    [JsonPropertyName("tag_name")]
    public string? TagName { get; set; }

    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("body")]
    public string? Body { get; set; }

    [JsonPropertyName("html_url")]
    public string? HtmlUrl { get; set; }

    [JsonPropertyName("published_at")]
    public string? PublishedAt { get; set; }

    [JsonPropertyName("draft")]
    public bool Draft { get; set; }

    [JsonPropertyName("assets")]
    public List<GithubAssetDto>? Assets { get; set; }
}

internal sealed class GithubAssetDto
{
    [JsonPropertyName("name")]
    public string? Name { get; set; }

    [JsonPropertyName("size")]
    public long Size { get; set; }

    [JsonPropertyName("browser_download_url")]
    public string? BrowserDownloadUrl { get; set; }

    [JsonPropertyName("digest")]
    public string? Digest { get; set; }
}

public sealed class AppUpdater : ObservableBase
{
    public const string GithubLatestApi = "https://api.github.com/repos/onekb/OpenUU/releases/latest";
    public const string GithubReleasesPage = "https://github.com/onekb/OpenUU/releases/latest";

    private static readonly HttpClient SharedHttp = new()
    {
        Timeout = TimeSpan.FromMinutes(10)
    };

    private UpdateCheckPolicy _policy = UpdateCheckPolicy.LaunchAndDaily;
    public UpdateCheckPolicy Policy
    {
        get => _policy;
        set
        {
            if (SetField(ref _policy, value))
                OnPrefsChanged?.Invoke();
        }
    }

    public long LastCheckEpochSeconds { get; set; }
    public string SkippedVersion { get; set; } = "";

    private bool _isChecking;
    public bool IsChecking
    {
        get => _isChecking;
        private set => SetField(ref _isChecking, value);
    }

    private ReleaseUpdateInfo? _releaseInfo;
    public ReleaseUpdateInfo? ReleaseInfo
    {
        get => _releaseInfo;
        private set
        {
            if (SetField(ref _releaseInfo, value))
                OnPropertyChanged(nameof(HasAvailableUpdate));
        }
    }

    public bool HasAvailableUpdate => ReleaseInfo?.HasUpdate == true;

    private string _statusSummary = $"当前版本 {AppVersion.Display}";
    public string StatusSummary
    {
        get => _statusSummary;
        private set => SetField(ref _statusSummary, value);
    }

    private bool _isInstalling;
    public bool IsInstalling
    {
        get => _isInstalling;
        private set => SetField(ref _isInstalling, value);
    }

    private double _downloadProgressPct;
    public double DownloadProgressPct
    {
        get => _downloadProgressPct;
        private set => SetField(ref _downloadProgressPct, value);
    }

    private string _installStatusText = "";
    public string InstallStatusText
    {
        get => _installStatusText;
        private set => SetField(ref _installStatusText, value);
    }

    private string _installErrorText = "";
    public string InstallErrorText
    {
        get => _installErrorText;
        private set => SetField(ref _installErrorText, value);
    }

    public Func<string>? CoordUrlProvider { get; set; }
    public Action? OnPrefsChanged { get; set; }
    public Action<string>? OnLog { get; set; }
    public Action<bool>? OnShowUpdateDialogRequested { get; set; }
    public Action? OnRequestShutdownForUpdate { get; set; }

    private DispatcherTimer? _dailyTimer;
    private CancellationTokenSource? _downloadCts;

    public void RefreshStatusFromPrefs()
    {
        if (LastCheckEpochSeconds > 0)
        {
            var dt = DateTimeOffset.FromUnixTimeSeconds(LastCheckEpochSeconds).ToLocalTime();
            StatusSummary = $"上次检查：{dt:MM-dd HH:mm}";
        }
        else
        {
            StatusSummary = $"当前版本 {AppVersion.Display}";
        }
    }

    public void StartScheduledChecks()
    {
        _dailyTimer?.Stop();
        _dailyTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromHours(6)
        };
        _dailyTimer.Tick += async (_, _) => await RunScheduledCheckIfDueAsync(isLaunch: false);
        _dailyTimer.Start();

        _ = Task.Run(async () =>
        {
            await Task.Delay(2200);
            System.Windows.Application.Current?.Dispatcher.InvokeAsync(async () =>
            {
                await RunScheduledCheckIfDueAsync(isLaunch: true);
            });
        });
    }

    private async Task RunScheduledCheckIfDueAsync(bool isLaunch)
    {
        switch (Policy)
        {
            case UpdateCheckPolicy.ManualOnly:
                return;
            case UpdateCheckPolicy.LaunchAndDaily:
                if (isLaunch || IsDailyCheckDue())
                    await CheckForUpdatesAsync(manual: false);
                break;
            case UpdateCheckPolicy.DailyOnly:
                if (IsDailyCheckDue())
                    await CheckForUpdatesAsync(manual: false);
                break;
        }
    }

    private bool IsDailyCheckDue()
    {
        if (LastCheckEpochSeconds <= 0) return true;
        long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        return (now - LastCheckEpochSeconds) >= 24 * 3600;
    }

    public void SkipCurrentAvailableVersion()
    {
        if (ReleaseInfo == null || string.IsNullOrEmpty(ReleaseInfo.LatestVersion)) return;
        SkippedVersion = ReleaseInfo.LatestVersion;
        OnPrefsChanged?.Invoke();
        OnLog?.Invoke($"[更新] 已忽略版本 v{SkippedVersion}");
    }

    public async Task CheckForUpdatesAsync(bool manual)
    {
        if (IsChecking) return;
        IsChecking = true;
        if (manual)
        {
            InstallErrorText = "";
            StatusSummary = "正在检查新版本...";
        }

        try
        {
            string coordBase = (CoordUrlProvider?.Invoke() ?? "https://openuu.1kb.ren").Trim().TrimEnd('/');
            var urls = new List<string>();
            if (!string.IsNullOrEmpty(coordBase))
                urls.Add($"{coordBase}/v1/latest-release");
            urls.Add(GithubLatestApi);

            string lastErr = "无法连接更新服务器";
            foreach (var url in urls)
            {
                try
                {
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(7));
                    using var req = new HttpRequestMessage(HttpMethod.Get, url);
                    req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
                    req.Headers.TryAddWithoutValidation("User-Agent", $"OpenUU-Windows/{AppVersion.Current}");

                    using var resp = await SharedHttp.SendAsync(req, HttpCompletionOption.ResponseContentRead, cts.Token);
                    if (!resp.IsSuccessStatusCode)
                    {
                        lastErr = $"HTTP {(int)resp.StatusCode}";
                        continue;
                    }

                    string json = await resp.Content.ReadAsStringAsync(cts.Token);
                    var dto = JsonSerializer.Deserialize<GithubReleaseDto>(json);
                    if (dto == null || dto.Draft || string.IsNullOrWhiteSpace(dto.TagName))
                        continue;

                    string rawTag = dto.TagName.Trim();
                    string curVer = AppVersion.Current;
                    string latestClean = rawTag.TrimStart('v', 'V');
                    bool newer = AppVersion.IsNewer(curVer, rawTag);

                    var asset = PickWindowsAsset(dto.Assets);
                    string sha = (asset?.Digest ?? "")
                        .Replace("sha256:", "", StringComparison.OrdinalIgnoreCase)
                        .Trim()
                        .ToLowerInvariant();

                    var info = new ReleaseUpdateInfo
                    {
                        HasUpdate = newer && asset != null,
                        CurrentVersion = curVer,
                        LatestVersion = latestClean,
                        TagName = rawTag.StartsWith('v') ? rawTag : $"v{rawTag}",
                        Title = !string.IsNullOrWhiteSpace(dto.Name) ? dto.Name! : $"OpenUU {rawTag}",
                        ReleaseNotes = (dto.Body ?? "").Trim(),
                        PublishedAt = dto.PublishedAt ?? "",
                        HtmlUrl = !string.IsNullOrWhiteSpace(dto.HtmlUrl) ? dto.HtmlUrl! : GithubReleasesPage,
                        AssetName = asset?.Name ?? "",
                        DownloadUrl = asset?.BrowserDownloadUrl ?? "",
                        AssetSizeBytes = asset?.Size ?? 0,
                        AssetSha256 = sha
                    };

                    LastCheckEpochSeconds = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                    OnPrefsChanged?.Invoke();
                    ReleaseInfo = info;

                    if (info.HasUpdate)
                    {
                        StatusSummary = $"发现新版本 {info.TagName}（当前 {AppVersion.Display}）";
                        OnLog?.Invoke($"[更新] 发现新版本 {info.TagName}");
                        if (manual || !string.Equals(SkippedVersion, info.LatestVersion, StringComparison.OrdinalIgnoreCase))
                            OnShowUpdateDialogRequested?.Invoke(manual);
                    }
                    else
                    {
                        StatusSummary = $"当前已是最新版本 ({AppVersion.Display})";
                        if (manual)
                            OnShowUpdateDialogRequested?.Invoke(true);
                    }
                    return;
                }
                catch (Exception ex)
                {
                    lastErr = ex.Message;
                }
            }

            if (manual)
            {
                StatusSummary = $"检查更新失败：{lastErr}";
                OnLog?.Invoke($"[更新] 检查更新失败: {lastErr}");
            }
        }
        finally
        {
            IsChecking = false;
        }
    }

    private static bool IsInnoSetupInstallation()
    {
        try
        {
            string baseDir = AppContext.BaseDirectory;
            return File.Exists(Path.Combine(baseDir, "unins000.exe")) ||
                   File.Exists(Path.Combine(baseDir, "unins001.exe"));
        }
        catch
        {
            return false;
        }
    }

    private static GithubAssetDto? PickWindowsAsset(List<GithubAssetDto>? assets)
    {
        if (assets == null) return null;
        var valid = assets.Where(a => !string.IsNullOrWhiteSpace(a.Name) && !string.IsNullOrWhiteSpace(a.BrowserDownloadUrl)).ToList();
        var setupExe = valid.FirstOrDefault(a =>
        {
            string n = a.Name!.ToLowerInvariant();
            return n.Contains("windows") && (n.EndsWith(".exe") || n.EndsWith(".msi"));
        });
        var portableZip = valid.FirstOrDefault(a =>
        {
            string n = a.Name!.ToLowerInvariant();
            return n.Contains("windows") && n.EndsWith(".zip");
        });
        return IsInnoSetupInstallation()
            ? (setupExe ?? portableZip)
            : (portableZip ?? setupExe);
    }

    public void OpenReleaseInBrowser()
    {
        string target = !string.IsNullOrWhiteSpace(ReleaseInfo?.DownloadUrl)
            ? ReleaseInfo!.DownloadUrl
            : (ReleaseInfo?.HtmlUrl ?? GithubReleasesPage);
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }
        catch
        {
        }
    }

    public void CancelDownload()
    {
        _downloadCts?.Cancel();
        _downloadCts = null;
        IsInstalling = false;
        InstallStatusText = "";
    }

    public async Task PerformOneClickUpdateAsync()
    {
        var info = ReleaseInfo;
        if (info == null || IsInstalling) return;
        if (string.IsNullOrWhiteSpace(info.DownloadUrl))
        {
            OpenReleaseInBrowser();
            return;
        }

        IsInstalling = true;
        InstallErrorText = "";
        DownloadProgressPct = 0;
        InstallStatusText = "正在连接下载节点...";
        _downloadCts = new CancellationTokenSource();
        var ct = _downloadCts.Token;

        string workDir = Path.Combine(Path.GetTempPath(), $"OpenUU-Update-{Guid.NewGuid():N}");
        Directory.CreateDirectory(workDir);

        try
        {
            string ext = Path.GetExtension(info.AssetName);
            if (string.IsNullOrEmpty(ext)) ext = ".zip";
            string archivePath = Path.Combine(workDir, $"OpenUU-Update{ext}");

            using (var req = new HttpRequestMessage(HttpMethod.Get, info.DownloadUrl))
            {
                req.Headers.TryAddWithoutValidation("User-Agent", $"OpenUU-Windows/{AppVersion.Current}");
                using var resp = await SharedHttp.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
                resp.EnsureSuccessStatusCode();

                long total = resp.Content.Headers.ContentLength ?? info.AssetSizeBytes;
                await using var netStream = await resp.Content.ReadAsStreamAsync(ct);
                await using var fileStream = new FileStream(archivePath, FileMode.Create, FileAccess.Write, FileShare.None, 65536, useAsync: true);

                var buf = new byte[65536];
                long downloaded = 0;
                var lastUiTick = Stopwatch.StartNew();

                while (true)
                {
                    int n = await netStream.ReadAsync(buf.AsMemory(0, buf.Length), ct);
                    if (n <= 0) break;
                    await fileStream.WriteAsync(buf.AsMemory(0, n), ct);
                    downloaded += n;

                    if (lastUiTick.ElapsedMilliseconds >= 80 || (total > 0 && downloaded >= total))
                    {
                        lastUiTick.Restart();
                        double doneMb = downloaded / 1048576.0;
                        if (total > 0)
                        {
                            double totMb = total / 1048576.0;
                            double pct = Math.Min(100.0, downloaded * 100.0 / total);
                            DownloadProgressPct = pct;
                            InstallStatusText = $"正在下载更新包：{doneMb:F1} / {totMb:F1} MB ({pct:F0}%)";
                        }
                        else
                        {
                            InstallStatusText = $"正在下载更新包：{doneMb:F1} MB...";
                        }
                    }
                }
            }

            if (!string.IsNullOrEmpty(info.AssetSha256))
            {
                InstallStatusText = "正在校验安装包完整性 (SHA-256)...";
                await using var verifyStream = File.OpenRead(archivePath);
                byte[] hashBytes = await SHA256.HashDataAsync(verifyStream, ct);
                string hex = Convert.ToHexString(hashBytes).ToLowerInvariant();
                if (!string.Equals(hex, info.AssetSha256, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("安装包 SHA-256 校验不一致，已中止覆盖更新。");
            }

            string targetDir = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            string targetExe = Path.Combine(targetDir, "OpenUU.exe");
            int currentPid = Environment.ProcessId;

            if (!archivePath.EndsWith(".zip", StringComparison.OrdinalIgnoreCase))
            {
                InstallStatusText = $"正在静默升级新版本 ({info.TagName}) 并自动重启...";
                string setupCmdPath = Path.Combine(Path.GetTempPath(), $"openuu-setup-update-{currentPid}.cmd");
                var setupScript = new StringBuilder();
                setupScript.AppendLine("@echo off");
                setupScript.AppendLine("chcp 65001 >nul");
                setupScript.AppendLine("for /L %%i in (1,1,40) do (");
                setupScript.AppendLine($"  tasklist /FI \"PID eq {currentPid}\" 2>nul | find \"{currentPid}\" >nul");
                setupScript.AppendLine("  if errorlevel 1 goto run_setup");
                setupScript.AppendLine("  timeout /t 1 /nobreak >nul");
                setupScript.AppendLine(")");
                setupScript.AppendLine(":run_setup");
                setupScript.AppendLine($"start \"\" /WAIT \"{archivePath}\" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS");
                setupScript.AppendLine($"if exist \"{targetExe}\" start \"\" \"{targetExe}\"");
                setupScript.AppendLine($"rmdir /S /Q \"{workDir}\" 2>nul");
                setupScript.AppendLine("del \"%~f0\" 2>nul");
                await File.WriteAllTextAsync(setupCmdPath, setupScript.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), ct);

                Process.Start(new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/C \"\"{setupCmdPath}\"\"",
                    CreateNoWindow = true,
                    UseShellExecute = false,
                    WindowStyle = ProcessWindowStyle.Hidden
                });
                await Task.Delay(200, ct);
                OnRequestShutdownForUpdate?.Invoke();
                return;
            }

            InstallStatusText = "正在解压新版本文件...";
            string extractDir = Path.Combine(workDir, "extracted");
            await Task.Run(() => ZipFile.ExtractToDirectory(archivePath, extractDir, overwriteFiles: true), ct);

            // Unwrap single nested folder if zip contains e.g. OpenUU-Windows/OpenUU.exe
            string payloadDir = extractDir;
            if (!File.Exists(Path.Combine(payloadDir, "OpenUU.exe")))
            {
                var subDirs = Directory.GetDirectories(extractDir);
                if (subDirs.Length == 1 && File.Exists(Path.Combine(subDirs[0], "OpenUU.exe")))
                    payloadDir = subDirs[0];
            }

            string cmdPath = Path.Combine(Path.GetTempPath(), $"openuu-apply-update-{currentPid}.cmd");
            var script = new StringBuilder();
            script.AppendLine("@echo off");
            script.AppendLine("chcp 65001 >nul");
            script.AppendLine("for /L %%i in (1,1,40) do (");
            script.AppendLine($"  tasklist /FI \"PID eq {currentPid}\" 2>nul | find \"{currentPid}\" >nul");
            script.AppendLine("  if errorlevel 1 goto do_copy");
            script.AppendLine("  timeout /t 1 /nobreak >nul");
            script.AppendLine(")");
            script.AppendLine(":do_copy");
            script.AppendLine($"xcopy /E /Y /I /Q \"{payloadDir}\\*\" \"{targetDir}\\\" >nul");
            script.AppendLine($"if exist \"{targetExe}\" start \"\" \"{targetExe}\"");
            script.AppendLine($"rmdir /S /Q \"{workDir}\" 2>nul");
            script.AppendLine("del \"%~f0\" 2>nul");

            await File.WriteAllTextAsync(cmdPath, script.ToString(), new UTF8Encoding(encoderShouldEmitUTF8Identifier: false), ct);

            InstallStatusText = $"正在替换新版本 ({info.TagName}) 并自动重启...";
            Process.Start(new ProcessStartInfo
            {
                FileName = "cmd.exe",
                Arguments = $"/C \"\"{cmdPath}\"\"",
                CreateNoWindow = true,
                UseShellExecute = false,
                WindowStyle = ProcessWindowStyle.Hidden
            });

            await Task.Delay(200, ct);
            OnRequestShutdownForUpdate?.Invoke();
        }
        catch (OperationCanceledException)
        {
            IsInstalling = false;
            InstallStatusText = "";
            try { Directory.Delete(workDir, recursive: true); } catch { }
        }
        catch (Exception ex)
        {
            IsInstalling = false;
            InstallStatusText = "";
            InstallErrorText = $"自动更新失败：{ex.Message}（可点击「浏览器下载」手动解压覆盖）";
            OnLog?.Invoke($"[更新] 自动更新异常: {ex.Message}");
            try { Directory.Delete(workDir, recursive: true); } catch { }
        }
    }
}

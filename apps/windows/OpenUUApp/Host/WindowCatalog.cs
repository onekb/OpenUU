using System.Diagnostics;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenUU.Host;

using OpenUU.Shared;

public sealed class ShareableWindowItem
{
    public IntPtr Hwnd { get; init; }
    public uint WindowId => unchecked((uint)Hwnd.ToInt64());
    public uint Pid { get; init; }
    public string AppId { get; init; } = "";
    public string AppName { get; init; } = "";
    public string Title { get; init; } = "";
    public string? ExePath { get; init; }
    public string? ExplicitIconPath { get; init; }
    public string? DiscoveredIconPath { get; init; }
    public bool IsGenericRuntime { get; init; }
    public bool IsPopup { get; init; }
    public Win32Interop.RECT PhysicalBounds { get; init; }
    public double DpiScale { get; init; } = 1.0;

    public float LogicalWidth => MathF.Max(1f, (float)(PhysicalBounds.Width / DpiScale));
    public float LogicalHeight => MathF.Max(1f, (float)(PhysicalBounds.Height / DpiScale));
    public float LogicalX => (float)(PhysicalBounds.Left / DpiScale);
    public float LogicalY => (float)(PhysicalBounds.Top / DpiScale);
}

public static partial class WindowCatalog
{
    public const string WeChatBundleId = "com.tencent.xinWeChat";

    private sealed record ResolvedAppMeta(
        string AppId,
        string AppName,
        string? ExePath,
        string? ExplicitIconPath,
        string? DiscoveredIconPath,
        bool IsGenericRuntime,
        bool AllowLiveTitleUpgrade
    );

    private static readonly HashSet<string> IgnoredClasses = new(StringComparer.OrdinalIgnoreCase)
    {
        "Progman",
        "WorkerW",
        "Shell_TrayWnd",
        "Shell_SecondaryTrayWnd",
        "Windows.UI.Core.CoreWindow",
        "ApplicationFrameWindow", // Handled via uncloaked check; empty shell frames skipped
        "MultitaskingViewFrame",
        "XamlExplorerHostIslandWindow",
        "ForegroundStaging",
        "tooltips_class32",
        "SysShadow",
        "SysDragImage",
        "IME",
        "MSCTFIME UI"
    };

    private static readonly HashSet<string> GenericRuntimeProcessNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "electron",
        "nw",
        "javaw",
        "java",
        "pythonw",
        "python",
        "autohotkey",
        "autohotkey64",
        "autohotkeyu64"
    };

    private static readonly HashSet<string> GenericFolderOrPackageNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "electron", "app", "desktop", "client", "frontend", "web", "ui", "gui",
        "src", "dist", "out", "build", "release", "debug", "main", "renderer",
        "packages", "apps", "bin", "resources", "node_modules"
    };

    private static readonly HashSet<string> StopAncestorDirNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "Users", "Documents", "Desktop", "Downloads", "Projects", "Project",
        "Workspace", "Workspaces", "Repos", "Repositories", "Code", "Source",
        "AppData", "Roaming", "Local", "Program Files", "Program Files (x86)",
        "npm", "pnpm", "yarn", "scoop"
    };

    private static readonly HashSet<string> IgnoredScanSubdirs = new(StringComparer.OrdinalIgnoreCase)
    {
        "node_modules", ".git", ".svn", ".hg", ".vscode", ".idea",
        "target", "bin", "obj", "coverage", ".next", ".turbo", "dist-electron"
    };

    private static readonly Dictionary<uint, ResolvedAppMeta> ProcessMetaCache = new();
    private static readonly object CacheLock = new();

    [GeneratedRegex(@"(?:^\s*[\(\[（【]\d{1,3}\+?[\)\]）】]\s*)|(?:\s*[\(\[（【]\d{1,3}\+?[\)\]）】]\s*$)", RegexOptions.Compiled)]
    private static partial Regex UnreadBadgeStripRegex();

    [GeneratedRegex(@"(?:""productName""|'productName'|\bproductName)\s*:\s*(?:""([^""\r\n]+)""|'([^'\r\n]+)')", RegexOptions.Compiled)]
    private static partial Regex QuotedProductNameRegex();

    [GeneratedRegex(@"^\s*productName\s*:\s*([^\r\n#""']+)", RegexOptions.Multiline | RegexOptions.Compiled)]
    private static partial Regex YamlProductNameRegex();

    private static readonly string[] ElectronBuilderConfigFiles =
    {
        "electron-builder.json",
        "electron-builder.yml",
        "electron-builder.yaml",
        "electron-builder.config.ts",
        "electron-builder.config.js",
        "electron-builder.config.mjs",
        "electron-builder.config.cjs"
    };

    public static List<ShareableWindowItem> FetchNormalWindows()
    {
        int myPid = Environment.ProcessId;
        var results = new List<ShareableWindowItem>();

        Win32Interop.EnumWindowsProc enumProc = (hwnd, _) =>
        {
            try
            {
                if (!Win32Interop.IsWindowVisible(hwnd))
                    return true;
                if (Win32Interop.IsWindowCloaked(hwnd))
                    return true;

                Win32Interop.GetWindowThreadProcessId(hwnd, out uint rawPid);
                if (rawPid == 0 || rawPid == (uint)myPid)
                    return true;

                uint style = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_STYLE);
                uint exStyle = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE);
                if ((style & Win32Interop.WS_CHILD) != 0)
                    return true;

                bool isToolWin = (exStyle & Win32Interop.WS_EX_TOOLWINDOW) != 0 &&
                                 (exStyle & Win32Interop.WS_EX_APPWINDOW) == 0;
                if (isToolWin)
                    return true;

                string className = Win32Interop.GetWindowClassName(hwnd);
                if (IgnoredClasses.Contains(className) && !string.Equals(className, "ApplicationFrameWindow", StringComparison.OrdinalIgnoreCase))
                    return true;

                uint pid = Win32Interop.ResolveEffectiveWindowPid(hwnd, rawPid, className);
                if (pid == 0 || pid == (uint)myPid)
                    return true;

                string title = Win32Interop.GetWindowTitle(hwnd).Replace("\0", "").Trim();
                if (string.IsNullOrEmpty(title))
                    return true;

                bool isMinimized = Win32Interop.IsIconic(hwnd);
                var bounds = Win32Interop.GetVisibleWindowBounds(hwnd);
                double scale = Win32Interop.GetDpiScale(hwnd);
                if (!isMinimized && (bounds.Width / scale < 120 || bounds.Height / scale < 90))
                    return true;
                if (isMinimized)
                {
                    bounds = new Win32Interop.RECT { Left = 120, Top = 120, Right = 1080, Bottom = 760 };
                }

                var meta = ResolveProcessMetadata(pid, hwnd, title);
                if (string.IsNullOrEmpty(meta.AppId))
                    return true;

                results.Add(new ShareableWindowItem
                {
                    Hwnd = hwnd,
                    Pid = pid,
                    AppId = meta.AppId,
                    AppName = meta.AppName,
                    Title = title,
                    ExePath = meta.ExePath,
                    ExplicitIconPath = meta.ExplicitIconPath,
                    DiscoveredIconPath = meta.DiscoveredIconPath,
                    IsGenericRuntime = meta.IsGenericRuntime,
                    IsPopup = false,
                    PhysicalBounds = bounds,
                    DpiScale = scale
                });
            }
            catch
            {
                // Never let a single malformed/protected window abort the entire EnumWindows scan
            }
            return true;
        };

        Win32Interop.EnumWindows(enumProc, IntPtr.Zero);
        GC.KeepAlive(enumProc);

        results.Sort((a, b) =>
        {
            bool aWeChat = a.AppId == WeChatBundleId;
            bool bWeChat = b.AppId == WeChatBundleId;
            if (aWeChat != bWeChat) return aWeChat ? -1 : 1;
            return string.Compare(a.AppName, b.AppName, StringComparison.OrdinalIgnoreCase);
        });

        return results;
    }

    /// <summary>
    /// Enumerates visible top-level normal windows AND floating popups/menus (<c>WS_POPUP</c>, context menus <c>#32768</c>,
    /// dropdowns, emoji panels) belonging to the specified shared <paramref name="sharedAppIds"/> or <paramref name="sharedPids"/>.
    /// Returned in Z-order (front-to-back as enumerated by <c>EnumWindows</c>).
    /// </summary>
    public static List<ShareableWindowItem> FetchTrackedWindows(
        ISet<string> sharedAppIds,
        ISet<uint> sharedPids
    )
    {
        int myPid = Environment.ProcessId;
        var results = new List<ShareableWindowItem>();

        Win32Interop.EnumWindowsProc enumProc = (hwnd, _) =>
        {
            try
            {
                if (!Win32Interop.IsWindowVisible(hwnd) || Win32Interop.IsIconic(hwnd))
                    return true;
                if (Win32Interop.IsWindowCloaked(hwnd))
                    return true;

                Win32Interop.GetWindowThreadProcessId(hwnd, out uint rawPid);
                if (rawPid == 0 || rawPid == (uint)myPid)
                    return true;

                string className = Win32Interop.GetWindowClassName(hwnd);
                if (string.Equals(className, "SysShadow", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(className, "SysDragImage", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(className, "IME", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(className, "MSCTFIME UI", StringComparison.OrdinalIgnoreCase))
                {
                    return true;
                }

                uint pid = Win32Interop.ResolveEffectiveWindowPid(hwnd, rawPid, className);
                if (pid == 0 || pid == (uint)myPid)
                    return true;

                string title = Win32Interop.GetWindowTitle(hwnd).Replace("\0", "").Trim();
                var meta = ResolveProcessMetadata(pid, hwnd, title);
                bool matchesApp = (!string.IsNullOrEmpty(meta.AppId) && sharedAppIds.Contains(meta.AppId)) ||
                                  sharedPids.Contains(pid) ||
                                  sharedPids.Contains(rawPid);
                if (!matchesApp)
                    return true;

                uint style = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_STYLE);
                uint exStyle = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE);
                if ((style & Win32Interop.WS_CHILD) != 0)
                    return true;

                var bounds = Win32Interop.GetVisibleWindowBounds(hwnd);
                double scale = Win32Interop.GetDpiScale(hwnd);
                double logW = bounds.Width / scale;
                double logH = bounds.Height / scale;

                bool isMenuOrPopup =
                    className == "#32768" ||
                    ((style & Win32Interop.WS_POPUP) != 0 &&
                     ((exStyle & (Win32Interop.WS_EX_TOOLWINDOW | Win32Interop.WS_EX_NOACTIVATE)) != 0 || string.IsNullOrEmpty(title)));

                if (isMenuOrPopup)
                {
                    // Match macOS MultiWindowCaptureManager.isCapturablePopoverFrame (>= 52x28, and >=68w or >=48h)
                    if (logW < 52 || logH < 28 || (logW < 68 && logH < 48))
                        return true;
                }
                else
                {
                    if (logW < 130 || logH < 100)
                        return true;
                    if (string.IsNullOrEmpty(title) && (exStyle & Win32Interop.WS_EX_TOOLWINDOW) != 0)
                        return true;
                }

                results.Add(new ShareableWindowItem
                {
                    Hwnd = hwnd,
                    Pid = pid,
                    AppId = meta.AppId,
                    AppName = meta.AppName,
                    Title = string.IsNullOrEmpty(title) ? (isMenuOrPopup ? "菜单" : meta.AppName) : title,
                    ExePath = meta.ExePath,
                    ExplicitIconPath = meta.ExplicitIconPath,
                    DiscoveredIconPath = meta.DiscoveredIconPath,
                    IsGenericRuntime = meta.IsGenericRuntime,
                    IsPopup = isMenuOrPopup,
                    PhysicalBounds = bounds,
                    DpiScale = scale
                });
            }
            catch
            {
            }
            return true;
        };

        Win32Interop.EnumWindows(enumProc, IntPtr.Zero);
        GC.KeepAlive(enumProc);

        return results;
    }

    public static List<RemoteAppSummary> BuildHostAppSummaries()
    {
        var normalWins = FetchNormalWindows();
        var grouped = new Dictionary<string, (ShareableWindowItem Sample, uint Count)>(StringComparer.OrdinalIgnoreCase);

        foreach (var w in normalWins)
        {
            if (grouped.TryGetValue(w.AppId, out var ex))
            {
                grouped[w.AppId] = (ex.Sample, ex.Count + 1);
            }
            else
            {
                grouped[w.AppId] = (w, 1);
            }
        }

        var apps = grouped.Select(kv =>
        {
            var sample = kv.Value.Sample;
            string iconB64 = "";
            try
            {
                iconB64 = IconCompositor.ExtractWindowOrExeIconBase64(
                    sample.Hwnd,
                    sample.ExePath,
                    sample.ExplicitIconPath,
                    sample.DiscoveredIconPath,
                    sample.IsGenericRuntime,
                    sample.AppName
                );
            }
            catch
            {
            }
            return new RemoteAppSummary
            {
                BundleId = kv.Key,
                Name = sample.AppName,
                Pid = sample.Pid,
                WindowCount = kv.Value.Count,
                IconPngB64 = iconB64
            };
        })
        .OrderByDescending(a => a.BundleId == WeChatBundleId)
        .ThenBy(a => a.Name, StringComparer.OrdinalIgnoreCase)
        .ToList();

        string hostName = "PC";
        try { hostName = Environment.MachineName; } catch { }

        string deskIcon = "";
        try { deskIcon = IconCompositor.GenerateDesktopIconBase64(); } catch { }

        apps.Insert(0, new RemoteAppSummary
        {
            BundleId = MultiWindowCaptureManager.FullDesktopBundleId,
            Name = $"整台电脑桌面 ({hostName})",
            Pid = 0,
            WindowCount = 1,
            IconPngB64 = deskIcon
        });

        return apps;
    }

    private static ResolvedAppMeta ResolveProcessMetadata(uint pid, IntPtr hwnd, string fallbackTitle)
    {
        lock (CacheLock)
        {
            if (ProcessMetaCache.TryGetValue(pid, out var cached))
            {
                if (cached.AllowLiveTitleUpgrade)
                {
                    string liveTitleName = CleanWindowTitleForAppName(fallbackTitle);
                    if (!string.IsNullOrEmpty(liveTitleName) &&
                        !string.Equals(liveTitleName, cached.AppName, StringComparison.Ordinal))
                    {
                        var upgraded = cached with { AppName = liveTitleName };
                        ProcessMetaCache[pid] = upgraded;
                        return upgraded;
                    }
                }
                return cached;
            }
        }

        string? exePath = null;
        string procName = "";
        string friendlyName = "";

        try
        {
            exePath = Win32Interop.TryGetProcessExePath(pid);
            if (!string.IsNullOrWhiteSpace(exePath))
            {
                procName = Path.GetFileNameWithoutExtension(exePath) ?? "";
            }
        }
        catch
        {
        }

        if (string.IsNullOrWhiteSpace(procName))
        {
            procName = TryGetProcessNameFallback(pid);
        }

        if (string.IsNullOrWhiteSpace(procName) ||
            procName.Equals("ApplicationFrameHost", StringComparison.OrdinalIgnoreCase))
        {
            return new ResolvedAppMeta("", "", null, null, null, false, false);
        }

        if (!string.IsNullOrEmpty(exePath))
        {
            try
            {
                friendlyName = TryReadFriendlyFileDescription(exePath);
            }
            catch
            {
            }
        }

        bool isGenericRuntime = GenericRuntimeProcessNames.Contains(procName) ||
                                string.Equals(friendlyName, "Electron", StringComparison.OrdinalIgnoreCase);

        (string? aumid, string? relaunchName, string? relaunchIcon) =
            (isGenericRuntime || string.IsNullOrWhiteSpace(friendlyName))
                ? Win32Interop.TryGetWindowAppUserModelProperties(hwnd)
                : (null, null, null);

        if (isGenericRuntime)
        {
            var hosted = ResolveHostedAppMetadata(pid, procName, exePath, fallbackTitle, aumid, relaunchName, relaunchIcon);
            lock (CacheLock)
            {
                if (ProcessMetaCache.Count > 512)
                    ProcessMetaCache.Clear();
                ProcessMetaCache[pid] = hosted;
            }
            return hosted;
        }

        string appId;
        if (procName.Equals("WeChat", StringComparison.OrdinalIgnoreCase) ||
            procName.Equals("Weixin", StringComparison.OrdinalIgnoreCase) ||
            procName.Equals("WeChatAppEx", StringComparison.OrdinalIgnoreCase))
        {
            appId = WeChatBundleId;
            if (string.IsNullOrWhiteSpace(friendlyName))
                friendlyName = "微信";
        }
        else
        {
            appId = $"win.app.{procName.ToLowerInvariant()}";
        }

        if (!string.IsNullOrWhiteSpace(relaunchName) && !relaunchName.StartsWith('@'))
            friendlyName = relaunchName;

        if (string.IsNullOrWhiteSpace(friendlyName))
            friendlyName = procName;

        friendlyName = friendlyName.Replace("\0", "").Trim();
        if (string.IsNullOrWhiteSpace(friendlyName))
            friendlyName = !string.IsNullOrWhiteSpace(fallbackTitle) ? fallbackTitle : procName;

        string? explicitIcon = !string.IsNullOrWhiteSpace(relaunchIcon) ? relaunchIcon : null;
        var entry = new ResolvedAppMeta(appId, friendlyName, exePath, explicitIcon, null, false, false);
        lock (CacheLock)
        {
            if (ProcessMetaCache.Count > 512)
                ProcessMetaCache.Clear();
            ProcessMetaCache[pid] = entry;
        }
        return entry;
    }

    /// <summary>
    /// Resolves the true application name, unique <c>win.app.*</c> bundle ID, and project icon file for apps
    /// hosted inside generic runtimes such as unpackaged <c>electron.exe</c>, <c>javaw.exe</c>, or <c>pythonw.exe</c>.
    /// </summary>
    private static ResolvedAppMeta ResolveHostedAppMetadata(
        uint pid,
        string procName,
        string? exePath,
        string fallbackTitle,
        string? aumid,
        string? relaunchName,
        string? relaunchIcon
    )
    {
        string? explicitAppName = null;
        string? explicitIconPath = null;
        string? fallbackPkgOrDirName = null;

        if (!string.IsNullOrWhiteSpace(relaunchName) &&
            !relaunchName.StartsWith('@') &&
            !relaunchName.Equals("Electron", StringComparison.OrdinalIgnoreCase))
        {
            explicitAppName = relaunchName.Trim();
        }

        if (!string.IsNullOrWhiteSpace(relaunchIcon) &&
            !relaunchIcon.Contains("electron.exe", StringComparison.OrdinalIgnoreCase))
        {
            explicitIconPath = relaunchIcon.Trim();
        }

        var candidateDirs = DiscoverHostedAppDirectories(pid, exePath);
        string? primaryProjectDir = candidateDirs.FirstOrDefault();

        foreach (var dir in candidateDirs)
        {
            string pkgJsonPath = Path.Combine(dir, "package.json");
            if (File.Exists(pkgJsonPath))
            {
                var (prodName, pkgName, pkgIconPath) = ReadPackageJsonMetadata(pkgJsonPath, dir);
                if (string.IsNullOrWhiteSpace(explicitAppName) && !string.IsNullOrWhiteSpace(prodName))
                    explicitAppName = prodName;
                if (string.IsNullOrWhiteSpace(explicitIconPath) && !string.IsNullOrWhiteSpace(pkgIconPath))
                    explicitIconPath = pkgIconPath;
                if (string.IsNullOrWhiteSpace(fallbackPkgOrDirName) && !string.IsNullOrWhiteSpace(pkgName))
                    fallbackPkgOrDirName = pkgName;
            }

            if (string.IsNullOrWhiteSpace(explicitAppName))
            {
                string? builderProdName = TryReadElectronBuilderProductName(dir);
                if (!string.IsNullOrWhiteSpace(builderProdName))
                    explicitAppName = builderProdName;
            }

            string folderName = Path.GetFileName(dir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            if (!string.IsNullOrWhiteSpace(folderName) && !GenericFolderOrPackageNames.Contains(folderName))
            {
                // Prefer the outermost non-generic project root folder name (e.g. "Octop" over "octop-desktop")
                if (string.IsNullOrWhiteSpace(fallbackPkgOrDirName) ||
                    fallbackPkgOrDirName.EndsWith("-desktop", StringComparison.OrdinalIgnoreCase) ||
                    fallbackPkgOrDirName.EndsWith("_desktop", StringComparison.OrdinalIgnoreCase))
                {
                    fallbackPkgOrDirName = folderName;
                }
                primaryProjectDir = dir;
            }
        }

        string? discoveredIconPath = null;
        if (string.IsNullOrWhiteSpace(explicitIconPath) && candidateDirs.Count > 0)
        {
            discoveredIconPath = ScanProjectForBestAppIcon(candidateDirs, explicitAppName ?? fallbackPkgOrDirName);
        }

        string liveTitleName = CleanWindowTitleForAppName(fallbackTitle);
        bool allowLiveTitleUpgrade = false;
        string finalName;

        if (!string.IsNullOrWhiteSpace(explicitAppName))
        {
            finalName = explicitAppName;
        }
        else if (!string.IsNullOrWhiteSpace(liveTitleName))
        {
            finalName = liveTitleName;
            allowLiveTitleUpgrade = true;
        }
        else if (!string.IsNullOrWhiteSpace(fallbackPkgOrDirName))
        {
            finalName = fallbackPkgOrDirName;
            allowLiveTitleUpgrade = true;
        }
        else
        {
            finalName = !string.IsNullOrWhiteSpace(fallbackTitle) ? fallbackTitle : procName;
            allowLiveTitleUpgrade = true;
        }

        finalName = finalName.Replace("\0", "").Trim();

        string slugSource;
        if (!string.IsNullOrWhiteSpace(aumid) &&
            !aumid.Equals("electron.app.Electron", StringComparison.OrdinalIgnoreCase) &&
            !aumid.Equals("com.squirrel.electron.electron", StringComparison.OrdinalIgnoreCase))
        {
            slugSource = aumid;
        }
        else if (!string.IsNullOrWhiteSpace(primaryProjectDir))
        {
            string folder = Path.GetFileName(primaryProjectDir.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
            slugSource = !string.IsNullOrWhiteSpace(folder) && !GenericFolderOrPackageNames.Contains(folder)
                ? folder
                : finalName;
        }
        else
        {
            slugSource = finalName;
        }

        string slug = SanitizeBundleSlug(slugSource);
        string appId = string.IsNullOrEmpty(slug)
            ? $"win.app.{procName.ToLowerInvariant()}.{pid}"
            : $"win.app.{procName.ToLowerInvariant()}.{slug}";

        return new ResolvedAppMeta(
            appId,
            finalName,
            exePath,
            explicitIconPath,
            discoveredIconPath,
            IsGenericRuntime: true,
            AllowLiveTitleUpgrade: allowLiveTitleUpgrade
        );
    }

    private static List<string> DiscoverHostedAppDirectories(uint pid, string? exePath)
    {
        var seeds = new List<string>();
        string? nodeModulesParent = ExtractNodeModulesParentDir(exePath);

        try
        {
            var args = Win32Interop.TryGetProcessCommandLineArgs(pid);
            for (int i = 1; i < args.Count; i++)
            {
                string arg = args[i].Trim().Trim('"');
                if (string.IsNullOrWhiteSpace(arg) || arg.StartsWith('-'))
                    continue;

                string? candidate = null;
                if (Path.IsPathRooted(arg))
                {
                    candidate = arg;
                }
                else if (!string.IsNullOrEmpty(nodeModulesParent))
                {
                    try { candidate = Path.GetFullPath(Path.Combine(nodeModulesParent, arg)); }
                    catch { }
                }

                if (string.IsNullOrEmpty(candidate)) continue;
                if (Directory.Exists(candidate))
                {
                    seeds.Add(candidate);
                }
                else if (File.Exists(candidate))
                {
                    string? parent = Path.GetDirectoryName(candidate);
                    if (!string.IsNullOrEmpty(parent) && Directory.Exists(parent))
                        seeds.Add(parent);
                }
            }
        }
        catch
        {
        }

        if (!string.IsNullOrEmpty(nodeModulesParent) && Directory.Exists(nodeModulesParent))
            seeds.Add(nodeModulesParent);

        var ordered = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddDir(string d)
        {
            string norm = d.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (!string.IsNullOrWhiteSpace(norm) && Directory.Exists(norm) && seen.Add(norm))
                ordered.Add(norm);
        }

        foreach (var seed in seeds)
        {
            AddDir(seed);
            string? cur = seed;
            for (int depth = 0; depth < 2; depth++)
            {
                string? parent = Path.GetDirectoryName(cur?.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                if (string.IsNullOrWhiteSpace(parent)) break;
                string pName = Path.GetFileName(parent.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
                if (string.IsNullOrWhiteSpace(pName) || StopAncestorDirNames.Contains(pName))
                    break;
                AddDir(parent);
                cur = parent;
            }
        }

        return ordered;
    }

    private static string? ExtractNodeModulesParentDir(string? exePath)
    {
        if (string.IsNullOrWhiteSpace(exePath)) return null;
        const string marker = "\\node_modules\\";
        int idx = exePath.IndexOf(marker, StringComparison.OrdinalIgnoreCase);
        if (idx <= 2) return null;
        return exePath[..idx];
    }

    private static (string? ProductName, string? PackageName, string? IconPath) ReadPackageJsonMetadata(string pkgJsonPath, string baseDir)
    {
        try
        {
            var fi = new FileInfo(pkgJsonPath);
            if (!fi.Exists || fi.Length <= 2 || fi.Length > 512 * 1024)
                return (null, null, null);

            using var doc = JsonDocument.Parse(File.ReadAllText(pkgJsonPath, Encoding.UTF8));
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return (null, null, null);

            string? TryStr(JsonElement obj, string prop) =>
                obj.TryGetProperty(prop, out var el) && el.ValueKind == JsonValueKind.String
                    ? el.GetString()?.Trim()
                    : null;

            string? prodName = TryStr(root, "productName") ?? TryStr(root, "displayName");
            string? rawIcon = TryStr(root, "icon");

            if (root.TryGetProperty("build", out var buildEl) && buildEl.ValueKind == JsonValueKind.Object)
            {
                prodName ??= TryStr(buildEl, "productName");
                if (buildEl.TryGetProperty("win", out var winEl) && winEl.ValueKind == JsonValueKind.Object)
                    rawIcon ??= TryStr(winEl, "icon");
                rawIcon ??= TryStr(buildEl, "icon");
            }

            if (root.TryGetProperty("packagerConfig", out var forgeEl) && forgeEl.ValueKind == JsonValueKind.Object)
            {
                prodName ??= TryStr(forgeEl, "name");
                rawIcon ??= TryStr(forgeEl, "icon");
            }

            if (!string.IsNullOrWhiteSpace(prodName) && prodName.Equals("Electron", StringComparison.OrdinalIgnoreCase))
                prodName = null;

            string? pkgName = TryStr(root, "name");
            if (!string.IsNullOrWhiteSpace(pkgName))
            {
                if (pkgName.StartsWith('@') && pkgName.Contains('/'))
                    pkgName = pkgName[(pkgName.IndexOf('/') + 1)..];
                if (GenericFolderOrPackageNames.Contains(pkgName))
                    pkgName = null;
            }

            string? resolvedIcon = ResolveDeclaredIconFile(baseDir, rawIcon);
            return (prodName, pkgName, resolvedIcon);
        }
        catch
        {
            return (null, null, null);
        }
    }

    private static string? TryReadElectronBuilderProductName(string dir)
    {
        foreach (var fileName in ElectronBuilderConfigFiles)
        {
            string cfgPath = Path.Combine(dir, fileName);
            if (!File.Exists(cfgPath)) continue;
            try
            {
                var fi = new FileInfo(cfgPath);
                if (fi.Length <= 2 || fi.Length > 128 * 1024) continue;

                string text = File.ReadAllText(cfgPath, Encoding.UTF8);
                var m = QuotedProductNameRegex().Match(text);
                if (m.Success)
                {
                    string val = (m.Groups[1].Success ? m.Groups[1].Value : m.Groups[2].Value).Trim();
                    if (!string.IsNullOrWhiteSpace(val) && !val.Equals("Electron", StringComparison.OrdinalIgnoreCase))
                        return val;
                }

                if (fileName.EndsWith(".yml", StringComparison.OrdinalIgnoreCase) ||
                    fileName.EndsWith(".yaml", StringComparison.OrdinalIgnoreCase))
                {
                    var ym = YamlProductNameRegex().Match(text);
                    if (ym.Success)
                    {
                        string val = ym.Groups[1].Value.Trim();
                        if (!string.IsNullOrWhiteSpace(val) && !val.Equals("Electron", StringComparison.OrdinalIgnoreCase))
                            return val;
                    }
                }
            }
            catch
            {
            }
        }
        return null;
    }

    private static string? ResolveDeclaredIconFile(string baseDir, string? rawIcon)
    {
        if (string.IsNullOrWhiteSpace(rawIcon)) return null;
        try
        {
            string combined = Path.IsPathRooted(rawIcon)
                ? rawIcon
                : Path.GetFullPath(Path.Combine(baseDir, rawIcon));

            if (File.Exists(combined))
                return combined;
            if (File.Exists(combined + ".ico"))
                return combined + ".ico";
            if (File.Exists(combined + ".png"))
                return combined + ".png";
        }
        catch
        {
        }
        return null;
    }

    private static string? ScanProjectForBestAppIcon(IReadOnlyList<string> candidateDirs, string? appHint)
    {
        string? bestPath = null;
        int bestScore = 0;
        var visitedDirs = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        int inspectedFiles = 0;

        void EvaluateFile(string filePath)
        {
            if (inspectedFiles > 400) return;
            string ext = Path.GetExtension(filePath).ToLowerInvariant();
            if (ext is not (".ico" or ".png")) return;

            string stem = Path.GetFileNameWithoutExtension(filePath);
            if (string.IsNullOrWhiteSpace(stem)) return;

            int nameScore = 0;
            if (stem.Equals("icon", StringComparison.OrdinalIgnoreCase) ||
                stem.Equals("app-icon", StringComparison.OrdinalIgnoreCase) ||
                stem.Equals("app_icon", StringComparison.OrdinalIgnoreCase) ||
                stem.Equals("appicon", StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 100;
            }
            else if (!string.IsNullOrWhiteSpace(appHint) && stem.Equals(appHint, StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 98;
            }
            else if (stem.Equals("logo", StringComparison.OrdinalIgnoreCase) ||
                     stem.Equals("app", StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 92;
            }
            else if (stem.Contains("icon", StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 75;
            }
            else if (stem.Contains("logo", StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 70;
            }
            else if (stem.Equals("favicon", StringComparison.OrdinalIgnoreCase))
            {
                nameScore = 55;
            }

            if (nameScore == 0) return;
            inspectedFiles++;

            if (ext == ".ico")
            {
                try
                {
                    var fi = new FileInfo(filePath);
                    if (!fi.Exists || fi.Length < 128 || fi.Length > 4 * 1024 * 1024) return;
                    int score = nameScore + 25;
                    if (score > bestScore)
                    {
                        bestScore = score;
                        bestPath = filePath;
                    }
                }
                catch
                {
                }
            }
            else if (ext == ".png")
            {
                if (!TryReadPngDimensions(filePath, out int w, out int h)) return;
                if (w < 32 || h < 32 || w > 2048 || h > 2048) return;
                double aspect = w / (double)h;
                if (aspect < 0.78 || aspect > 1.28) return; // Reject horizontal banners

                int sizeBonus = (w >= 128 && w <= 1024) ? 22 : (w >= 64 ? 12 : 0);
                int score = nameScore + sizeBonus;
                if (score > bestScore)
                {
                    bestScore = score;
                    bestPath = filePath;
                }
            }
        }

        void WalkDir(string dir, int depth)
        {
            if (depth > 3 || inspectedFiles > 400 || !visitedDirs.Add(dir))
                return;

            try
            {
                foreach (var f in Directory.EnumerateFiles(dir))
                    EvaluateFile(f);

                if (depth < 3)
                {
                    foreach (var sub in Directory.EnumerateDirectories(dir))
                    {
                        string subName = Path.GetFileName(sub);
                        if (string.IsNullOrEmpty(subName) || subName.StartsWith('.') || IgnoredScanSubdirs.Contains(subName))
                            continue;
                        WalkDir(sub, depth + 1);
                    }
                }
            }
            catch
            {
            }
        }

        foreach (var root in candidateDirs)
            WalkDir(root, 0);

        return bestPath;
    }

    private static bool TryReadPngDimensions(string path, out int width, out int height)
    {
        width = 0;
        height = 0;
        try
        {
            Span<byte> hdr = stackalloc byte[24];
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            if (fs.Read(hdr) < 24) return false;
            if (hdr[0] != 0x89 || hdr[1] != 0x50 || hdr[2] != 0x4E || hdr[3] != 0x47)
                return false;

            width = (hdr[16] << 24) | (hdr[17] << 16) | (hdr[18] << 8) | hdr[19];
            height = (hdr[20] << 24) | (hdr[21] << 16) | (hdr[22] << 8) | hdr[23];
            return width > 0 && height > 0;
        }
        catch
        {
            return false;
        }
    }

    private static string CleanWindowTitleForAppName(string rawTitle)
    {
        if (string.IsNullOrWhiteSpace(rawTitle)) return "";
        string cleaned = UnreadBadgeStripRegex().Replace(rawTitle, "").Trim();
        if (string.IsNullOrWhiteSpace(cleaned)) return "";

        if (cleaned.Equals("Electron", StringComparison.OrdinalIgnoreCase) ||
            cleaned.StartsWith("DevTools", StringComparison.OrdinalIgnoreCase) ||
            cleaned.StartsWith("Developer Tools", StringComparison.OrdinalIgnoreCase) ||
            cleaned.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            cleaned.StartsWith("https://", StringComparison.OrdinalIgnoreCase) ||
            cleaned.StartsWith("localhost:", StringComparison.OrdinalIgnoreCase) ||
            cleaned.Equals("Loading...", StringComparison.OrdinalIgnoreCase))
        {
            return "";
        }

        // If title follows "Document - AppName" convention, take the trailing app name segment if concise
        int sepIdx = cleaned.LastIndexOf(" - ", StringComparison.Ordinal);
        if (sepIdx > 0 && sepIdx + 3 < cleaned.Length)
        {
            string tail = cleaned[(sepIdx + 3)..].Trim();
            if (tail.Length is >= 2 and <= 32 && !tail.Equals("Electron", StringComparison.OrdinalIgnoreCase))
                return tail;
        }

        return cleaned.Length > 40 ? cleaned[..40].Trim() : cleaned;
    }

    private static string SanitizeBundleSlug(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        var sb = new StringBuilder(raw.Length);
        foreach (char ch in raw.Trim())
        {
            if (char.IsAsciiLetterOrDigit(ch))
                sb.Append(char.ToLowerInvariant(ch));
            else if (ch is '.' or '-' or '_')
                sb.Append('.');
        }
        string ascii = sb.ToString().Trim('.');
        if (ascii.Length >= 2)
            return ascii;

        // Deterministic short hex hash for pure-CJK names
        uint hash = 2166136261u;
        foreach (char c in raw)
        {
            hash ^= c;
            hash *= 16777619u;
        }
        return $"app{hash:x8}";
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static string TryGetProcessNameFallback(uint pid)
    {
        try
        {
            using var proc = Process.GetProcessById((int)pid);
            return proc.ProcessName ?? "";
        }
        catch
        {
            return "";
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static string TryReadFriendlyFileDescription(string exePath)
    {
        if (!File.Exists(exePath)) return "";
        var fvi = FileVersionInfo.GetVersionInfo(exePath);
        return !string.IsNullOrWhiteSpace(fvi.FileDescription)
            ? fvi.FileDescription.Trim()
            : (fvi.ProductName?.Trim() ?? "");
    }
}

using System.Diagnostics;
using System.IO;

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
    public bool IsPopup { get; init; }
    public Win32Interop.RECT PhysicalBounds { get; init; }
    public double DpiScale { get; init; } = 1.0;

    public float LogicalWidth => MathF.Max(1f, (float)(PhysicalBounds.Width / DpiScale));
    public float LogicalHeight => MathF.Max(1f, (float)(PhysicalBounds.Height / DpiScale));
    public float LogicalX => (float)(PhysicalBounds.Left / DpiScale);
    public float LogicalY => (float)(PhysicalBounds.Top / DpiScale);
}

public static class WindowCatalog
{
    public const string WeChatBundleId = "com.tencent.xinWeChat";

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
        "IME",
        "MSCTFIME UI"
    };

    private static readonly Dictionary<uint, (string AppId, string AppName, string? ExePath)> ProcessMetaCache = new();
    private static readonly object CacheLock = new();

    public static List<ShareableWindowItem> FetchNormalWindows()
    {
        int myPid = Environment.ProcessId;
        var results = new List<ShareableWindowItem>();

        Win32Interop.EnumWindows((hwnd, _) =>
        {
            if (!Win32Interop.IsWindowVisible(hwnd))
                return true;
            if (Win32Interop.IsWindowCloaked(hwnd))
                return true;

            Win32Interop.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || pid == (uint)myPid)
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

            string title = Win32Interop.GetWindowTitle(hwnd).Trim();
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

            var (appId, appName, exePath) = ResolveProcessMetadata(pid, title);
            if (string.IsNullOrEmpty(appId))
                return true;

            results.Add(new ShareableWindowItem
            {
                Hwnd = hwnd,
                Pid = pid,
                AppId = appId,
                AppName = appName,
                Title = title,
                ExePath = exePath,
                IsPopup = false,
                PhysicalBounds = bounds,
                DpiScale = scale
            });
            return true;
        }, IntPtr.Zero);

        results.Sort((a, b) =>
        {
            bool aWeChat = a.AppId == WeChatBundleId;
            bool bWeChat = b.AppId == WeChatBundleId;
            if (aWeChat != bWeChat) return aWeChat ? -1 : 1;
            return string.Compare(a.AppName, b.AppName, StringComparison.CurrentCultureIgnoreCase);
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

        Win32Interop.EnumWindows((hwnd, _) =>
        {
            if (!Win32Interop.IsWindowVisible(hwnd) || Win32Interop.IsIconic(hwnd))
                return true;
            if (Win32Interop.IsWindowCloaked(hwnd))
                return true;

            Win32Interop.GetWindowThreadProcessId(hwnd, out uint pid);
            if (pid == 0 || pid == (uint)myPid)
                return true;

            string title = Win32Interop.GetWindowTitle(hwnd).Trim();
            var (appId, appName, exePath) = ResolveProcessMetadata(pid, title);
            bool matchesApp = sharedAppIds.Contains(appId) || sharedPids.Contains(pid);
            if (!matchesApp)
                return true;

            uint style = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_STYLE);
            uint exStyle = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE);
            if ((style & Win32Interop.WS_CHILD) != 0)
                return true;

            string className = Win32Interop.GetWindowClassName(hwnd);
            if (string.Equals(className, "SysShadow", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(className, "IME", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(className, "MSCTFIME UI", StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }

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
                AppId = appId,
                AppName = appName,
                Title = string.IsNullOrEmpty(title) ? (isMenuOrPopup ? "菜单" : appName) : title,
                ExePath = exePath,
                IsPopup = isMenuOrPopup,
                PhysicalBounds = bounds,
                DpiScale = scale
            });
            return true;
        }, IntPtr.Zero);

        return results;
    }

    public static List<RemoteAppSummary> BuildHostAppSummaries()
    {
        var normalWins = FetchNormalWindows();
        var grouped = new Dictionary<string, (string Name, uint Pid, uint Count, IntPtr SampleHwnd, string? ExePath)>(StringComparer.OrdinalIgnoreCase);

        foreach (var w in normalWins)
        {
            if (grouped.TryGetValue(w.AppId, out var ex))
            {
                grouped[w.AppId] = (ex.Name, ex.Pid, ex.Count + 1, ex.SampleHwnd, ex.ExePath);
            }
            else
            {
                grouped[w.AppId] = (w.AppName, w.Pid, 1, w.Hwnd, w.ExePath);
            }
        }

        var apps = grouped.Select(kv =>
        {
            var val = kv.Value;
            string iconB64 = IconCompositor.ExtractWindowOrExeIconBase64(val.SampleHwnd, val.ExePath);
            return new RemoteAppSummary
            {
                BundleId = kv.Key,
                Name = val.Name,
                Pid = val.Pid,
                WindowCount = val.Count,
                IconPngB64 = iconB64
            };
        })
        .OrderByDescending(a => a.BundleId == WeChatBundleId)
        .ThenBy(a => a.Name, StringComparer.CurrentCultureIgnoreCase)
        .ToList();

        string hostName = Environment.MachineName;
        apps.Insert(0, new RemoteAppSummary
        {
            BundleId = MultiWindowCaptureManager.FullDesktopBundleId,
            Name = $"整台电脑桌面 ({hostName})",
            Pid = 0,
            WindowCount = 1,
            IconPngB64 = IconCompositor.GenerateDesktopIconBase64()
        });

        return apps;
    }

    private static (string AppId, string AppName, string? ExePath) ResolveProcessMetadata(uint pid, string fallbackTitle)
    {
        lock (CacheLock)
        {
            if (ProcessMetaCache.TryGetValue(pid, out var cached))
                return cached;
        }

        string procName = "";
        string? exePath = null;
        string friendlyName = "";

        try
        {
            using var proc = Process.GetProcessById((int)pid);
            procName = proc.ProcessName;
            try
            {
                exePath = proc.MainModule?.FileName;
                if (!string.IsNullOrEmpty(exePath) && File.Exists(exePath))
                {
                    var fvi = FileVersionInfo.GetVersionInfo(exePath);
                    friendlyName = !string.IsNullOrWhiteSpace(fvi.FileDescription)
                        ? fvi.FileDescription.Trim()
                        : (fvi.ProductName?.Trim() ?? "");
                }
            }
            catch
            {
                // Elevated/system process MainModule may deny read; ProcessName still succeeds
            }
        }
        catch
        {
            return ("", "", null);
        }

        if (string.IsNullOrWhiteSpace(procName))
            return ("", "", null);

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

        if (string.IsNullOrWhiteSpace(friendlyName))
            friendlyName = !string.IsNullOrWhiteSpace(fallbackTitle) ? procName : procName;

        var entry = (appId, friendlyName, exePath);
        lock (CacheLock)
        {
            if (ProcessMetaCache.Count > 512)
                ProcessMetaCache.Clear();
            ProcessMetaCache[pid] = entry;
        }
        return entry;
    }
}

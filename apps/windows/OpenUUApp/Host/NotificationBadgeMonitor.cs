using System.Text.RegularExpressions;
using System.Windows.Threading;

namespace OpenUU.Host;

/// <summary>
/// Watches shared Windows applications' window titles for unread message badge counts
/// (e.g. <c>微信 (3)</c>, <c>(12) Discord</c>, <c>[2] Slack</c>) and emits <c>BadgeUpdate</c> &amp; <c>NotificationEvent</c>
/// alerts to connected Clients (Windows counterpart to macOS <c>NotificationBadgeMonitor</c>).
/// </summary>
public sealed partial class NotificationBadgeMonitor : IDisposable
{
    public Action<string, string, string, string>? OnNotification { get; set; }
    public Action<string, string>? OnBadgeChanged { get; set; }

    private DispatcherTimer? _timer;
    private bool _isRunning;
    private bool _isEnabled = true;
    private Dictionary<string, string> _watchedApps = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _lastBadges = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, long> _lastNotifTick = new(StringComparer.OrdinalIgnoreCase);

    [GeneratedRegex(@"(?:^\s*[\(\[（【](\d{1,3}\+?)[\)\]）】])|(?:[\(\[（【](\d{1,3}\+?)[\)\]）】]\s*$)", RegexOptions.Compiled)]
    private static partial Regex UnreadCountRegex();

    public void SetEnabled(bool enabled) => _isEnabled = enabled;

    public void UpdateWatchedApps(IEnumerable<(string BundleId, string Name)> apps)
    {
        var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (bid, name) in apps)
        {
            if (!string.IsNullOrWhiteSpace(bid))
                map[bid] = name;
        }
        _watchedApps = map;
    }

    public void Start()
    {
        if (_isRunning) return;
        _isRunning = true;
        _lastBadges.Clear();
        _timer?.Stop();
        _timer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromSeconds(2.0)
        };
        _timer.Tick += (_, _) => PollAppWindowBadges();
        _timer.Start();
    }

    public void Stop()
    {
        _isRunning = false;
        _timer?.Stop();
        _timer = null;
        _lastBadges.Clear();
    }

    public void Dispose() => Stop();

    private void PollAppWindowBadges()
    {
        if (!_isRunning || !_isEnabled || _watchedApps.Count == 0) return;

        var wins = WindowCatalog.FetchNormalWindows();
        var observed = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        foreach (var w in wins)
        {
            if (!_watchedApps.ContainsKey(w.AppId)) continue;
            string badge = ExtractBadgeFromTitle(w.Title);
            if (!string.IsNullOrEmpty(badge))
                observed[w.AppId] = badge;
            else if (!observed.ContainsKey(w.AppId))
                observed[w.AppId] = "";
        }

        long now = Environment.TickCount64;
        foreach (var (appId, appName) in _watchedApps)
        {
            string newBadge = observed.TryGetValue(appId, out var b) ? b : "";
            bool hadPrev = _lastBadges.TryGetValue(appId, out var oldBadge);
            if (hadPrev && oldBadge == newBadge)
                continue;

            _lastBadges[appId] = newBadge;
            OnBadgeChanged?.Invoke(appId, newBadge);

            if (hadPrev && BadgeIncreased(oldBadge ?? "", newBadge))
            {
                long prevTick = _lastNotifTick.TryGetValue(appId, out long t) ? t : 0;
                if (now - prevTick > 2500)
                {
                    _lastNotifTick[appId] = now;
                    string body = $"收到新消息（当前未读: {newBadge}）";
                    OnNotification?.Invoke(appId, appName, "", body);
                }
            }
        }
    }

    private static string ExtractBadgeFromTitle(string title)
    {
        if (string.IsNullOrWhiteSpace(title)) return "";
        var m = UnreadCountRegex().Match(title);
        if (!m.Success) return "";
        return !string.IsNullOrEmpty(m.Groups[1].Value) ? m.Groups[1].Value : m.Groups[2].Value;
    }

    private static bool BadgeIncreased(string oldBadge, string newBadge)
    {
        if (string.IsNullOrEmpty(newBadge)) return false;
        if (string.IsNullOrEmpty(oldBadge)) return true;
        int oldN = int.TryParse(new string(oldBadge.Where(char.IsDigit).ToArray()), out int o) ? o : 0;
        int newN = int.TryParse(new string(newBadge.Where(char.IsDigit).ToArray()), out int n) ? n : 0;
        return newN > oldN;
    }
}

using System.Collections.ObjectModel;
using System.Windows;
using System.Windows.Media;

namespace OpenUU.Client;

using OpenUU.Host;
using OpenUU.Shared;

public enum RemoteSessionPhase
{
    Idle,
    Connecting,
    Connected,
    Error
}

/// <summary>
/// Independent remote Host session allowing a single Windows OpenUU Client to simultaneously connect to
/// and control MULTIPLE remote Macs and/or Windows PCs side-by-side without window ID or Taskbar collisions!
/// </summary>
public sealed class RemotePeerSession : ObservableBase, IDisposable
{
    public string Id { get; }
    public int SessionIndex { get; }
    public OpenUUBridge Bridge { get; }
    public FastVideoRouter VideoRouter { get; } = new();
    public AudioStreamPlayer AudioPlayer { get; } = new();

    private string _alias;
    public string Alias
    {
        get => _alias;
        set => SetField(ref _alias, value);
    }

    private string _target;
    public string Target
    {
        get => _target;
        set => SetField(ref _target, value);
    }

    private ushort _port;
    public ushort Port
    {
        get => _port;
        set => SetField(ref _port, value);
    }

    private RemoteSessionPhase _phase = RemoteSessionPhase.Idle;
    public RemoteSessionPhase Phase
    {
        get => _phase;
        private set
        {
            if (SetField(ref _phase, value))
            {
                OnPropertyChanged(nameof(IsConnected));
                OnPropertyChanged(nameof(IsConnecting));
                OnPropertyChanged(nameof(IsError));
            }
        }
    }

    public bool IsConnected => Phase == RemoteSessionPhase.Connected;
    public bool IsConnecting => Phase == RemoteSessionPhase.Connecting;
    public bool IsError => Phase == RemoteSessionPhase.Error;
    public DateTime? ConnectingStartedAtUtc { get; private set; }
    public int ElapsedConnectingSeconds => ConnectingStartedAtUtc.HasValue
        ? Math.Max(0, (int)(DateTime.UtcNow - ConnectingStartedAtUtc.Value).TotalSeconds)
        : 0;

    private string _errorMessage = "";
    public string ErrorMessage
    {
        get => _errorMessage;
        private set => SetField(ref _errorMessage, value);
    }

    private string _linkBadge = "";
    public string LinkBadge
    {
        get => _linkBadge;
        private set => SetField(ref _linkBadge, value);
    }

    private string _statusMessage = "未连接";
    public string StatusMessage
    {
        get => _statusMessage;
        private set => SetField(ref _statusMessage, value);
    }

    private string _remoteHostName = "";
    public string RemoteHostName
    {
        get => _remoteHostName;
        private set => SetField(ref _remoteHostName, value);
    }

    private int _openWindowCount;
    public int OpenWindowCount
    {
        get => _openWindowCount;
        private set => SetField(ref _openWindowCount, value);
    }

    public bool AutoOpenFullDesktopOnConnect { get; set; }

    private bool _remoteIsMacOs = true;
    private bool _mapCtrlToMacCommandPref = true;
    public bool MapCtrlToMacCommandPref
    {
        get => _mapCtrlToMacCommandPref;
        set
        {
            _mapCtrlToMacCommandPref = value;
            SyncCtrlMappingOnWindows();
        }
    }

    private bool _showDebugHud;
    public bool ShowDebugHud
    {
        get => _showDebugHud;
        set
        {
            _showDebugHud = value;
            foreach (var win in _proxyWindows.Values)
                win.SetDebugHudVisible(value);
        }
    }

    private bool _isAudioMuted;
    public bool IsAudioMuted
    {
        get => _isAudioMuted;
        set
        {
            if (SetField(ref _isAudioMuted, value))
            {
                AudioPlayer.SetMuted(value);
                foreach (var win in _proxyWindows.Values)
                    win.SetAudioMuted(value);
                if (IsConnected)
                    Bridge.SendAudioControl(enabled: !value, muteHost: _muteHostSpeakers);
                OnStateMutated?.Invoke();
            }
        }
    }

    private bool _muteHostSpeakers = true;
    public bool MuteHostSpeakers
    {
        get => _muteHostSpeakers;
        set
        {
            if (SetField(ref _muteHostSpeakers, value))
            {
                if (IsConnected)
                    Bridge.SendAudioControl(enabled: !_isAudioMuted, muteHost: value);
                OnStateMutated?.Invoke();
            }
        }
    }

    public ObservableCollection<RemoteAppSummary> RemoteApps { get; } = new();

    private readonly Dictionary<uint, ProxyWindow> _proxyWindows = new();
    private readonly Dictionary<uint, WindowTopologyItem> _knownWindows = new();
    private readonly HashSet<uint> _locallyClosedWindows = new();
    private readonly Dictionary<string, ImageSource> _compositedIcons = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, string> _latestBadges = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _openedBundleIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<uint, string> _windowToBundleId = new();
    private string? _lastOpenedBundleId;

    // AppState callbacks
    public Action? OnStateMutated { get; set; }
    public Action<RemotePeerSession, string, string>? OnConnected { get; set; }
    public Action<string>? OnStatusLog { get; set; }
    public Action<string, int, string?, string?, string?>? OnRemoteClipboard { get; set; }
    public Action<string>? OnRemoteClipboardFile { get; set; }
    public Action? OnBeforePasteShortcut { get; set; }
    public Action<RemotePeerSession, string, string, string, string, string, ImageSource?>? OnPresentNotification { get; set; }

    public RemotePeerSession(
        string id,
        int sessionIndex,
        string alias,
        string target,
        ushort port = 39481,
        WanConfigModel? wanConfig = null,
        string? configDir = null
    )
    {
        Id = id;
        SessionIndex = sessionIndex;
        _alias = alias;
        _target = target;
        _port = port;
        Bridge = new OpenUUBridge(configDir: configDir);
        if (wanConfig != null)
            Bridge.SetWanConfig(wanConfig);

        SetupCallbacks();
    }

    public string CompositeKey(string subKey) => $"{Id}::{subKey}";

    private void SetupCallbacks()
    {
        Bridge.OnStatus = msg =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                StatusMessage = msg;
                OnStatusLog?.Invoke($"[{Alias}] {msg}");
                OpenUULogger.Shared.Info("CLIENT", $"[{Alias}] {msg}");

                if (msg.StartsWith("connected to host:", StringComparison.OrdinalIgnoreCase))
                {
                    string rawName = msg["connected to host:".Length..]
                        .Split(" (", StringSplitOptions.None)[0]
                        .Trim();
                    if (string.IsNullOrEmpty(rawName)) rawName = Alias;
                    RemoteHostName = rawName;
                    ConnectingStartedAtUtc = null;
                    ErrorMessage = "";
                    Phase = RemoteSessionPhase.Connected;
                    AudioPlayer.SetMuted(_isAudioMuted);
                    Bridge.SendAudioControl(enabled: !_isAudioMuted, muteHost: _muteHostSpeakers);
                    Bridge.RequestAppList();

                    string remoteDevId = Bridge.GetIdentitySnapshot()?.TrustedPeers.FirstOrDefault()?.DeviceId ?? "";
                    OnConnected?.Invoke(this, rawName, remoteDevId);

                    if (AutoOpenFullDesktopOnConnect)
                    {
                        AutoOpenFullDesktopOnConnect = false;
                        OpenFullDesktop();
                    }
                }
                else if (msg.StartsWith("connect failed:", StringComparison.OrdinalIgnoreCase))
                {
                    string reason = msg["connect failed:".Length..].Trim();
                    CleanupSessionWindows();
                    ConnectingStartedAtUtc = null;
                    ErrorMessage = reason;
                    Phase = RemoteSessionPhase.Error;
                    OnStateMutated?.Invoke();
                }
                else if (msg.Contains("disconnected", StringComparison.OrdinalIgnoreCase))
                {
                    CleanupSessionWindows();
                    ConnectingStartedAtUtc = null;
                    Phase = RemoteSessionPhase.Idle;
                    OnStateMutated?.Invoke();
                }
                else if (IsConnecting)
                {
                    OnStateMutated?.Invoke();
                }
            });
        };

        Bridge.OnControlEvent = evt =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                switch (evt.Type)
                {
                    case "link_quality":
                    {
                        var tier = StreamNetworkTierExtensions.Parse(evt.LinkMode);
                        uint rtt = evt.RttMs ?? 0;
                        VideoRouter.SetWanJitterMode(tier != StreamNetworkTier.Lan);
                        LinkBadge = rtt > 0 ? $"{tier.GetLabel()} · {rtt}ms" : tier.GetLabel();
                        OnStateMutated?.Invoke();
                        break;
                    }
                    case "cursor":
                    {
                        if (!string.IsNullOrEmpty(evt.Kind))
                        {
                            foreach (var win in _proxyWindows.Values)
                                win.ApplyRemoteCursor(evt.Kind);
                        }
                        break;
                    }
                    case "window_topology":
                    {
                        if (evt.Windows != null)
                        {
                            OpenUULogger.Shared.Debug("TOPO", $"window_topology count={evt.Windows.Count} ids=[{string.Join(",", evt.Windows.Select(w => w.WindowId))}]");
                            ReconcileRemoteWindows(evt.Windows);
                        }
                        break;
                    }
                    case "list_apps_resp":
                    {
                        if (evt.Apps != null)
                        {
                            OpenUULogger.Shared.Info("CLIENT", $"list_apps_resp count={evt.Apps.Count}");
                            // Auto-detect whether remote Host is Windows (win.app.*) vs macOS (com.*)
                            bool anyWindowsApp = evt.Apps.Any(a => a.BundleId.StartsWith("win.app.", StringComparison.OrdinalIgnoreCase));
                            _remoteIsMacOs = !anyWindowsApp;
                            SyncCtrlMappingOnWindows();

                            RemoteApps.Clear();
                            foreach (var app in evt.Apps)
                            {
                                var comp = IconCompositor.CompositeWithOpenUUBadge(app.IconPngB64);
                                _compositedIcons[app.BundleId] = comp;
                                app.DisplayIcon = comp;
                                RemoteApps.Add(app);
                            }
                            OnStateMutated?.Invoke();
                        }
                        break;
                    }
                    case "clipboard_sync":
                    {
                        OnRemoteClipboard?.Invoke(
                            evt.ContentHash ?? "",
                            evt.ClipKind ?? 0,
                            evt.Text,
                            evt.MimeType,
                            evt.ImageB64
                        );
                        break;
                    }
                    case "notification":
                    {
                        string bid = evt.AppBundleId ?? "";
                        string appName = RemoteApps.FirstOrDefault(a => a.BundleId == bid)?.Name ?? bid;
                        _compositedIcons.TryGetValue(bid, out var icon);
                        OnPresentNotification?.Invoke(
                            this,
                            bid,
                            $"{appName} · {Alias}",
                            evt.Title ?? "",
                            evt.Subtitle ?? "",
                            evt.Body ?? "",
                            icon
                        );
                        break;
                    }
                    case "badge_update":
                    {
                        string bid = evt.AppBundleId ?? "";
                        string badge = evt.BadgeText ?? "";
                        if (!string.IsNullOrEmpty(bid))
                        {
                            _latestBadges[bid] = badge;
                            foreach (var (winId, pw) in _proxyWindows)
                            {
                                if (_windowToBundleId.TryGetValue(winId, out var wBid) &&
                                    string.Equals(wBid, bid, StringComparison.OrdinalIgnoreCase))
                                {
                                    pw.UpdateTaskbarBadge(badge);
                                }
                            }
                        }
                        break;
                    }
                    case "file_drop":
                    {
                        if (!string.IsNullOrEmpty(evt.LocalPath) && System.IO.File.Exists(evt.LocalPath))
                        {
                            uint winId = evt.WindowId ?? 0;
                            if (winId == 0xFFFF_FFFE)
                            {
                                bool handedOff = false;
                                foreach (var pw in _proxyWindows.Values)
                                {
                                    if (pw.DeliverDragOutFiles(new[] { evt.LocalPath }))
                                    {
                                        handedOff = true;
                                        break;
                                    }
                                }
                                if (!handedOff)
                                    OnRemoteClipboardFile?.Invoke(evt.LocalPath);
                            }
                            else
                            {
                                OnRemoteClipboardFile?.Invoke(evt.LocalPath);
                            }
                        }
                        break;
                    }
                }
            });
        };

        Bridge.OnVideoFrame = packet =>
        {
            bool needsSync = VideoRouter.RouteAndEnqueue(packet);
            if (needsSync)
            {
                uint winId = packet.WindowId;
                ushort w = packet.Width;
                ushort h = packet.Height;
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (_locallyClosedWindows.Contains(winId))
                        return;
                    var pw = EnsureProxyWindow(winId);
                    pw.SyncRemoteFrameSize(winId, w, h);
                });
            }
        };

        Bridge.OnAudioFrame = pkt =>
        {
            AudioPlayer.Enqueue(pkt);
        };
    }

    private void SyncCtrlMappingOnWindows()
    {
        bool effectiveMap = _mapCtrlToMacCommandPref && _remoteIsMacOs;
        foreach (var pw in _proxyWindows.Values)
            pw.MapCtrlToMacCommand = effectiveMap;
    }

    public void Connect(string password, bool autoOpenDesktop = false)
    {
        AutoOpenFullDesktopOnConnect = autoOpenDesktop;
        ConnectingStartedAtUtc = DateTime.UtcNow;
        Phase = RemoteSessionPhase.Connecting;
        ErrorMessage = "";
        StatusMessage = $"正在发起连接 {DeviceCodeFormatter.FormatInput(Target)}...";
        LinkBadge = "正在握手...";
        OnStateMutated?.Invoke();
        Bridge.ConnectSmart(Target, Port, password);
    }

    public void Disconnect()
    {
        Bridge.Disconnect();
        CleanupSessionWindows();
        ConnectingStartedAtUtc = null;
        Phase = RemoteSessionPhase.Idle;
        LinkBadge = "";
        OnStatusLog?.Invoke($"[{Alias}] 已断开远程连接");
    }

    public void ClearError()
    {
        if (Phase == RemoteSessionPhase.Error)
        {
            ErrorMessage = "";
            Phase = RemoteSessionPhase.Idle;
            OnStateMutated?.Invoke();
        }
    }

    public void RefreshApps() => Bridge.RequestAppList();

    public void OpenApp(RemoteAppSummary app)
    {
        _locallyClosedWindows.Clear();
        VideoRouter.UnsuppressAll();
        _openedBundleIds.Add(app.BundleId);
        _lastOpenedBundleId = app.BundleId;
        if (!_compositedIcons.ContainsKey(app.BundleId))
            _compositedIcons[app.BundleId] = IconCompositor.CompositeWithOpenUUBadge(app.IconPngB64);

        Bridge.StartRemoteSession(app.BundleId, 0);
        OnStatusLog?.Invoke($"[{Alias}] 正在打开远程应用: {app.Name}...");
    }

    public void OpenFullDesktop()
    {
        var desktop = RemoteApps.FirstOrDefault(a => a.BundleId == MultiWindowCaptureManager.FullDesktopBundleId)
            ?? new RemoteAppSummary
            {
                BundleId = MultiWindowCaptureManager.FullDesktopBundleId,
                Name = $"整台桌面 ({Alias})",
                Pid = 0,
                WindowCount = 1,
                IconPngB64 = IconCompositor.GenerateDesktopIconBase64()
            };
        OpenApp(desktop);
    }

    public void CleanupSessionWindows()
    {
        AudioPlayer.Stop();
        RemoteApps.Clear();
        LinkBadge = "";
        VideoRouter.SetWanJitterMode(false);
        foreach (var pw in _proxyWindows.Values)
            pw.CloseProgrammatically();
        _proxyWindows.Clear();
        OpenWindowCount = 0;
        VideoRouter.Clear();
        _knownWindows.Clear();
        _windowToBundleId.Clear();
        _openedBundleIds.Clear();
        _lastOpenedBundleId = null;
    }

    private void BindBundleId(WindowTopologyItem item)
    {
        if (_windowToBundleId.ContainsKey(item.WindowId)) return;
        if (item.WindowId == MultiWindowCaptureManager.FullDesktopWindowId)
        {
            _windowToBundleId[item.WindowId] = MultiWindowCaptureManager.FullDesktopBundleId;
            return;
        }
        if (item.ParentWindowId != 0 && _windowToBundleId.TryGetValue(item.ParentWindowId, out var parentBid))
        {
            _windowToBundleId[item.WindowId] = parentBid;
            return;
        }
        var matchedApp = RemoteApps.FirstOrDefault(a =>
            _openedBundleIds.Contains(a.BundleId) &&
            !string.IsNullOrEmpty(a.Name) &&
            (item.Title == a.Name || item.Title.StartsWith(a.Name, StringComparison.CurrentCultureIgnoreCase)));
        if (matchedApp != null)
        {
            _windowToBundleId[item.WindowId] = matchedApp.BundleId;
            return;
        }
        if (_openedBundleIds.Count == 1)
        {
            _windowToBundleId[item.WindowId] = _openedBundleIds.First();
            return;
        }
        if (_lastOpenedBundleId != null && _openedBundleIds.Contains(_lastOpenedBundleId))
        {
            _windowToBundleId[item.WindowId] = _lastOpenedBundleId;
        }
    }

    private ImageSource ResolveCompositedIcon(WindowTopologyItem item)
    {
        if (!string.IsNullOrEmpty(item.IconPngB64))
            return IconCompositor.CompositeWithOpenUUBadge(item.IconPngB64);
        if (_windowToBundleId.TryGetValue(item.WindowId, out var bid) && _compositedIcons.TryGetValue(bid, out var icon))
            return icon;
        if (item.ParentWindowId != 0 &&
            _windowToBundleId.TryGetValue(item.ParentWindowId, out var pBid) &&
            _compositedIcons.TryGetValue(pBid, out var pIcon))
            return pIcon;
        return _compositedIcons.Values.FirstOrDefault() ?? IconCompositor.CompositeWithOpenUUBadge(null);
    }

    private void ReconcileRemoteWindows(IReadOnlyList<WindowTopologyItem> remoteWindows)
    {
        var activeIds = remoteWindows.Select(w => w.WindowId).ToHashSet();
        foreach (var id in _locallyClosedWindows.Where(id => !activeIds.Contains(id)).ToList())
        {
            VideoRouter.Unsuppress(id);
            _locallyClosedWindows.Remove(id);
        }

        foreach (var id in _knownWindows.Keys.Where(id => !activeIds.Contains(id)).ToList())
            _knownWindows.Remove(id);

        foreach (var item in remoteWindows.Where(w => w.Kind == 0))
            BindBundleId(item);
        foreach (var item in remoteWindows.Where(w => w.Kind != 0))
            BindBundleId(item);

        foreach (var item in remoteWindows)
        {
            _knownWindows[item.WindowId] = item;
            if (_proxyWindows.TryGetValue(item.WindowId, out var pw))
            {
                ApplyTopologyToProxyWindow(item, pw);
            }
        }

        foreach (var kv in _proxyWindows.Where(kv => !activeIds.Contains(kv.Key)).ToList())
        {
            _proxyWindows.Remove(kv.Key);
            VideoRouter.Unregister(kv.Key);
            if (_windowToBundleId.Remove(kv.Key, out var bid) && !_windowToBundleId.Values.Contains(bid))
                _openedBundleIds.Remove(bid);
            kv.Value.CloseProgrammatically();
        }

        if (remoteWindows.Count == 0)
            _openedBundleIds.Clear();

        OpenWindowCount = _proxyWindows.Count;
        OnStateMutated?.Invoke();
    }

    private ProxyWindow EnsureProxyWindow(uint windowId)
    {
        if (_proxyWindows.TryGetValue(windowId, out var existing))
            return existing;

        _knownWindows.TryGetValue(windowId, out var info);
        double hostOffset = (SessionIndex % 5) * 44.0;
        double winOffset = _proxyWindows.Count * 28.0;
        var origin = new System.Windows.Point(160 + hostOffset + winOffset, 120 + winOffset);

        if (info is { ParentWindowId: not 0 } && _proxyWindows.TryGetValue(info.ParentWindowId, out var parentWin))
        {
            origin = new System.Windows.Point(parentWin.Left + info.RelX, parentWin.Top + info.RelY);
        }

        string title = string.IsNullOrWhiteSpace(info?.Title) ? "远程窗口" : info!.Title;
        string subId = _windowToBundleId.TryGetValue(windowId, out var bid) ? bid : $"win-{windowId}";
        string appUserModelId = $"ren.onekb.openuu.proxy.{Id}.{subId}.{windowId}";
        var icon = info != null ? ResolveCompositedIcon(info) : (_compositedIcons.Values.FirstOrDefault() ?? IconCompositor.CompositeWithOpenUUBadge(null));

        var pw = new ProxyWindow(
            Bridge,
            VideoRouter.RendererFor(windowId),
            title,
            appUserModelId,
            origin,
            icon,
            msg => OnStatusLog?.Invoke($"[{Alias}] {msg}")
        )
        {
            MapCtrlToMacCommand = _mapCtrlToMacCommandPref && _remoteIsMacOs
        };

        pw.SetDebugHudVisible(_showDebugHud);
        pw.SetAudioMuted(_isAudioMuted);
        pw.OnToggleAudioMute = () => IsAudioMuted = !IsAudioMuted;
        if (_windowToBundleId.TryGetValue(windowId, out var badgeBid) &&
            _latestBadges.TryGetValue(badgeBid, out var badgeText) &&
            !string.IsNullOrEmpty(badgeText))
        {
            pw.UpdateTaskbarBadge(badgeText);
        }

        pw.OnWindowMovedByUser = RefreshFloatingPopoversPlacement;
        pw.OnBeforePasteShortcut = () => OnBeforePasteShortcut?.Invoke();
        pw.OnWindowClosedByUser = closedId =>
        {
            _locallyClosedWindows.Add(closedId);
            _proxyWindows.Remove(closedId);
            VideoRouter.Suppress(closedId);

            var childIds = _knownWindows.Values
                .Where(w => w.ParentWindowId == closedId)
                .Select(w => w.WindowId)
                .ToList();
            foreach (var cid in childIds)
            {
                _locallyClosedWindows.Add(cid);
                VideoRouter.Suppress(cid);
                if (_proxyWindows.Remove(cid, out var childPw))
                    childPw.CloseProgrammatically();
            }

            Bridge.StopRemoteSession(closedId);
            if (_windowToBundleId.Remove(closedId, out var closedBid) && !_windowToBundleId.Values.Contains(closedBid))
                _openedBundleIds.Remove(closedBid);

            OpenWindowCount = _proxyWindows.Count;
            OnStateMutated?.Invoke();
        };

        _proxyWindows[windowId] = pw;
        OpenWindowCount = _proxyWindows.Count;
        if (info != null)
            ApplyTopologyToProxyWindow(info, pw);

        OnStateMutated?.Invoke();
        return pw;
    }

    private void ApplyTopologyToProxyWindow(WindowTopologyItem item, ProxyWindow pw)
    {
        pw.UpdateWindowTitle(item.Title);
        if (item.Kind != 2)
        {
            pw.UpdateTaskbarIcon(ResolveCompositedIcon(item));
        }

        bool isPopover = item.Kind == 2;
        float myArea = item.Width * item.Height;
        bool isOverlayPreview = isPopover && _knownWindows.Values.Any(other =>
            other.WindowId != item.WindowId &&
            other.Kind == 2 &&
            other.ParentWindowId == item.ParentWindowId &&
            (other.Width * other.Height) > myArea + 100f);

        pw.ConfigureFloatingPopover(isPopover, isOverlayPreview);
        if (isPopover && item.ParentWindowId != 0 && _proxyWindows.TryGetValue(item.ParentWindowId, out var parentPw))
        {
            var parentRemote = parentPw.RemoteLogicalSize;
            double scaleX = parentRemote.Width > 10 ? (parentPw.ActualWidth / parentRemote.Width) : 1.0;
            double scaleY = parentRemote.Height > 10 ? (parentPw.ActualHeight / parentRemote.Height) : 1.0;
            var parentBounds = new Rect(parentPw.Left, parentPw.Top, parentPw.ActualWidth, parentPw.ActualHeight);
            pw.UpdatePopoverPlacement(
                parentBounds,
                item.RelX * scaleX,
                item.RelY * scaleY,
                new System.Windows.Size(item.Width, item.Height)
            );
        }
    }

    private void RefreshFloatingPopoversPlacement()
    {
        foreach (var (wid, pw) in _proxyWindows)
        {
            if (_knownWindows.TryGetValue(wid, out var item) && item.Kind == 2)
                ApplyTopologyToProxyWindow(item, pw);
        }
    }

    public void FocusWindows(string subKey)
    {
        bool matched = false;
        foreach (var (winId, pw) in _proxyWindows)
        {
            if ((_windowToBundleId.TryGetValue(winId, out var bid) && string.Equals(bid, subKey, StringComparison.OrdinalIgnoreCase)) ||
                subKey == $"win-{winId}")
            {
                if (pw.WindowState == WindowState.Minimized)
                    pw.WindowState = WindowState.Normal;
                pw.Activate();
                matched = true;
            }
        }
        if (!matched)
        {
            foreach (var pw in _proxyWindows.Values)
            {
                if (pw.WindowState == WindowState.Minimized)
                    pw.WindowState = WindowState.Normal;
                pw.Activate();
            }
        }
    }

    public long TotalDecodedFramesAcrossWindows()
        => _proxyWindows.Values.Sum(pw => pw.Renderer.TotalDecodedFrames);

    public IReadOnlyDictionary<uint, WindowTopologyItem> SnapshotKnownWindows()
        => new Dictionary<uint, WindowTopologyItem>(_knownWindows);

    public void Dispose()
    {
        CleanupSessionWindows();
        AudioPlayer.Dispose();
        VideoRouter.Dispose();
        Bridge.Dispose();
    }
}

using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text.Json;
using System.Windows.Threading;

namespace OpenUU.App;

using OpenUU.Client;
using OpenUU.Host;
using OpenUU.Shared;

public sealed class UserPrefsModel
{
    public string ManualHostIp { get; set; } = "";
    public string ManualHostPort { get; set; } = "39481";
    public string ClientPin { get; set; } = "";
    public string HostPin { get; set; } = "";
    public bool SilentClick { get; set; } = true;
    public bool HoverCursor { get; set; } = true;
    public bool PreventSleep { get; set; } = true;
    public bool ClipboardSync { get; set; } = true;
    public bool NotificationSync { get; set; } = true;
    public bool RemoteAudioSync { get; set; } = true;
    public bool MuteHostAudio { get; set; } = true;
    public bool DynamicRes { get; set; } = true;
    public int TargetFps { get; set; } = 45;
    public bool DebugHud { get; set; } = false;
    public bool MapCtrlToMacCommand { get; set; } = true;
    public string CaptureScheme { get; set; } = "main";
    public double DrawerHeight { get; set; } = 215.0;
}

/// <summary>
/// Central state orchestrator for the Windows OpenUU application (1:1 counterpart to macOS <c>AppState</c>),
/// coordinating Host mode, LAN mDNS discovery, WAN 5-layer Smart Connect, multi-host concurrent Client sessions,
/// bidirectional Clipboard &amp; File sync, notifications, and diagnostic logging.
/// </summary>
public sealed class AppState : ObservableBase, IDisposable
{
    public const string DefaultRelayToken = "openuu-public-relay-fair-use";

    public OpenUUBridge HostBridge { get; }
    public OpenUUBridge ProbeBridge { get; }
    public MultiWindowCaptureManager CaptureManager { get; } = new();
    public InputInjector InputInjector { get; } = new();
    public SleepPreventer SleepPreventer { get; } = new();
    public ClipboardSyncManager ClipboardSync { get; } = new();
    public NotificationBadgeMonitor NotificationMonitor { get; } = new();
    public ClientNotificationManager ClientNotificationManager { get; } = new();
    public DeviceBookStore DeviceBook { get; }

    private readonly string? _customConfigDir;
    private readonly string _prefsPath;
    private UserPrefsModel _prefs = new();

    private readonly Dictionary<string, RemotePeerSession> _sessions = new();
    private readonly List<string> _activeSessionOrder = new();
    private int _nextSessionIndex;

    public ObservableCollection<RemotePeerSession> ConnectedSessions { get; } = new();
    public ObservableCollection<DiscoveredPeer> DiscoveredPeers { get; } = new();
    public ObservableCollection<TrustedPeerModel> TrustedPeers { get; } = new();
    public ObservableCollection<OpenUULogEntry> LogEntries { get; } = new();

    // Host incoming file-drop batching
    private readonly Dictionary<uint, List<string>> _pendingDroppedFiles = new();
    private readonly Dictionary<uint, CancellationTokenSource> _pendingDropCts = new();

    private SidebarTab _selectedTab = SidebarTab.RemoteHome;
    public SidebarTab SelectedTab
    {
        get => _selectedTab;
        set
        {
            if (SetField(ref _selectedTab, value))
            {
                OnPropertyChanged(nameof(HeaderTitle));
                OnPropertyChanged(nameof(HeaderSubtitle));
                OnPropertyChanged(nameof(ShowAddDeviceButton));
            }
        }
    }

    public string HeaderTitle => _selectedTab.GetTitle();
    public string HeaderSubtitle => _selectedTab.GetSubtitle();
    public bool ShowAddDeviceButton => _selectedTab is SidebarTab.RemoteHome or SidebarTab.DeviceList;

    private string _statusLog = "就绪";
    public string StatusLog
    {
        get => _statusLog;
        set
        {
            if (SetField(ref _statusLog, value))
                OpenUULogger.Shared.Debug("UI", value);
        }
    }

    private OpenUULogLevel _selectedLogLevel = OpenUULogLevel.Debug;
    public OpenUULogLevel SelectedLogLevel
    {
        get => _selectedLogLevel;
        set => SetField(ref _selectedLogLevel, value);
    }

    // Host State
    private bool _isHostRunning;
    public bool IsHostRunning
    {
        get => _isHostRunning;
        private set
        {
            if (SetField(ref _isHostRunning, value))
                OnPropertyChanged(nameof(IsAnyActive));
        }
    }

    private int _activeStreamCount;
    public int ActiveStreamCount
    {
        get => _activeStreamCount;
        private set => SetField(ref _activeStreamCount, value);
    }

    private ushort _hostPort = 39481;
    public ushort HostPort
    {
        get => _hostPort;
        set => SetField(ref _hostPort, value);
    }

    private string _hostPin = "";
    public string HostPin
    {
        get => _hostPin;
        set
        {
            if (SetField(ref _hostPin, value))
            {
                _prefs.HostPin = value;
                SavePrefs();
            }
        }
    }

    private bool _isHostPasswordRevealed = true;
    public bool IsHostPasswordRevealed
    {
        get => _isHostPasswordRevealed;
        set
        {
            if (SetField(ref _isHostPasswordRevealed, value))
                OnPropertyChanged(nameof(MaskedHostPin));
        }
    }

    public string MaskedHostPin => new('•', Math.Max(6, _hostPin.Length));

    // Quality & Security Toggles
    private int _targetFps = 45;
    public int TargetFps
    {
        get => _targetFps;
        set
        {
            if (SetField(ref _targetFps, value))
            {
                CaptureManager.TargetFps = value;
                _prefs.TargetFps = value;
                SavePrefs();
            }
        }
    }

    private string _captureScheme = "main";
    public string CaptureScheme
    {
        get => _captureScheme;
        set
        {
            if (SetField(ref _captureScheme, value))
            {
                _prefs.CaptureScheme = value;
                SavePrefs();
            }
        }
    }

    private bool _dynamicResolutionBoost = true;
    public bool DynamicResolutionBoost
    {
        get => _dynamicResolutionBoost;
        set
        {
            if (SetField(ref _dynamicResolutionBoost, value))
            {
                CaptureManager.DynamicResolutionEnabled = value;
                _prefs.DynamicRes = value;
                SavePrefs();
            }
        }
    }

    private bool _showDebugHud;
    public bool ShowDebugHud
    {
        get => _showDebugHud;
        set
        {
            if (SetField(ref _showDebugHud, value))
            {
                foreach (var s in _sessions.Values)
                    s.ShowDebugHud = value;
                _prefs.DebugHud = value;
                SavePrefs();
            }
        }
    }

    private bool _clipboardSyncEnabled = true;
    public bool ClipboardSyncEnabled
    {
        get => _clipboardSyncEnabled;
        set
        {
            if (SetField(ref _clipboardSyncEnabled, value))
            {
                ClipboardSync.IsEnabled = value;
                _prefs.ClipboardSync = value;
                SavePrefs();
            }
        }
    }

    private bool _notificationSyncEnabled = true;
    public bool NotificationSyncEnabled
    {
        get => _notificationSyncEnabled;
        set
        {
            if (SetField(ref _notificationSyncEnabled, value))
            {
                NotificationMonitor.SetEnabled(value);
                ClientNotificationManager.IsEnabled = value;
                _prefs.NotificationSync = value;
                SavePrefs();
            }
        }
    }

    private bool _remoteAudioEnabled = true;
    public bool RemoteAudioEnabled
    {
        get => _remoteAudioEnabled;
        set
        {
            if (SetField(ref _remoteAudioEnabled, value))
            {
                _prefs.RemoteAudioSync = value;
                SavePrefs();
                SyncHostAudioPreferences();
            }
        }
    }

    private bool _muteHostAudioDuringRemote = true;
    public bool MuteHostAudioDuringRemote
    {
        get => _muteHostAudioDuringRemote;
        set
        {
            if (SetField(ref _muteHostAudioDuringRemote, value))
            {
                _prefs.MuteHostAudio = value;
                SavePrefs();
                _clientRequestedMuteHost = null;
                SyncHostAudioPreferences();
            }
        }
    }

    private bool _clientRequestedAudioEnabled = true;
    private bool? _clientRequestedMuteHost;

    private bool _silentClickMode = true;
    public bool SilentClickMode
    {
        get => _silentClickMode;
        set
        {
            if (SetField(ref _silentClickMode, value))
            {
                InputInjector.SilentMode = value;
                _prefs.SilentClick = value;
                SavePrefs();
            }
        }
    }

    private bool _hoverCursorSync = true;
    public bool HoverCursorSync
    {
        get => _hoverCursorSync;
        set
        {
            if (SetField(ref _hoverCursorSync, value))
            {
                InputInjector.HoverCursorSync = value;
                _prefs.HoverCursor = value;
                SavePrefs();
            }
        }
    }

    private bool _preventDisplaySleep = true;
    public bool PreventDisplaySleep
    {
        get => _preventDisplaySleep;
        set
        {
            if (SetField(ref _preventDisplaySleep, value))
            {
                if (IsHostRunning)
                    SleepPreventer.SetEnabled(value);
                _prefs.PreventSleep = value;
                SavePrefs();
            }
        }
    }

    private bool _mapCtrlToMacCommand = true;
    public bool MapCtrlToMacCommand
    {
        get => _mapCtrlToMacCommand;
        set
        {
            if (SetField(ref _mapCtrlToMacCommand, value))
            {
                foreach (var s in _sessions.Values)
                    s.MapCtrlToMacCommandPref = value;
                _prefs.MapCtrlToMacCommand = value;
                SavePrefs();
            }
        }
    }

    public double DrawerHeight
    {
        get => _prefs.DrawerHeight;
        set
        {
            _prefs.DrawerHeight = value;
            SavePrefs();
        }
    }

    public bool IsRunningAsAdministrator { get; } = CheckIsAdmin();

    // Quick Connect Fields
    private string _quickConnectTarget = "";
    public string QuickConnectTarget
    {
        get => _quickConnectTarget;
        set
        {
            if (SetField(ref _quickConnectTarget, value))
            {
                _prefs.ManualHostIp = DeviceCodeFormatter.SanitizeForUse(value);
                SavePrefs();

                if (string.IsNullOrWhiteSpace(_quickConnectPassword))
                {
                    var matched = DeviceBook.FindMatchingDevice(value);
                    if (matched != null && !string.IsNullOrEmpty(matched.SavedPassword))
                        QuickConnectPassword = matched.SavedPassword;
                }
            }
        }
    }

    private string _quickConnectPort = "39481";
    public string QuickConnectPort
    {
        get => _quickConnectPort;
        set
        {
            if (SetField(ref _quickConnectPort, value))
            {
                _prefs.ManualHostPort = value;
                SavePrefs();
            }
        }
    }

    private string _quickConnectPassword = "";
    public string QuickConnectPassword
    {
        get => _quickConnectPassword;
        set
        {
            if (SetField(ref _quickConnectPassword, value))
            {
                _prefs.ClientPin = value;
                SavePrefs();
            }
        }
    }

    // Identity & WAN Config State
    private string _myFormattedDeviceCode = "--- --- ---";
    public string MyFormattedDeviceCode
    {
        get => _myFormattedDeviceCode;
        private set => SetField(ref _myFormattedDeviceCode, value);
    }

    private string _myRawDeviceCode = "";
    public string MyRawDeviceCode
    {
        get => _myRawDeviceCode;
        private set => SetField(ref _myRawDeviceCode, value);
    }

    private string _myHostTicket = "";
    public string MyHostTicket
    {
        get => _myHostTicket;
        private set => SetField(ref _myHostTicket, value);
    }

    private string _coordStatusText = "未开启被控监听";
    public string CoordStatusText
    {
        get => _coordStatusText;
        private set => SetField(ref _coordStatusText, value);
    }

    private string _hostLinkBadge = "";
    public string HostLinkBadge
    {
        get => _hostLinkBadge;
        private set => SetField(ref _hostLinkBadge, value);
    }

    private string _wanCoordUrl = "https://openuu.1kb.ren";
    public string WanCoordUrl
    {
        get => _wanCoordUrl;
        set => SetField(ref _wanCoordUrl, value);
    }

    private string _wanRelayUrl = "https://openuu-relay.1kb.ren";
    public string WanRelayUrl
    {
        get => _wanRelayUrl;
        set => SetField(ref _wanRelayUrl, value);
    }

    private string _wanRelayAuthToken = DefaultRelayToken;
    public string WanRelayAuthToken
    {
        get => _wanRelayAuthToken;
        set => SetField(ref _wanRelayAuthToken, value);
    }

    private bool _wanEnablePublicFallback = true;
    public bool WanEnablePublicFallback
    {
        get => _wanEnablePublicFallback;
        set => SetField(ref _wanEnablePublicFallback, value);
    }

    private bool _wanAllowInsecureTls;
    public bool WanAllowInsecureTls
    {
        get => _wanAllowInsecureTls;
        set => SetField(ref _wanAllowInsecureTls, value);
    }

    private string? _selectedSessionId;
    public string? SelectedSessionId
    {
        get => _selectedSessionId;
        set
        {
            if (SetField(ref _selectedSessionId, value))
                OnSessionStatsChanged();
        }
    }

    public int ConnectedHostCount => _sessions.Values.Count(s => s.IsConnected);
    public int TotalOpenRemoteWindows => _sessions.Values.Sum(s => s.OpenWindowCount);
    public bool IsAnyActive => IsHostRunning || ConnectedHostCount > 0;
    public string SidebarSummaryText => $"并发远控：{ConnectedHostCount} 台 · {TotalOpenRemoteWindows} 窗";

    private DispatcherTimer? _discoveryTimer;
    private int _presenceTickCounter;

    public event Action? StateMutated;

    public AppState(string? customConfigDir = null)
    {
        _customConfigDir = customConfigDir;
        string appDataDir = !string.IsNullOrWhiteSpace(customConfigDir)
            ? customConfigDir.Trim()
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenUU");
        Directory.CreateDirectory(appDataDir);
        _prefsPath = Path.Combine(appDataDir, "windows_prefs.json");

        LoadPrefs();

        HostBridge = new OpenUUBridge(configDir: customConfigDir);
        ProbeBridge = new OpenUUBridge(configDir: customConfigDir);
        DeviceBook = new DeviceBookStore(appDataDir);

        OpenUULogger.Shared.OnEntryAppended = entry =>
        {
            LogEntries.Add(entry);
            while (LogEntries.Count > 400)
                LogEntries.RemoveAt(0);
        };
        foreach (var existing in OpenUULogger.Shared.RecentEntries(OpenUULogLevel.Debug, 200))
            LogEntries.Add(existing);

        OpenUULogger.Shared.Info("APP", $"launched platform=windows version=v0.6.0 admin={IsRunningAsAdministrator} fps={_targetFps}");

        ProbeBridge.OnProbeResults = results =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                DeviceBook.ApplyProbeResults(results);
                StateMutated?.Invoke();
            });
        };

        SetupHostCallbacks();
        SetupSharedManagers();
    }

    private void LoadPrefs()
    {
        try
        {
            if (File.Exists(_prefsPath))
            {
                var loaded = JsonSerializer.Deserialize<UserPrefsModel>(File.ReadAllText(_prefsPath));
                if (loaded != null) _prefs = loaded;
            }
        }
        catch
        {
        }

        if (string.IsNullOrWhiteSpace(_prefs.HostPin))
            _prefs.HostPin = Random.Shared.Next(0, 1_000_000).ToString("D6");

        _hostPin = _prefs.HostPin;
        _quickConnectTarget = DeviceCodeFormatter.FormatInput(_prefs.ManualHostIp);
        _quickConnectPort = string.IsNullOrWhiteSpace(_prefs.ManualHostPort) ? "39481" : _prefs.ManualHostPort;
        _quickConnectPassword = _prefs.ClientPin;
        _silentClickMode = _prefs.SilentClick;
        _hoverCursorSync = _prefs.HoverCursor;
        _preventDisplaySleep = _prefs.PreventSleep;
        _clipboardSyncEnabled = _prefs.ClipboardSync;
        _notificationSyncEnabled = _prefs.NotificationSync;
        _remoteAudioEnabled = _prefs.RemoteAudioSync;
        _muteHostAudioDuringRemote = _prefs.MuteHostAudio;
        _dynamicResolutionBoost = _prefs.DynamicRes;
        _targetFps = _prefs.TargetFps is 30 or 45 or 60 ? _prefs.TargetFps : 45;
        _showDebugHud = _prefs.DebugHud;
        _mapCtrlToMacCommand = _prefs.MapCtrlToMacCommand;
        _captureScheme = string.IsNullOrWhiteSpace(_prefs.CaptureScheme) ? "main" : _prefs.CaptureScheme;
        SavePrefs();
    }

    private void SavePrefs()
    {
        try
        {
            File.WriteAllText(_prefsPath, JsonSerializer.Serialize(_prefs, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch
        {
        }
    }

    private static bool CheckIsAdmin()
    {
        try
        {
            using var identity = WindowsIdentity.GetCurrent();
            var principal = new WindowsPrincipal(identity);
            return principal.IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch
        {
            return false;
        }
    }

    private void SyncHostAudioPreferences()
    {
        bool effectiveEnabled = _remoteAudioEnabled && _clientRequestedAudioEnabled;
        bool effectiveMuteHost = _clientRequestedMuteHost ?? _muteHostAudioDuringRemote;
        CaptureManager.SetAudioPreferences(effectiveEnabled, effectiveMuteHost);
    }

    private void SetupHostCallbacks()
    {
        HostBridge.OnStatus = msg =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
            {
                StatusLog = $"[被控端] {msg}";
                OpenUULogger.Shared.Info("HOST", msg);

                if (msg.StartsWith("client connected:", StringComparison.OrdinalIgnoreCase))
                {
                    _clientRequestedAudioEnabled = true;
                    _clientRequestedMuteHost = null;
                    SyncHostAudioPreferences();
                    RefreshIdentitySnapshot();
                    ClipboardSync.Start();
                    PushHostAppListToClient();
                    NotificationMonitor.Start();
                    CaptureManager.RequestAllKeyframes();
                }
                else if (msg.Contains("disconnected", StringComparison.OrdinalIgnoreCase))
                {
                    _clientRequestedAudioEnabled = true;
                    _clientRequestedMuteHost = null;
                    HostLinkBadge = "";
                    CaptureManager.NetworkTier = StreamNetworkTier.Lan;
                    NotificationMonitor.Stop();
                    if (ConnectedHostCount == 0)
                        ClipboardSync.Stop();
                    StopAllHostStreams();
                }
                StateMutated?.Invoke();
            });
        };

        HostBridge.OnControlEvent = evt =>
        {
            switch (evt.Type)
            {
                case "link_quality":
                {
                    var tier = StreamNetworkTierExtensions.Parse(evt.LinkMode);
                    uint rtt = evt.RttMs ?? 0;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        CaptureManager.NetworkTier = tier;
                        HostLinkBadge = rtt > 0 ? $"{tier.GetLabel()} · {rtt}ms" : tier.GetLabel();
                        StateMutated?.Invoke();
                    });
                    break;
                }
                case "list_apps_req":
                {
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(PushHostAppListToClient);
                    break;
                }
                case "start_session":
                {
                    string bid = evt.BundleId ?? "";
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        CaptureManager.AddSharedApp(bid);
                    });
                    break;
                }
                case "stop_session":
                {
                    if (evt.WindowId is { } wid)
                    {
                        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                        {
                            CaptureManager.StopWindow(wid);
                        });
                    }
                    break;
                }
                case "request_keyframe":
                {
                    uint targetWid = evt.WindowId ?? 0;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        CaptureManager.RequestKeyframe(targetWid);
                    });
                    break;
                }
                case "audio_control":
                {
                    bool enabled = evt.AudioEnabled ?? true;
                    bool? muteHost = evt.MuteHost;
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        _clientRequestedAudioEnabled = enabled;
                        _clientRequestedMuteHost = muteHost;
                        SyncHostAudioPreferences();
                    });
                    break;
                }
                case "clipboard_sync":
                {
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        ClipboardSync.ApplyRemoteClipboard(
                            evt.ContentHash ?? "",
                            evt.ClipKind ?? 0,
                            evt.Text,
                            evt.MimeType,
                            evt.ImageB64
                        );
                    });
                    break;
                }
                case "file_drop":
                {
                    if (evt.WindowId is { } wid && !string.IsNullOrEmpty(evt.LocalPath) && File.Exists(evt.LocalPath))
                    {
                        string path = evt.LocalPath;
                        System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                        {
                            if (wid == 0)
                                EnqueueClipboardFile(path);
                            else
                                EnqueueDroppedFileForPaste(wid, path);
                        });
                    }
                    break;
                }
                default:
                    InputInjector.HandleControlEvent(evt);
                    break;
            }
        };
    }

    private void SetupSharedManagers()
    {
        CaptureManager.DynamicResolutionEnabled = _dynamicResolutionBoost;
        CaptureManager.TargetFps = _targetFps;
        CaptureManager.OnEncodedFrame = (codec, flags, wid, pts, rw, rh, data) =>
        {
            HostBridge.SendVideoFrame(codec, flags, wid, pts, rw, rh, data);
        };
        CaptureManager.OnEncodedAudio = (codec, flags, channels, sampleRate, pts, data) =>
        {
            HostBridge.SendAudioFrame(codec, flags, channels, sampleRate, pts, data);
        };
        SyncHostAudioPreferences();
        CaptureManager.OnTopologyChanged = items =>
        {
            ActiveStreamCount = items.Count;
            HostBridge.SendWindowTopology(items);
        };
        CaptureManager.OnStatus = msg =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => StatusLog = $"[被控端] {msg}");
        };

        InputInjector.SilentMode = _silentClickMode;
        InputInjector.HoverCursorSync = _hoverCursorSync;
        InputInjector.OnDebugLog = msg =>
        {
            System.Windows.Application.Current?.Dispatcher.BeginInvoke(() => StatusLog = $"[输入] {msg}");
        };
        InputInjector.OnCursorKindChanged = kind => HostBridge.SendCursorUpdate(kind);
        InputInjector.OnNormalWindowInteracted = wid => CaptureManager.NotifyWindowInteracted(wid);

        ClipboardSync.IsEnabled = _clipboardSyncEnabled;
        ClipboardSync.OnSendText = (hash, text) =>
        {
            if (IsHostRunning) HostBridge.SendClipboardText(hash, text);
            foreach (var s in _sessions.Values.Where(s => s.IsConnected))
                s.Bridge.SendClipboardText(hash, text);
        };
        ClipboardSync.OnSendImage = (hash, mime, data) =>
        {
            if (IsHostRunning) HostBridge.SendClipboardImage(hash, mime, data);
            foreach (var s in _sessions.Values.Where(s => s.IsConnected))
                s.Bridge.SendClipboardImage(hash, mime, data);
        };
        ClipboardSync.OnSendFiles = paths =>
        {
            foreach (var p in paths)
            {
                if (IsHostRunning) HostBridge.SendFileBlob(0, 0, 0, p);
                foreach (var s in _sessions.Values.Where(s => s.IsConnected))
                    s.Bridge.SendFileBlob(0, 0, 0, p);
            }
            StatusLog = $"[剪贴板] 正在向已连接设备同步 {paths.Count} 个文件...";
        };
        ClipboardSync.OnStatusLog = msg => StatusLog = $"[剪贴板] {msg}";

        NotificationMonitor.SetEnabled(_notificationSyncEnabled);
        ClientNotificationManager.IsEnabled = _notificationSyncEnabled;
        NotificationMonitor.OnNotification = (bid, title, sub, body) =>
            HostBridge.SendNotification(bid, title, sub, body);
        NotificationMonitor.OnBadgeChanged = (bid, badge) =>
            HostBridge.SendBadgeUpdate(bid, badge);
        ClientNotificationManager.OnNotificationClicked = HandleNotificationFocus;
    }

    // ========================================================================
    // Multi-Host Session Orchestration
    // ========================================================================

    public WanConfigModel CurrentWanConfigModel() => new()
    {
        CoordUrl = WanCoordUrl.Trim(),
        RelayUrl = WanRelayUrl.Trim(),
        RelayAuthToken = WanRelayAuthToken.Trim(),
        EnablePublicFallback = WanEnablePublicFallback,
        AllowInsecureTls = WanAllowInsecureTls
    };

    public RemotePeerSession? GetSession(string deviceId)
        => _sessions.TryGetValue(deviceId, out var s) ? s : null;

    public RemotePeerSession ConnectDevice(ManagedRemoteDevice device, bool autoOpenDesktop = false)
    {
        string cleanTarget = DeviceCodeFormatter.SanitizeForUse(device.Target);
        var sess = EnsureSession(device);
        sess.Alias = device.Alias;
        sess.Target = cleanTarget;
        sess.Port = device.Port;
        sess.Bridge.SetWanConfig(CurrentWanConfigModel());
        SelectedSessionId = sess.Id;

        string typedPw = QuickConnectPassword.Trim();
        bool sameTarget = DeviceBook.FindMatchingDevice(QuickConnectTarget)?.Id == device.Id;
        string password;
        if (sameTarget && !string.IsNullOrEmpty(typedPw) && typedPw != device.SavedPassword)
        {
            password = typedPw;
            DeviceBook.AddOrUpdateDevice(
                id: device.Id,
                alias: device.Alias,
                target: cleanTarget,
                port: device.Port,
                savedPassword: password,
                groupTag: device.GroupTag,
                isFavorite: device.IsFavorite,
                notes: device.Notes
            );
        }
        else
        {
            password = string.IsNullOrEmpty(device.SavedPassword) ? typedPw : device.SavedPassword;
        }

        sess.Connect(password, autoOpenDesktop);
        RefreshConnectedSessionsList();
        return sess;
    }

    public RemotePeerSession? ConnectFromQuickInput(bool autoOpenDesktop = false)
    {
        string rawTarget = DeviceCodeFormatter.SanitizeForUse(QuickConnectTarget);
        if (string.IsNullOrEmpty(rawTarget))
        {
            StatusLog = "请输入伙伴 9 位设备代码、openuu:// 连接串或 IP/域名";
            return null;
        }
        ushort port = ushort.TryParse(QuickConnectPort.Trim(), out ushort p) && p > 0 ? p : (ushort)39481;
        var matched = DeviceBook.FindMatchingDevice(rawTarget);
        string typedPw = QuickConnectPassword.Trim();
        string password = !string.IsNullOrEmpty(typedPw) ? typedPw : (matched?.SavedPassword ?? "");

        var device = DeviceBook.AddOrUpdateDevice(
            id: matched?.Id,
            alias: matched?.Alias ?? "",
            target: rawTarget,
            port: port,
            savedPassword: password,
            groupTag: matched?.GroupTag ?? "常用",
            isFavorite: matched?.IsFavorite ?? false,
            notes: matched?.Notes ?? ""
        );

        var sess = EnsureSession(device);
        sess.Target = rawTarget;
        sess.Port = port;
        sess.Bridge.SetWanConfig(CurrentWanConfigModel());
        SelectedSessionId = sess.Id;
        sess.Connect(password, autoOpenDesktop);
        RefreshConnectedSessionsList();
        return sess;
    }

    public void ConnectDiscoveredPeer(DiscoveredPeer peer, bool autoOpenDesktop = false)
    {
        string target = peer.PreferredIp;
        QuickConnectTarget = target;
        QuickConnectPort = peer.Port.ToString();
        var matched = DeviceBook.Devices.FirstOrDefault(d =>
            d.RemoteDeviceId == peer.DeviceId || d.Target == target);
        string pw = matched != null && !string.IsNullOrEmpty(matched.SavedPassword)
            ? matched.SavedPassword
            : QuickConnectPassword;

        var dev = DeviceBook.AddOrUpdateDevice(
            id: matched?.Id,
            alias: matched?.Alias ?? peer.DeviceName,
            target: target,
            port: peer.Port,
            savedPassword: pw
        );
        ConnectDevice(dev, autoOpenDesktop);
    }

    public void DisconnectSession(string id)
    {
        if (!_sessions.TryGetValue(id, out var sess)) return;
        sess.Disconnect();
        RefreshConnectedSessionsList();
        if (SelectedSessionId == id)
            SelectedSessionId = ConnectedSessions.FirstOrDefault()?.Id;
        if (ConnectedHostCount == 0 && !IsHostRunning)
            ClipboardSync.Stop();
        OnSessionStatsChanged();
    }

    public void DisconnectAllClientSessions()
    {
        foreach (var s in _sessions.Values.Where(s => s.IsConnected || s.IsConnecting))
            s.Disconnect();
        SelectedSessionId = null;
        RefreshConnectedSessionsList();
        if (!IsHostRunning)
            ClipboardSync.Stop();
        StatusLog = "已断开所有远程控制连接";
        OnSessionStatsChanged();
    }

    public void DeleteManagedDevice(ManagedRemoteDevice device)
    {
        if (_sessions.Remove(device.Id, out var sess))
            sess.Dispose();
        _activeSessionOrder.Remove(device.Id);
        if (!string.IsNullOrEmpty(device.RemoteDeviceId))
        {
            HostBridge.RemoveTrustedPeer(device.RemoteDeviceId);
            ProbeBridge.RemoveTrustedPeer(device.RemoteDeviceId);
        }
        DeviceBook.RemoveDevice(device.Id);
        RefreshConnectedSessionsList();
        if (SelectedSessionId == device.Id)
            SelectedSessionId = ConnectedSessions.FirstOrDefault()?.Id;
        StatusLog = $"已从设备列表删除: {device.Alias}";
        OnSessionStatsChanged();
    }

    private RemotePeerSession EnsureSession(ManagedRemoteDevice device)
    {
        if (_sessions.TryGetValue(device.Id, out var existing))
        {
            if (!_activeSessionOrder.Contains(device.Id))
                _activeSessionOrder.Insert(0, device.Id);
            return existing;
        }

        _nextSessionIndex++;
        var sess = new RemotePeerSession(
            device.Id,
            _nextSessionIndex,
            device.Alias,
            device.Target,
            device.Port,
            CurrentWanConfigModel(),
            _customConfigDir
        )
        {
            ShowDebugHud = _showDebugHud,
            MapCtrlToMacCommandPref = _mapCtrlToMacCommand
        };

        sess.OnStateMutated = () =>
        {
            RefreshConnectedSessionsList();
            OnSessionStatsChanged();
        };
        sess.OnStatusLog = msg => StatusLog = msg;
        sess.OnConnected = (connectedSess, remoteName, remoteDevId) =>
        {
            ClipboardSync.Start();
            var saved = DeviceBook.RecordConnectedHost(
                connectedSess.Id,
                remoteName,
                remoteDevId,
                connectedSess.Target,
                connectedSess.Port,
                QuickConnectPassword
            );
            connectedSess.Alias = saved.Alias;
            SelectedSessionId = connectedSess.Id;
            RefreshIdentitySnapshot();
            RefreshConnectedSessionsList();
            OnSessionStatsChanged();
        };
        sess.OnRemoteClipboard = (hash, kind, text, mime, imgB64) =>
        {
            ClipboardSync.ApplyRemoteClipboard(hash, kind, text, mime, imgB64);
        };
        sess.OnRemoteClipboardFile = EnqueueClipboardFile;
        sess.OnBeforePasteShortcut = () => ClipboardSync.SyncNowIfChanged();
        sess.OnPresentNotification = (srcSess, bid, appTitle, title, sub, body, icon) =>
        {
            ClientNotificationManager.PresentRemoteNotification(
                srcSess.CompositeKey(bid),
                appTitle,
                title,
                sub,
                body,
                icon
            );
        };

        _sessions[device.Id] = sess;
        _activeSessionOrder.Insert(0, device.Id);
        return sess;
    }

    private void RefreshConnectedSessionsList()
    {
        var desired = _activeSessionOrder
            .Where(id => _sessions.TryGetValue(id, out var s) && (s.IsConnected || s.IsConnecting))
            .Select(id => _sessions[id])
            .ToList();

        if (!desired.SequenceEqual(ConnectedSessions))
        {
            ConnectedSessions.Clear();
            foreach (var s in desired)
                ConnectedSessions.Add(s);
        }
    }

    private void OnSessionStatsChanged()
    {
        OnPropertyChanged(nameof(ConnectedHostCount));
        OnPropertyChanged(nameof(TotalOpenRemoteWindows));
        OnPropertyChanged(nameof(IsAnyActive));
        OnPropertyChanged(nameof(SidebarSummaryText));
        StateMutated?.Invoke();
    }

    private void HandleNotificationFocus(string compositeKey)
    {
        var parts = compositeKey.Split("::", 2, StringSplitOptions.None);
        if (parts.Length == 2 && _sessions.TryGetValue(parts[0], out var sess))
        {
            string subKey = parts[1];
            var app = sess.RemoteApps.FirstOrDefault(a => string.Equals(a.BundleId, subKey, StringComparison.OrdinalIgnoreCase));
            sess.FocusWindows(subKey);
            if (sess.OpenWindowCount == 0 && app != null)
                sess.OpenApp(app);
        }
    }

    // ========================================================================
    // Host Service, Discovery & Identity Management
    // ========================================================================

    public void RefreshIdentitySnapshot(bool syncWanFields = false)
    {
        var snap = HostBridge.GetIdentitySnapshot();
        if (snap == null) return;

        MyFormattedDeviceCode = snap.FormattedCode;
        MyRawDeviceCode = snap.DeviceCode;
        MyHostTicket = snap.HostTicket;
        if (IsHostRunning && !string.IsNullOrEmpty(snap.CoordStatus))
            CoordStatusText = snap.CoordStatus;

        var merged = new Dictionary<string, TrustedPeerModel>();
        foreach (var p in snap.TrustedPeers)
            merged[p.DeviceId] = p;
        foreach (var s in _sessions.Values)
        {
            var sSnap = s.Bridge.GetIdentitySnapshot();
            if (sSnap == null) continue;
            foreach (var p in sSnap.TrustedPeers)
            {
                if (!merged.TryGetValue(p.DeviceId, out var ex) || p.LastConnectedMs >= ex.LastConnectedMs)
                    merged[p.DeviceId] = p;
            }
        }

        var sortedTrusted = merged.Values.OrderByDescending(p => p.LastConnectedMs).ToList();
        TrustedPeers.Clear();
        foreach (var tp in sortedTrusted)
            TrustedPeers.Add(tp);
        DeviceBook.SyncFromTrustedPeers(sortedTrusted);

        if (syncWanFields)
        {
            WanCoordUrl = snap.WanConfig.CoordUrl;
            WanRelayUrl = snap.WanConfig.RelayUrl;
            WanRelayAuthToken = snap.WanConfig.RelayAuthToken ?? "";
            WanEnablePublicFallback = snap.WanConfig.EnablePublicFallback;
            WanAllowInsecureTls = snap.WanConfig.AllowInsecureTls;
        }
    }

    public void ProbeAllSavedDevicesNow()
    {
        var queries = DeviceBook.Devices.Select(d =>
        {
            var matchedTrusted = TrustedPeers.FirstOrDefault(tp =>
                (!string.IsNullOrEmpty(d.RemoteDeviceId) && tp.DeviceId == d.RemoteDeviceId) ||
                (!string.IsNullOrEmpty(d.DeviceCode) && tp.DeviceCode == d.DeviceCode));
            return new DeviceProbeQueryModel
            {
                Id = d.Id,
                Target = DeviceCodeFormatter.SanitizeForUse(d.Target),
                Pin = d.SavedPassword,
                EndpointId = matchedTrusted?.EndpointId ?? ""
            };
        }).ToList();

        if (queries.Count == 0) return;
        ProbeBridge.SetWanConfig(CurrentWanConfigModel());
        ProbeBridge.ProbeDevicesOnline(queries);
    }

    public void SaveWanSettings()
    {
        var cfg = CurrentWanConfigModel();
        HostBridge.SetWanConfig(cfg);
        ProbeBridge.SetWanConfig(cfg);
        foreach (var s in _sessions.Values)
            s.Bridge.SetWanConfig(cfg);
        RefreshIdentitySnapshot(syncWanFields: true);
        ProbeAllSavedDevicesNow();
        StatusLog = IsHostRunning
            ? "[网络] 已保存跨网配置（重启被控服务后将向新服务器注册本机设备码）"
            : "[网络] 已保存跨网打洞与中继配置";
    }

    public void RegenerateHostPin(bool strong = false)
    {
        HostPin = HostBridge.GenerateAccessCode(strong);
        OnPropertyChanged(nameof(MaskedHostPin));
    }

    public void ToggleHostService()
    {
        if (IsHostRunning)
            StopHostService();
        else
            StartHost();
    }

    public bool StartHost()
    {
        string preferred = HostPin.Trim();
        HostBridge.SetWanConfig(CurrentWanConfigModel());
        var res = HostBridge.StartHost(HostPort, string.IsNullOrEmpty(preferred) ? null : preferred);
        if (res == null)
        {
            StatusLog = "启动本机被控服务失败（请检查端口是否占用）";
            return false;
        }
        HostPort = res.Value.BoundPort;
        HostPin = res.Value.Pin;
        OnPropertyChanged(nameof(MaskedHostPin));
        IsHostRunning = true;
        if (_preventDisplaySleep)
            SleepPreventer.SetEnabled(true);
        RefreshIdentitySnapshot();
        StateMutated?.Invoke();
        return true;
    }

    public void StopHostService()
    {
        CaptureManager.StopAll();
        ActiveStreamCount = 0;
        HostLinkBadge = "";
        CaptureManager.NetworkTier = StreamNetworkTier.Lan;
        HostBridge.StopHost();
        SleepPreventer.SetEnabled(false);
        IsHostRunning = false;
        CoordStatusText = "未开启被控监听";
        StatusLog = "[被控端] 已停止本机被控监听";
        StateMutated?.Invoke();
    }

    public void StopAllHostStreams()
    {
        CaptureManager.StopAll();
        ActiveStreamCount = 0;
        HostBridge.SendWindowTopology(Array.Empty<WindowTopologyItem>());
        StatusLog = "[被控端] 已停止所有正在共享的画面";
    }

    public void StartDiscovery()
    {
        RefreshIdentitySnapshot(syncWanFields: true);
        ProbeBridge.StartDiscovery();
        ProbeAllSavedDevicesNow();

        _discoveryTimer?.Stop();
        _discoveryTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromSeconds(2.0)
        };
        _discoveryTimer.Tick += (_, _) =>
        {
            var peers = ProbeBridge.ListPeers();
            DiscoveredPeers.Clear();
            foreach (var p in peers)
                DiscoveredPeers.Add(p);

            if (IsHostRunning)
                RefreshIdentitySnapshot(syncWanFields: false);

            _presenceTickCounter++;
            if (_presenceTickCounter % 60 == 0)
            {
                ProbeAllSavedDevicesNow();
            }
            StateMutated?.Invoke();
        };
        _discoveryTimer.Start();
    }

    public void RevokeTrustedPeer(TrustedPeerModel peer)
    {
        HostBridge.RemoveTrustedPeer(peer.DeviceId);
        ProbeBridge.RemoveTrustedPeer(peer.DeviceId);
        foreach (var s in _sessions.Values)
            s.Bridge.RemoveTrustedPeer(peer.DeviceId);
        RefreshIdentitySnapshot();
        StatusLog = $"已撤销信任授权: {peer.DeviceName}";
        StateMutated?.Invoke();
    }

    private void PushHostAppListToClient()
    {
        try
        {
            var apps = WindowCatalog.BuildHostAppSummaries();
            NotificationMonitor.UpdateWatchedApps(
                apps.Where(a => a.BundleId != MultiWindowCaptureManager.FullDesktopBundleId)
                    .Select(a => (a.BundleId, a.Name))
            );
            HostBridge.SendAppList(apps);
        }
        catch (Exception ex)
        {
            StatusLog = $"[被控端] 获取应用列表失败: {ex.Message}";
        }
    }

    private void EnqueueClipboardFile(string filePath)
    {
        const uint key = 0;
        if (!_pendingDroppedFiles.TryGetValue(key, out var list))
        {
            list = new List<string>();
            _pendingDroppedFiles[key] = list;
        }
        list.Add(filePath);

        if (_pendingDropCts.Remove(key, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        _pendingDropCts[key] = cts;
        var ct = cts.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(140, ct);
                System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                {
                    _pendingDropCts.Remove(key);
                    if (_pendingDroppedFiles.Remove(key, out var files) && files.Count > 0)
                        ClipboardSync.ApplyRemoteClipboardFiles(files);
                });
            }
            catch
            {
            }
        }, ct);
    }

    private void EnqueueDroppedFileForPaste(uint windowId, string filePath)
    {
        if (!_pendingDroppedFiles.TryGetValue(windowId, out var list))
        {
            list = new List<string>();
            _pendingDroppedFiles[windowId] = list;
        }
        list.Add(filePath);

        if (_pendingDropCts.Remove(windowId, out var old)) old.Cancel();
        var cts = new CancellationTokenSource();
        _pendingDropCts[windowId] = cts;
        var ct = cts.Token;

        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(140, ct);
                System.Windows.Application.Current?.Dispatcher.Invoke(() =>
                {
                    _pendingDropCts.Remove(windowId);
                    if (!_pendingDroppedFiles.Remove(windowId, out var files) || files.Count == 0)
                        return;

                    ClipboardSync.ApplyRemoteClipboardFiles(files);
                    InputInjector.PasteDroppedFiles(windowId, files);
                    StatusLog = $"[被控端] 已接收并粘贴 {files.Count} 个拖入文件";
                });
            }
            catch
            {
            }
        }, ct);
    }

    // ========================================================================
    // Clipboard Helpers & Diagnostics
    // ========================================================================

    public void CopyTextWithoutSyncEcho(string text, string statusMessage)
    {
        try
        {
            System.Windows.Forms.Clipboard.SetText(text, System.Windows.Forms.TextDataFormat.UnicodeText);
            ClipboardSync.IgnoreCurrentClipboardChange();
            StatusLog = statusMessage;
        }
        catch
        {
        }
    }

    public void CopyMyDeviceCode()
        => CopyTextWithoutSyncEcho(MyFormattedDeviceCode, $"已复制本机设备代码: {MyFormattedDeviceCode}");

    public void CopyInvitationBundle()
    {
        string invite = $"【OpenUU 远程协助】\n设备代码：{MyFormattedDeviceCode}\n访问密码：{HostPin}";
        CopyTextWithoutSyncEcho(invite, "已复制本机设备代码与访问密码，可直接发送给伙伴");
    }

    public void CopyMyHostTicket()
    {
        RefreshIdentitySnapshot();
        if (string.IsNullOrEmpty(MyHostTicket))
        {
            StatusLog = "请先开启「允许控制本机」并等待 2 秒生成跨网连接串";
            return;
        }
        CopyTextWithoutSyncEcho(MyHostTicket, "已复制 openuu:// 免寻址跨网连接串");
    }

    public void CopyDiagnosticLogs()
    {
        string connDesc = string.Join(",", ConnectedSessions.Select(s => $"{s.Alias}({s.OpenWindowCount}w)"));
        var roles = new List<string>();
        if (IsHostRunning) roles.Add($"Host(port={HostPort}, streams={ActiveStreamCount})");
        if (!string.IsNullOrEmpty(connDesc)) roles.Add($"MultiClient[{connDesc}]");
        string role = roles.Count > 0 ? string.Join(" + ", roles) : "Idle";
        string caps = $"Admin={IsRunningAsAdministrator}, Silent={SilentClickMode}, DynRes={DynamicResolutionBoost}";
        string snap = $"savedDevices={DeviceBook.Devices.Count} activeSessions={ConnectedHostCount} totalWindows={TotalOpenRemoteWindows}";

        string report = OpenUULogger.Shared.BuildDiagnosticReport(
            "v0.6.0-windows",
            role,
            CaptureScheme,
            caps,
            snap,
            SelectedLogLevel
        );
        CopyTextWithoutSyncEcho(report, "[日志] 已复制诊断日志到剪贴板");
    }

    public void RevealLogDirectoryInExplorer()
    {
        try
        {
            if (File.Exists(OpenUULogger.Shared.LogFilePath))
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{OpenUULogger.Shared.LogFilePath}\"")
                {
                    UseShellExecute = true
                });
            }
            else
            {
                Process.Start(new ProcessStartInfo("explorer.exe", $"\"{OpenUULogger.Shared.LogDirectoryPath}\"")
                {
                    UseShellExecute = true
                });
            }
        }
        catch
        {
        }
    }

    public void ClearDiagnosticLogs()
    {
        OpenUULogger.Shared.Clear();
        LogEntries.Clear();
        StatusLog = "[日志] 已清空诊断日志";
    }

    public void RelaunchAsAdministrator()
    {
        string? exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe) || !File.Exists(exe)) return;
        try
        {
            Process.Start(new ProcessStartInfo(exe)
            {
                UseShellExecute = true,
                Verb = "runas"
            });
            System.Windows.Application.Current?.Shutdown();
        }
        catch
        {
            StatusLog = "已取消管理员提权重启";
        }
    }

    public void Dispose()
    {
        _discoveryTimer?.Stop();
        ClipboardSync.Stop();
        NotificationMonitor.Dispose();
        ClientNotificationManager.Dispose();
        CaptureManager.AudioStreamer.Dispose();
        CaptureManager.Dispose();
        InputInjector.Dispose();
        SleepPreventer.Dispose();

        foreach (var s in _sessions.Values)
            s.Dispose();
        _sessions.Clear();

        HostBridge.Dispose();
        ProbeBridge.Dispose();
    }
}

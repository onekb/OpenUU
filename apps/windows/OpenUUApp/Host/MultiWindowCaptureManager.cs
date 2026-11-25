using System.Windows.Threading;

namespace OpenUU.Host;

using OpenUU.Shared;

/// <summary>
/// Tracks ALL normal windows (<c>kind=0/1</c>) and floating popups/menus (<c>kind=2</c>) across one or more
/// shared Windows applications, plus optional Full Remote Desktop mode (<c>__openuu_full_desktop__</c>).
/// Windows counterpart to macOS <c>MultiWindowCaptureManager</c>.
/// </summary>
public sealed class MultiWindowCaptureManager : IDisposable
{
    public const string FullDesktopBundleId = "__openuu_full_desktop__";
    public const uint FullDesktopWindowId = 0x7FFF_FF00;

    private sealed class SuppressedWindowState
    {
        public string AppId { get; init; } = "";
        public bool SeenBehindActiveWindow { get; set; }
        public float LastX { get; set; }
        public float LastY { get; set; }
        public float LastW { get; set; }
        public float LastH { get; set; }
        public string LastTitle { get; set; } = "";
        public ulong SuppressedAtInteractionSeq { get; init; }
    }

    private readonly HashSet<string> _sharedAppIds = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<uint> _sharedPids = new();
    private readonly Dictionary<string, uint> _primaryWindowByApp = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<uint, SuppressedWindowState> _suppressedWindows = new();
    private readonly Dictionary<uint, ScreenCaptureEngine> _engines = new();
    private readonly Dictionary<uint, string> _windowIconCache = new();
    private List<ShareableWindowItem> _lastTrackedWindows = new();
    private List<WindowTopologyItem> _lastTopology = new();

    private bool _isSharingFullDesktop;
    private (int W, int H) _fullDesktopLogicalSize = (1920, 1080);
    private DispatcherTimer? _pollTimer;
    private CancellationTokenSource? _fastSyncCts;
    private ulong _interactionSeq;

    private bool _dynamicResolutionEnabled = true;
    private int _targetFps = 45;
    private StreamNetworkTier _networkTier = StreamNetworkTier.Lan;

    public HostAudioStreamer AudioStreamer { get; } = new();
    public ScreenCaptureEngine.EncodedFrameHandler? OnEncodedFrame { get; set; }
    public HostAudioStreamer.EncodedAudioHandler? OnEncodedAudio
    {
        get => AudioStreamer.OnEncodedAudio;
        set => AudioStreamer.OnEncodedAudio = value;
    }
    public Action<IReadOnlyList<WindowTopologyItem>>? OnTopologyChanged { get; set; }
    public Action<string>? OnStatus { get; set; }

    public int ActiveStreamCount => _engines.Count;

    public void SetAudioPreferences(bool enabled, bool muteHost)
    {
        AudioStreamer.UpdatePreferences(enabled, muteHost);
    }

    public bool DynamicResolutionEnabled
    {
        get => _dynamicResolutionEnabled;
        set
        {
            _dynamicResolutionEnabled = value;
            foreach (var eng in _engines.Values)
                eng.DynamicResolutionEnabled = value;
        }
    }

    public int TargetFps
    {
        get => _targetFps;
        set
        {
            _targetFps = value;
            foreach (var eng in _engines.Values)
                eng.SetTargetFps(value);
        }
    }

    public StreamNetworkTier NetworkTier
    {
        get => _networkTier;
        set
        {
            if (_networkTier == value) return;
            _networkTier = value;
            AudioStreamer.SetNetworkTier(value);
            foreach (var eng in _engines.Values)
                eng.NetworkTier = value;
        }
    }

    public void AddSharedApp(string appId)
    {
        if (string.IsNullOrWhiteSpace(appId)) return;
        if (appId == FullDesktopBundleId)
        {
            StartFullDesktopSharing();
            return;
        }

        foreach (var k in _suppressedWindows.Where(kv => kv.Value.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase)).Select(kv => kv.Key).ToList())
        {
            _suppressedWindows.Remove(k);
        }
        _sharedAppIds.Add(appId);

        // Restore minimized windows of the target app so PrintWindow(PW_RENDERFULLCONTENT) has an active DWM surface
        var allNormal = WindowCatalog.FetchNormalWindows();
        foreach (var w in allNormal.Where(w => w.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase)))
        {
            _sharedPids.Add(w.Pid);
            if (Win32Interop.IsIconic(w.Hwnd))
            {
                Win32Interop.ShowWindow(w.Hwnd, Win32Interop.SW_RESTORE);
            }
        }

        SyncAppWindows(forcePublish: true);
        EnsurePolling();
    }

    private void StartFullDesktopSharing()
    {
        if (_engines.Remove(FullDesktopWindowId, out var old))
            old.Dispose();

        var eng = new ScreenCaptureEngine
        {
            DynamicResolutionEnabled = _dynamicResolutionEnabled,
            NetworkTier = _networkTier,
            OnEncodedFrame = (codec, flags, wid, pts, rw, rh, data) =>
                OnEncodedFrame?.Invoke(codec, flags, wid, pts, rw, rh, data)
        };
        _fullDesktopLogicalSize = eng.StartDesktopCapture(FullDesktopWindowId, _targetFps);
        _isSharingFullDesktop = true;
        _engines[FullDesktopWindowId] = eng;
        PublishTopology(_lastTrackedWindows, force: true);
        OpenUULogger.Shared.Info("CAPTURE", $"started full_desktop res={_fullDesktopLogicalSize.W}x{_fullDesktopLogicalSize.H} fps={_targetFps}");
        OnStatus?.Invoke($"开始传输整台电脑桌面 ({_fullDesktopLogicalSize.W}×{_fullDesktopLogicalSize.H})");
    }

    public void StopWindow(uint windowId)
    {
        if (windowId == FullDesktopWindowId)
        {
            _isSharingFullDesktop = false;
            if (_engines.Remove(FullDesktopWindowId, out var dEng))
                dEng.Dispose();
            PublishTopology(_lastTrackedWindows, force: true);
            OnStatus?.Invoke("已停止整台电脑桌面传输");
            return;
        }

        var stoppedWin = _lastTrackedWindows.FirstOrDefault(w => w.WindowId == windowId);
        string stoppedAppId = stoppedWin?.AppId ?? "";
        if (!string.IsNullOrEmpty(stoppedAppId))
        {
            _suppressedWindows[windowId] = new SuppressedWindowState
            {
                AppId = stoppedAppId,
                SeenBehindActiveWindow = false,
                LastX = stoppedWin?.LogicalX ?? 0,
                LastY = stoppedWin?.LogicalY ?? 0,
                LastW = stoppedWin?.LogicalWidth ?? 0,
                LastH = stoppedWin?.LogicalHeight ?? 0,
                LastTitle = stoppedWin?.Title ?? "",
                SuppressedAtInteractionSeq = _interactionSeq
            };
        }

        if (_engines.Remove(windowId, out var eng))
            eng.Dispose();
        _windowIconCache.Remove(windowId);

        var stoppedApps = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var kv in _primaryWindowByApp.Where(kv => kv.Value == windowId))
            stoppedApps.Add(kv.Key);

        if (stoppedWin is { IsPopup: false } && !string.IsNullOrEmpty(stoppedAppId))
        {
            bool hasOtherNormal = _lastTrackedWindows.Any(w =>
                w.WindowId != windowId &&
                !w.IsPopup &&
                w.AppId.Equals(stoppedAppId, StringComparison.OrdinalIgnoreCase));
            if (!hasOtherNormal)
                stoppedApps.Add(stoppedAppId);
        }

        foreach (var appId in stoppedApps)
        {
            _primaryWindowByApp.Remove(appId);
            _sharedAppIds.Remove(appId);
            foreach (var k in _suppressedWindows.Where(kv => kv.Value.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase)).Select(kv => kv.Key).ToList())
                _suppressedWindows.Remove(k);

            foreach (var w in _lastTrackedWindows.Where(w => w.AppId.Equals(appId, StringComparison.OrdinalIgnoreCase)))
            {
                if (_engines.Remove(w.WindowId, out var subEng))
                    subEng.Dispose();
                _windowIconCache.Remove(w.WindowId);
                _sharedPids.Remove(w.Pid);
            }
        }

        if (_sharedAppIds.Count == 0)
        {
            _pollTimer?.Stop();
            _pollTimer = null;
            _lastTrackedWindows.Clear();
            _sharedPids.Clear();
            PublishTopology(Array.Empty<ShareableWindowItem>(), force: true);
        }
        else
        {
            SyncAppWindows(forcePublish: true);
        }
    }

    public void RequestAllKeyframes() => RequestKeyframe(0);

    public void RequestKeyframe(uint windowId)
    {
        if (windowId != 0 && _engines.TryGetValue(windowId, out var targeted))
        {
            targeted.RequestKeyframe();
            return;
        }
        foreach (var eng in _engines.Values)
            eng.RequestKeyframe();
        if (_lastTopology.Count > 0)
            OnTopologyChanged?.Invoke(_lastTopology);
    }

    public void NotifyWindowInteracted(uint windowId)
    {
        if (windowId != 0)
            _interactionSeq++;
        _fastSyncCts?.Cancel();
        _fastSyncCts = new CancellationTokenSource();
        var ct = _fastSyncCts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(110, ct);
                System.Windows.Application.Current?.Dispatcher.Invoke(() => SyncAppWindows(forcePublish: false));
            }
            catch
            {
            }
        }, ct);
    }

    public void StopAll()
    {
        _pollTimer?.Stop();
        _pollTimer = null;
        _fastSyncCts?.Cancel();
        _fastSyncCts = null;

        AudioStreamer.Stop();
        foreach (var eng in _engines.Values)
            eng.Dispose();
        _engines.Clear();
        _windowIconCache.Clear();
        _lastTrackedWindows.Clear();
        _sharedAppIds.Clear();
        _sharedPids.Clear();
        _primaryWindowByApp.Clear();
        _suppressedWindows.Clear();
        _isSharingFullDesktop = false;
        _lastTopology.Clear();
    }

    public void Dispose() => StopAll();

    private void EnsurePolling()
    {
        if (_pollTimer != null) return;
        _pollTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(650)
        };
        _pollTimer.Tick += (_, _) => SyncAppWindows(forcePublish: false);
        _pollTimer.Start();
    }

    public void SyncAppWindows(bool forcePublish)
    {
        if (_sharedAppIds.Count == 0)
        {
            PublishTopology(Array.Empty<ShareableWindowItem>(), force: forcePublish);
            return;
        }

        var rawCandidates = WindowCatalog.FetchTrackedWindows(_sharedAppIds, _sharedPids);
        foreach (var w in rawCandidates.Where(w => _sharedAppIds.Contains(w.AppId)))
            _sharedPids.Add(w.Pid);

        // Handle unsuppression if a previously closed secondary window changed title/size or jumped to front Z-order
        var activeRawIds = rawCandidates.Select(w => w.WindowId).ToHashSet();
        foreach (var k in _suppressedWindows.Keys.Where(k => !activeRawIds.Contains(k)).ToList())
            _suppressedWindows.Remove(k);

        if (_suppressedWindows.Count > 0)
        {
            var zRank = new Dictionary<uint, int>();
            for (int i = 0; i < rawCandidates.Count; i++)
            {
                if (!rawCandidates[i].IsPopup)
                    zRank[rawCandidates[i].WindowId] = i;
            }

            IntPtr fgHwnd = Win32Interop.GetForegroundWindow();
            foreach (var w in rawCandidates)
            {
                if (!_suppressedWindows.TryGetValue(w.WindowId, out var st))
                    continue;
                bool geomChanged = MathF.Abs(w.LogicalWidth - st.LastW) > 3f ||
                                   MathF.Abs(w.LogicalHeight - st.LastH) > 3f ||
                                   MathF.Abs(w.LogicalX - st.LastX) > 3f ||
                                   MathF.Abs(w.LogicalY - st.LastY) > 3f;
                bool titleChanged = !string.IsNullOrEmpty(w.Title) && w.Title != st.LastTitle;
                bool refocusedAfterClick = _interactionSeq > st.SuppressedAtInteractionSeq && fgHwnd != IntPtr.Zero && w.Hwnd == fgHwnd;
                if (geomChanged || titleChanged || refocusedAfterClick)
                {
                    _suppressedWindows.Remove(w.WindowId);
                    continue;
                }
                if (!w.IsPopup && zRank.TryGetValue(w.WindowId, out int myRank))
                {
                    int minActive = rawCandidates
                        .Where(o => !o.IsPopup && !_suppressedWindows.ContainsKey(o.WindowId) && o.AppId == w.AppId && zRank.ContainsKey(o.WindowId))
                        .Select(o => zRank[o.WindowId])
                        .DefaultIfEmpty(int.MaxValue)
                        .Min();
                    if (myRank > minActive)
                        st.SeenBehindActiveWindow = true;
                    else if (st.SeenBehindActiveWindow)
                        _suppressedWindows.Remove(w.WindowId);
                }
            }
        }

        var appWindows = rawCandidates.Where(w => !_suppressedWindows.ContainsKey(w.WindowId)).ToList();

        foreach (var appGroup in appWindows.Where(w => !w.IsPopup).GroupBy(w => w.AppId, StringComparer.OrdinalIgnoreCase))
        {
            if (!_primaryWindowByApp.ContainsKey(appGroup.Key))
            {
                var preferred = PickPreferredPrimaryWindow(appGroup.ToList());
                if (preferred != null)
                    _primaryWindowByApp[appGroup.Key] = preferred.WindowId;
            }
        }
        // Clean up stale primary window references if closed
        var liveNormalIds = appWindows.Where(w => !w.IsPopup).Select(w => w.WindowId).ToHashSet();
        foreach (var kv in _primaryWindowByApp.ToList())
        {
            if (!liveNormalIds.Contains(kv.Value))
            {
                var candidates = appWindows.Where(w => !w.IsPopup && w.AppId.Equals(kv.Key, StringComparison.OrdinalIgnoreCase)).ToList();
                var replacement = PickPreferredPrimaryWindow(candidates);
                if (replacement != null)
                    _primaryWindowByApp[kv.Key] = replacement.WindowId;
                else
                    _primaryWindowByApp.Remove(kv.Key);
            }
        }

        var currentIds = appWindows.Select(w => w.WindowId).ToHashSet();
        var trackedIds = _engines.Keys.Where(id => id != FullDesktopWindowId).ToList();

        foreach (var closedId in trackedIds.Where(id => !currentIds.Contains(id)))
        {
            if (_engines.Remove(closedId, out var eng))
                eng.Dispose();
            _windowIconCache.Remove(closedId);
        }

        foreach (var w in appWindows.Where(w => !w.IsPopup && !_windowIconCache.ContainsKey(w.WindowId)))
        {
            string b64 = IconCompositor.ExtractWindowOrExeIconBase64(
                w.Hwnd,
                w.ExePath,
                w.ExplicitIconPath,
                w.DiscoveredIconPath,
                w.IsGenericRuntime,
                w.AppName
            );
            if (!string.IsNullOrEmpty(b64))
                _windowIconCache[w.WindowId] = b64;
        }

        _lastTrackedWindows = appWindows;
        PublishTopology(appWindows, force: forcePublish);

        bool startedAny = false;
        foreach (var w in appWindows)
        {
            if (_engines.TryGetValue(w.WindowId, out var existingEng))
            {
                existingEng.UpdateWindowLogicalSize(
                    w.LogicalWidth,
                    w.LogicalHeight,
                    w.PhysicalBounds.Width,
                    w.PhysicalBounds.Height
                );
                continue;
            }

            var newEng = new ScreenCaptureEngine
            {
                DynamicResolutionEnabled = _dynamicResolutionEnabled,
                NetworkTier = _networkTier,
                OnEncodedFrame = (codec, flags, wid, pts, rw, rh, data) =>
                    OnEncodedFrame?.Invoke(codec, flags, wid, pts, rw, rh, data)
            };
            newEng.StartWindowCapture(w, _targetFps);
            _engines[w.WindowId] = newEng;
            startedAny = true;
            OpenUULogger.Shared.Info("CAPTURE", $"started win={w.WindowId} app={w.AppName} popup={w.IsPopup} size={(int)w.LogicalWidth}x{(int)w.LogicalHeight}");
            OnStatus?.Invoke($"开始传输窗口: {w.AppName} - {w.Title}");
        }

        if (forcePublish)
        {
            foreach (var eng in _engines.Values)
                eng.RequestKeyframe();
        }
        if (startedAny || forcePublish)
        {
            PublishTopology(appWindows, force: forcePublish);
        }
    }

    private void PublishTopology(IReadOnlyList<ShareableWindowItem> windows, bool force)
    {
        var byId = windows.ToDictionary(w => w.WindowId);
        var items = new List<WindowTopologyItem>(windows.Count + 1);

        foreach (var win in windows)
        {
            uint primaryId = _primaryWindowByApp.TryGetValue(win.AppId, out uint pidWin) ? pidWin : win.WindowId;
            bool isMain = !win.IsPopup && win.WindowId == primaryId;
            uint anchorId;
            if (isMain)
            {
                anchorId = 0;
            }
            else if (win.IsPopup)
            {
                // Anchor popup menu to the topmost normal window of the same PID/App that intersects or lies closest
                var anchorCandidate = windows
                    .Where(c => !c.IsPopup && (c.Pid == win.Pid || c.AppId.Equals(win.AppId, StringComparison.OrdinalIgnoreCase)))
                    .OrderByDescending(c => OverlapArea(win.PhysicalBounds, c.PhysicalBounds))
                    .FirstOrDefault();
                anchorId = anchorCandidate?.WindowId ?? primaryId;
            }
            else
            {
                anchorId = primaryId;
            }

            float relX = 0f, relY = 0f;
            if (!isMain && anchorId != 0 && byId.TryGetValue(anchorId, out var anchorWin))
            {
                relX = win.LogicalX - anchorWin.LogicalX;
                relY = win.LogicalY - anchorWin.LogicalY;
            }

            _windowIconCache.TryGetValue(win.WindowId, out string? iconB64);
            items.Add(new WindowTopologyItem
            {
                WindowId = win.WindowId,
                ParentWindowId = anchorId,
                Kind = isMain ? 0 : (win.IsPopup ? 2 : 1),
                RelX = relX,
                RelY = relY,
                Width = win.LogicalWidth,
                Height = win.LogicalHeight,
                Title = string.IsNullOrWhiteSpace(win.Title) ? win.AppName : win.Title,
                IconPngB64 = win.IsPopup ? null : iconB64
            });
        }

        if (_isSharingFullDesktop)
        {
            items.Add(new WindowTopologyItem
            {
                WindowId = FullDesktopWindowId,
                ParentWindowId = 0,
                Kind = 0,
                RelX = 0,
                RelY = 0,
                Width = _fullDesktopLogicalSize.W,
                Height = _fullDesktopLogicalSize.H,
                Title = $"远程桌面 - {Environment.MachineName}",
                IconPngB64 = null
            });
        }

        items.Sort((a, b) => a.WindowId.CompareTo(b.WindowId));

        if (force || !items.SequenceEqual(_lastTopology))
        {
            _lastTopology = items;
            OnTopologyChanged?.Invoke(items);
        }
        AudioStreamer.UpdateScope(_isSharingFullDesktop, _sharedAppIds);
    }

    private static ShareableWindowItem? PickPreferredPrimaryWindow(IReadOnlyList<ShareableWindowItem> candidates)
    {
        if (candidates.Count == 0) return null;
        return candidates
            .OrderByDescending(w =>
            {
                string t = (w.Title ?? "").Trim();
                string app = (w.AppName ?? "").Trim();
                return !string.IsNullOrEmpty(app) && string.Equals(t, app, StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            })
            .ThenByDescending(w =>
            {
                string t = (w.Title ?? "").Trim();
                string app = (w.AppName ?? "").Trim();
                return !string.IsNullOrEmpty(app) && t.StartsWith(app, StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            })
            .ThenByDescending(w => (double)w.LogicalWidth * w.LogicalHeight)
            .FirstOrDefault();
    }

    private static long OverlapArea(Win32Interop.RECT a, Win32Interop.RECT b)
    {
        int xOverlap = Math.Max(0, Math.Min(a.Right, b.Right) - Math.Max(a.Left, b.Left));
        int yOverlap = Math.Max(0, Math.Min(a.Bottom, b.Bottom) - Math.Max(a.Top, b.Top));
        return (long)xOverlap * yOverlap;
    }
}

using System.Diagnostics;

namespace OpenUU.Host;

using OpenUU.Shared;

/// <summary>
/// Captures a single Windows <c>HWND</c> (via DWM composition surface <c>PrintWindow(PW_RENDERFULLCONTENT)</c>)
/// or the primary monitor (via DXGI <c>IDXGIOutputDuplication</c> with GDI fallback), skips unchanged idle frames,
/// and encodes into low-latency Annex-B H.264 / HEVC via <c>openuu_win_media.dll</c>.
/// </summary>
public sealed unsafe class ScreenCaptureEngine : IDisposable
{
    public delegate void EncodedFrameHandler(
        byte codec,
        byte flags,
        uint windowId,
        ulong ptsUs,
        ushort reportedWidth,
        ushort reportedHeight,
        ReadOnlySpan<byte> annexBData
    );

    public EncodedFrameHandler? OnEncodedFrame { get; set; }

    private readonly object _sync = new();
    private CancellationTokenSource? _cts;
    private Task? _loopTask;

    private IntPtr _targetHwnd;
    private uint _targetWindowId;
    private bool _isFullDesktop;
    private bool _isFloatingPopover;

    private float _logicalWidth;
    private float _logicalHeight;
    private volatile int _baseFps = 45;
    private volatile bool _dynamicResolutionEnabled = true;
    private StreamNetworkTier _networkTier = StreamNetworkTier.Lan;
    private volatile bool _forceKeyframe = true;
    private volatile bool _reconfigRequested;

    public bool DynamicResolutionEnabled
    {
        get => _dynamicResolutionEnabled;
        set
        {
            if (_dynamicResolutionEnabled != value)
            {
                _dynamicResolutionEnabled = value;
                _reconfigRequested = true;
            }
        }
    }

    public StreamNetworkTier NetworkTier
    {
        get => _networkTier;
        set
        {
            if (_networkTier != value)
            {
                _networkTier = value;
                _reconfigRequested = true;
            }
        }
    }

    public void SetTargetFps(int fps)
    {
        int clamped = Math.Clamp(fps, 24, 60);
        if (_baseFps != clamped)
        {
            _baseFps = clamped;
            _reconfigRequested = true;
        }
    }

    public void RequestKeyframe() => _forceKeyframe = true;

    public void UpdateWindowLogicalSize(float logicalW, float logicalH)
    {
        lock (_sync)
        {
            if (MathF.Abs(logicalW - _logicalWidth) > 2f || MathF.Abs(logicalH - _logicalHeight) > 2f)
            {
                _logicalWidth = MathF.Max(48f, logicalW);
                _logicalHeight = MathF.Max(32f, logicalH);
                _reconfigRequested = true;
            }
        }
    }

    public void StartWindowCapture(ShareableWindowItem item, int fps)
    {
        Stop();
        lock (_sync)
        {
            _targetHwnd = item.Hwnd;
            _targetWindowId = item.WindowId;
            _isFullDesktop = false;
            _isFloatingPopover = item.IsPopup;
            _logicalWidth = MathF.Max(48f, item.LogicalWidth);
            _logicalHeight = MathF.Max(32f, item.LogicalHeight);
            _baseFps = Math.Clamp(fps, 24, 60);
            _forceKeyframe = true;
            _reconfigRequested = false;

            _cts = new CancellationTokenSource();
            var token = _cts.Token;
            _loopTask = Task.Factory.StartNew(
                () => CaptureLoop(token),
                token,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default
            );
        }
    }

    public (int ScreenW, int ScreenH) StartDesktopCapture(uint windowId, int fps)
    {
        Stop();
        int screenW = Math.Max(640, Win32Interop.GetSystemMetrics(Win32Interop.SM_CXSCREEN));
        int screenH = Math.Max(480, Win32Interop.GetSystemMetrics(Win32Interop.SM_CYSCREEN));
        double dpiScale = Win32Interop.GetDpiScale(Win32Interop.GetForegroundWindow());
        if (dpiScale <= 0.1) dpiScale = 1.0;

        lock (_sync)
        {
            _targetHwnd = IntPtr.Zero;
            _targetWindowId = windowId;
            _isFullDesktop = true;
            _isFloatingPopover = false;
            _logicalWidth = (float)(screenW / dpiScale);
            _logicalHeight = (float)(screenH / dpiScale);
            _baseFps = Math.Clamp(fps, 24, 60);
            _forceKeyframe = true;
            _reconfigRequested = false;

            _cts = new CancellationTokenSource();
            var token = _cts.Token;
            _loopTask = Task.Factory.StartNew(
                () => CaptureLoop(token),
                token,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default
            );
        }

        return ((int)_logicalWidth, (int)_logicalHeight);
    }

    public void Stop()
    {
        CancellationTokenSource? cts;
        Task? task;
        lock (_sync)
        {
            cts = _cts;
            task = _loopTask;
            _cts = null;
            _loopTask = null;
        }
        if (cts != null)
        {
            cts.Cancel();
            try { task?.Wait(TimeSpan.FromMilliseconds(800)); }
            catch { }
            cts.Dispose();
        }
    }

    public void Dispose() => Stop();

    private (int EncW, int EncH, ushort ReportedW, ushort ReportedH) ComputeDimensions(float logW, float logH, StreamNetworkTier tier, bool dynRes)
    {
        int reportedW = Math.Max(2, ((int)MathF.Round(logW * 2.0f)) & ~1);
        int reportedH = Math.Max(2, ((int)MathF.Round(logH * 2.0f)) & ~1);

        const float baseScale = 2.0f;
        float effScale;
        if (!_isFloatingPopover && (dynRes || tier == StreamNetworkTier.WanRelay))
        {
            float maxEdge = MathF.Max(1f, MathF.Max(logW, logH));
            float targetMaxPx = tier switch
            {
                StreamNetworkTier.Lan => 1600f,
                StreamNetworkTier.WanDirect => 1500f,
                StreamNetworkTier.WanRelay => 1360f,
                _ => 1600f
            };
            float minScale = tier == StreamNetworkTier.WanRelay ? 1.05f : 1.15f;
            effScale = MathF.Min(baseScale, MathF.Min(1.35f, MathF.Max(minScale, targetMaxPx / maxEdge)));
        }
        else
        {
            effScale = baseScale;
        }

        int encW = Math.Max(64, ((int)MathF.Round(logW * effScale) + 7) & ~15);
        int encH = Math.Max(64, ((int)MathF.Round(logH * effScale) + 7) & ~15);
        return (encW, encH, (ushort)Math.Min(65534, reportedW), (ushort)Math.Min(65534, reportedH));
    }

    private static int EffectiveFps(int baseFps, StreamNetworkTier tier) => tier switch
    {
        StreamNetworkTier.Lan => Math.Clamp(baseFps, 24, 60),
        StreamNetworkTier.WanDirect => Math.Clamp(baseFps, 24, 45),
        StreamNetworkTier.WanRelay => Math.Min(30, Math.Max(24, baseFps)),
        _ => 45
    };

    private static int ComputeBitrate(int width, int height, int fps, StreamNetworkTier tier)
    {
        long pixels = (long)width * height;
        double fpsFactor = 0.25 + 0.75 * (Math.Clamp(fps, 24, 60) / 60.0);
        return tier switch
        {
            StreamNetworkTier.Lan => Math.Max(2_800_000, (int)(Math.Min(10_000_000L, Math.Max(4_500_000L, pixels * 3)) * fpsFactor)),
            StreamNetworkTier.WanDirect => Math.Max(1_400_000, (int)(Math.Min(4_000_000L, Math.Max(1_800_000L, (long)(pixels * 1.45))) * fpsFactor)),
            StreamNetworkTier.WanRelay => (int)Math.Clamp((long)(pixels * 0.95), 950_000L, 2_000_000L),
            _ => 4_500_000
        };
    }

    private void CaptureLoop(CancellationToken ct)
    {
        OpenUUNativeMethods.openuu_media_startup();

        IntPtr encoder = IntPtr.Zero;
        IntPtr dxgiCap = IntPtr.Zero;
        byte actualCodec = 1;
        int activeEncW = 0;
        int activeEncH = 0;
        int activeFps = 30;
        ushort reportedW = 0;
        ushort reportedH = 0;

        byte[] bgraBuf = Array.Empty<byte>();
        byte[] annexBBuf = new byte[4 * 1024 * 1024]; // 4 MiB max single compressed frame
        ulong lastHash = 0;
        long sentFramesAfterStart = 0;
        var sw = Stopwatch.StartNew();
        long lastSentTickMs = 0;

        try
        {
            if (_isFullDesktop)
            {
                dxgiCap = OpenUUNativeMethods.openuu_dxgi_capturer_create(out int scrW, out int scrH);
                if (scrW > 0 && scrH > 0)
                {
                    double dpi = Win32Interop.GetDpiScale(Win32Interop.GetForegroundWindow());
                    if (dpi <= 0.1) dpi = 1.0;
                    lock (_sync)
                    {
                        _logicalWidth = (float)(scrW / dpi);
                        _logicalHeight = (float)(scrH / dpi);
                    }
                }
            }

            while (!ct.IsCancellationRequested)
            {
                long frameStartMs = sw.ElapsedMilliseconds;

                if (!_isFullDesktop && _targetHwnd != IntPtr.Zero)
                {
                    if (!Win32Interop.IsWindow(_targetHwnd))
                        break;

                    if (!Win32Interop.IsIconic(_targetHwnd))
                    {
                        var vis = Win32Interop.GetVisibleWindowBounds(_targetHwnd);
                        double scale = Win32Interop.GetDpiScale(_targetHwnd);
                        float curLogW = (float)(vis.Width / scale);
                        float curLogH = (float)(vis.Height / scale);
                        if (curLogW >= 44f && curLogH >= 28f)
                        {
                            lock (_sync)
                            {
                                if (MathF.Abs(curLogW - _logicalWidth) > 2f || MathF.Abs(curLogH - _logicalHeight) > 2f)
                                {
                                    _logicalWidth = curLogW;
                                    _logicalHeight = curLogH;
                                    _reconfigRequested = true;
                                }
                            }
                        }
                    }
                }

                float snapLogW, snapLogH;
                lock (_sync)
                {
                    snapLogW = _logicalWidth;
                    snapLogH = _logicalHeight;
                }
                var tier = _networkTier;
                int effFps = EffectiveFps(_baseFps, tier);
                var dims = ComputeDimensions(snapLogW, snapLogH, tier, _dynamicResolutionEnabled);

                if (encoder == IntPtr.Zero || _reconfigRequested || dims.EncW != activeEncW || dims.EncH != activeEncH || effFps != activeFps)
                {
                    _reconfigRequested = false;
                    if (encoder != IntPtr.Zero)
                    {
                        OpenUUNativeMethods.openuu_encoder_destroy(encoder);
                        encoder = IntPtr.Zero;
                    }
                    activeEncW = dims.EncW;
                    activeEncH = dims.EncH;
                    activeFps = effFps;
                    reportedW = dims.ReportedW;
                    reportedH = dims.ReportedH;

                    int bitrate = ComputeBitrate(activeEncW, activeEncH, activeFps, tier);
                    byte preferredCodec = tier.PrefersHevc() ? (byte)2 : (byte)1;
                    encoder = OpenUUNativeMethods.openuu_encoder_create(
                        activeEncW,
                        activeEncH,
                        activeFps,
                        bitrate,
                        preferredCodec,
                        out actualCodec,
                        out _
                    );
                    if (encoder == IntPtr.Zero)
                    {
                        OpenUULogger.Shared.Warn("CAPTURE", $"encoder_create failed win={_targetWindowId} {activeEncW}x{activeEncH}@{activeFps}");
                        Thread.Sleep(100);
                        continue;
                    }

                    int neededBgra = activeEncW * activeEncH * 4;
                    if (bgraBuf.Length < neededBgra)
                        bgraBuf = new byte[neededBgra];

                    _forceKeyframe = true;
                    lastHash = 0;
                    sentFramesAfterStart = 0;
                }

                bool wantForceIdr = _forceKeyframe;
                if (wantForceIdr)
                    sentFramesAfterStart = 0;
                int capRc;
                ulong curHash = 0;

                fixed (byte* pBgra = bgraBuf)
                {
                    if (_isFullDesktop)
                    {
                        capRc = OpenUUNativeMethods.openuu_dxgi_capturer_grab_bgra(
                            dxgiCap,
                            activeEncW,
                            activeEncH,
                            pBgra,
                            activeEncW * 4,
                            out curHash
                        );
                    }
                    else
                    {
                        capRc = OpenUUNativeMethods.openuu_capture_hwnd_bgra(
                            _targetHwnd,
                            activeEncW,
                            activeEncH,
                            pBgra,
                            activeEncW * 4,
                            out curHash
                        );
                    }
                }

                // Always emit an initial burst of 14 frames on stream start / keyframe request so any H.264/HEVC
                // decoder DPB flushes immediately even on static windows, followed by lightweight 250ms P-frame keep-fresh (~30B).
                bool isInitialWarmup = sentFramesAfterStart < 14;
                bool isUnchanged = !wantForceIdr &&
                                   !isInitialWarmup &&
                                   (capRc == 0 || (capRc == 1 && curHash != 0 && curHash == lastHash)) &&
                                   (frameStartMs - lastSentTickMs < 250);

                // Note: If DXGI AcquireNextFrame returned 0 (desktop unchanged) during initial warmup or keep-fresh,
                // bgraBuf already holds the latest valid desktop frame from Frame #0, so allow encoding that tiny skip P-frame!
                bool hasValidPixels = capRc == 1 || (capRc == 0 && sentFramesAfterStart > 0);
                if (hasValidPixels && !isUnchanged)
                {
                    if (wantForceIdr)
                    {
                        _forceKeyframe = false;
                        OpenUUNativeMethods.openuu_encoder_force_keyframe(encoder);
                    }

                    ulong ptsUs = (ulong)(sw.Elapsed.TotalMicroseconds);
                    int encodedBytes;
                    byte isKey;
                    fixed (byte* pBgra = bgraBuf)
                    fixed (byte* pOut = annexBBuf)
                    {
                        encodedBytes = OpenUUNativeMethods.openuu_encoder_encode_bgra(
                            encoder,
                            pBgra,
                            activeEncW * 4,
                            ptsUs,
                            pOut,
                            annexBBuf.Length,
                            out isKey
                        );
                    }

                    if (encodedBytes > 0)
                    {
                        if (capRc == 1)
                            lastHash = curHash;
                        sentFramesAfterStart++;
                        if (sentFramesAfterStart == 1)
                        {
                            OpenUULogger.Shared.Debug("CAPTURE", $"first_frame win={_targetWindowId} {activeEncW}x{activeEncH} bytes={encodedBytes}");
                        }
                        lastSentTickMs = frameStartMs;
                        byte flags = isKey != 0 ? (byte)0x01 : (byte)0x00;
                        OnEncodedFrame?.Invoke(
                            actualCodec,
                            flags,
                            _targetWindowId,
                            ptsUs,
                            reportedW,
                            reportedH,
                            annexBBuf.AsSpan(0, encodedBytes)
                        );
                    }
                }

                int intervalMs = Math.Max(15, 1000 / Math.Max(1, activeFps));
                int elapsedMs = (int)(sw.ElapsedMilliseconds - frameStartMs);
                int sleepMs = intervalMs - elapsedMs;
                if (sleepMs > 1)
                {
                    ct.WaitHandle.WaitOne(sleepMs);
                }
            }
        }
        catch (Exception ex)
        {
            OpenUULogger.Shared.Error("CAPTURE", $"CaptureLoop exception win={_targetWindowId}: {ex}");
        }
        finally
        {
            if (encoder != IntPtr.Zero)
                OpenUUNativeMethods.openuu_encoder_destroy(encoder);
            if (dxgiCap != IntPtr.Zero)
                OpenUUNativeMethods.openuu_dxgi_capturer_destroy(dxgiCap);
        }
    }
}

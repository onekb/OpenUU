using System.Diagnostics;
using System.Threading.Channels;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace OpenUU.Client;

using OpenUU.Shared;

/// <summary>
/// Lock-protected router that dispatches incoming QUIC video packets directly to each remote window's
/// dedicated <see cref="VideoDisplayRenderer"/> decode queue without blocking the UI thread.
/// </summary>
public sealed class FastVideoRouter : IDisposable
{
    private sealed class Entry
    {
        public required VideoDisplayRenderer Renderer { get; init; }
        public ushort Width { get; set; }
        public ushort Height { get; set; }
    }

    private readonly object _lock = new();
    private readonly Dictionary<uint, Entry> _entries = new();
    private readonly HashSet<uint> _suppressedWindowIds = new();
    private bool _isWanMode;

    public void SetWanJitterMode(bool enabled)
    {
        List<VideoDisplayRenderer> renderers;
        lock (_lock)
        {
            _isWanMode = enabled;
            renderers = _entries.Values.Select(e => e.Renderer).ToList();
        }
        foreach (var r in renderers)
            r.SetWanJitterMode(enabled);
    }

    public VideoDisplayRenderer RendererFor(uint windowId)
    {
        lock (_lock)
        {
            _suppressedWindowIds.Remove(windowId);
            if (_entries.TryGetValue(windowId, out var existing))
                return existing.Renderer;

            var created = new VideoDisplayRenderer();
            created.SetWanJitterMode(_isWanMode);
            _entries[windowId] = new Entry { Renderer = created, Width = 0, Height = 0 };
            return created;
        }
    }

    public bool RouteAndEnqueue(EncodedVideoPacket packet)
    {
        VideoDisplayRenderer target;
        bool needsWindowSync = false;

        lock (_lock)
        {
            if (_suppressedWindowIds.Contains(packet.WindowId))
                return false;

            if (_entries.TryGetValue(packet.WindowId, out var existing))
            {
                if (existing.Width != packet.Width || existing.Height != packet.Height)
                {
                    existing.Width = packet.Width;
                    existing.Height = packet.Height;
                    needsWindowSync = true;
                }
                target = existing.Renderer;
            }
            else
            {
                var created = new VideoDisplayRenderer();
                created.SetWanJitterMode(_isWanMode);
                _entries[packet.WindowId] = new Entry
                {
                    Renderer = created,
                    Width = packet.Width,
                    Height = packet.Height
                };
                target = created;
                needsWindowSync = true;
                OpenUULogger.Shared.Debug("VIDEO", $"first_rx win={packet.WindowId} codec={packet.Codec} flags={packet.Flags} len={packet.Data.Length}");
            }
        }

        target.Enqueue(packet);
        return needsWindowSync;
    }

    public void Suppress(uint windowId)
    {
        VideoDisplayRenderer? removed = null;
        lock (_lock)
        {
            _suppressedWindowIds.Add(windowId);
            if (_entries.Remove(windowId, out var entry))
                removed = entry.Renderer;
        }
        removed?.Dispose();
    }

    public void Unsuppress(uint windowId)
    {
        lock (_lock)
        {
            _suppressedWindowIds.Remove(windowId);
        }
    }

    public void UnsuppressAll()
    {
        lock (_lock)
        {
            _suppressedWindowIds.Clear();
        }
    }

    public void Unregister(uint windowId)
    {
        VideoDisplayRenderer? removed = null;
        lock (_lock)
        {
            if (_entries.Remove(windowId, out var entry))
                removed = entry.Renderer;
        }
        removed?.Dispose();
    }

    public void Clear()
    {
        List<VideoDisplayRenderer> all;
        lock (_lock)
        {
            all = _entries.Values.Select(e => e.Renderer).ToList();
            _entries.Clear();
            _suppressedWindowIds.Clear();
        }
        foreach (var r in all)
            r.Dispose();
    }

    public void Dispose() => Clear();
}

/// <summary>
/// Low-latency Media Foundation H.264 / HEVC Annex-B decoder (<c>openuu_win_media.dll</c>) that decodes on
/// a dedicated background worker and updates a WPF <see cref="WriteableBitmap"/> cleanly.
/// </summary>
public sealed class VideoDisplayRenderer : IDisposable
{
    private readonly Channel<EncodedVideoPacket> _channel;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _workerTask;

    private WriteableBitmap? _bitmap;
    private int _bmpWidth;
    private int _bmpHeight;
    private volatile bool _isWanMode;
    private volatile bool _disposed;
    private volatile int _uiPresentPending;

    private byte[] _bgraStaging = Array.Empty<byte>();
    private int _stagingW;
    private int _stagingH;
    private readonly object _stagingLock = new();

    private long _totalDecodedFrames;
    public long TotalDecodedFrames => Interlocked.Read(ref _totalDecodedFrames);

    public Action<WriteableBitmap>? OnBitmapReplaced { get; set; }
    public Action<VideoStreamTelemetry>? OnTelemetryUpdated { get; set; }
    public Action<uint>? OnRequestKeyframe { get; set; }

    public WriteableBitmap? CurrentBitmap => _bitmap;

    public VideoDisplayRenderer()
    {
        _channel = Channel.CreateBounded<EncodedVideoPacket>(new BoundedChannelOptions(96)
        {
            FullMode = BoundedChannelFullMode.Wait,
            SingleReader = true,
            SingleWriter = false
        });
        _workerTask = Task.Factory.StartNew(
            DecodeLoopAsync,
            _cts.Token,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default
        ).Unwrap();
    }

    public void SetWanJitterMode(bool enabled) => _isWanMode = enabled;

    public void Enqueue(EncodedVideoPacket packet)
    {
        if (_disposed) return;
        _channel.Writer.TryWrite(packet);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _channel.Writer.TryComplete();
        _cts.Cancel();
    }

    private async Task DecodeLoopAsync()
    {
        OpenUUNativeMethods.openuu_media_startup();

        IntPtr decoder = IntPtr.Zero;
        byte activeCodec = 0;

        var sw = Stopwatch.StartNew();
        long statsWindowStartMs = 0;
        int statsFramesInWindow = 0;
        long statsBytesInWindow = 0;
        double statsDecodeMsSum = 0;
        int statsSkippedFrames = 0;
        long lastArrivalMs = 0;
        int maxGapMsInWindow = 0;
        ulong firstHostPtsUs = 0;
        ulong lastHostPtsUs = 0;

        try
        {
            var reader = _channel.Reader;
            while (await reader.WaitToReadAsync(_cts.Token).ConfigureAwait(false))
            {
                // Drain burst queue: if a newer IDR keyframe is already queued behind old frames, jump straight to it!
                var batch = new List<EncodedVideoPacket>(8);
                while (reader.TryRead(out var pkt))
                    batch.Add(pkt);

                int startIdx = 0;
                int maxBurst = _isWanMode ? 5 : 3;
                if (batch.Count > maxBurst)
                {
                    for (int i = batch.Count - 1; i > 0; i--)
                    {
                        if ((batch[i].Flags & 0x01) != 0)
                        {
                            statsSkippedFrames += i;
                            startIdx = i;
                            break;
                        }
                    }
                }

                for (int i = startIdx; i < batch.Count; i++)
                {
                    if (_cts.IsCancellationRequested) break;
                    var packet = batch[i];
                    if (packet.Data.Length == 0) continue;

                    if (decoder == IntPtr.Zero || activeCodec != packet.Codec)
                    {
                        if (decoder != IntPtr.Zero)
                        {
                            OpenUUNativeMethods.openuu_decoder_destroy(decoder);
                            decoder = IntPtr.Zero;
                        }
                        activeCodec = packet.Codec == 2 ? (byte)2 : (byte)1;
                        decoder = OpenUUNativeMethods.openuu_decoder_create(activeCodec);
                        if (decoder == IntPtr.Zero)
                        {
                            if (activeCodec == 2)
                                OpenUULogger.Shared.Warn("VIDEO", "系统缺少 HEVC 解码器扩展，建议在 Microsoft Store 安装 HEVC 视频扩展或使用 H.264 链路");
                            continue;
                        }
                    }

                    double t0 = sw.Elapsed.TotalMilliseconds;
                    int rc = DecodeNativePacket(decoder, packet, out int decW, out int decH);

                    double decodeMs = Math.Max(0.01, sw.Elapsed.TotalMilliseconds - t0);

                    if (rc < 0)
                    {
                        OnRequestKeyframe?.Invoke(packet.WindowId);
                        continue;
                    }

                    if (rc == 1 && decW > 0 && decH > 0)
                    {
                        long total = Interlocked.Increment(ref _totalDecodedFrames);
                        if (total == 1 || total == 5 || total % 60 == 0)
                        {
                            OpenUULogger.Shared.Debug("VIDEO", $"win={packet.WindowId} decoded_frames={total} res={decW}x{decH} decodeMs={decodeMs:F2}");
                        }

                        ScheduleUiPresent();

                        long nowMs = sw.ElapsedMilliseconds;
                        if (statsWindowStartMs == 0)
                            statsWindowStartMs = nowMs;
                        if (lastArrivalMs > 0)
                        {
                            int gap = (int)(nowMs - lastArrivalMs);
                            if (gap is > 0 and < 1500)
                                maxGapMsInWindow = Math.Max(maxGapMsInWindow, gap);
                        }
                        lastArrivalMs = nowMs;

                        if (packet.TimestampUs > 0)
                        {
                            if (firstHostPtsUs == 0) firstHostPtsUs = packet.TimestampUs;
                            lastHostPtsUs = packet.TimestampUs;
                        }

                        statsFramesInWindow++;
                        statsBytesInWindow += packet.Data.Length;
                        statsDecodeMsSum += decodeMs;

                        double elapsedSec = (nowMs - statsWindowStartMs) / 1000.0;
                        if (elapsedSec >= 0.45)
                        {
                            int fps = (int)Math.Round(statsFramesInWindow / elapsedSec);
                            int hostFps = fps;
                            if (lastHostPtsUs > firstHostPtsUs && statsFramesInWindow > 1)
                            {
                                double hostSpan = (lastHostPtsUs - firstHostPtsUs) / 1_000_000.0;
                                if (hostSpan > 0.05)
                                    hostFps = (int)Math.Round((statsFramesInWindow - 1) / hostSpan);
                            }
                            double mbps = (statsBytesInWindow * 8.0) / (elapsedSec * 1_000_000.0);
                            double avgDec = statsDecodeMsSum / Math.Max(1, statsFramesInWindow);
                            int logW = Math.Max(1, packet.Width / 2);
                            int logH = Math.Max(1, packet.Height / 2);
                            double scale = (double)decW / logW;

                            var snap = new VideoStreamTelemetry(
                                CodecName: packet.Codec == 2 ? "HEVC" : "H.264",
                                Fps: fps,
                                HostFps: hostFps,
                                MaxGapMs: maxGapMsInWindow,
                                BitrateMbps: mbps,
                                EncodedWidth: decW,
                                EncodedHeight: decH,
                                LogicalWidth: logW,
                                LogicalHeight: logH,
                                ScaleRatio: scale,
                                AvgDecodeMs: avgDec,
                                LastFrameBytes: packet.Data.Length,
                                IsLastKeyframe: (packet.Flags & 0x01) != 0,
                                SkippedBurstFrames: statsSkippedFrames,
                                UpdatedAtTicks: Stopwatch.GetTimestamp()
                            );

                            statsWindowStartMs = nowMs;
                            statsFramesInWindow = 0;
                            statsBytesInWindow = 0;
                            statsDecodeMsSum = 0;
                            maxGapMsInWindow = 0;
                            firstHostPtsUs = 0;
                            lastHostPtsUs = 0;

                            OnTelemetryUpdated?.Invoke(snap);
                        }
                    }
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            OpenUULogger.Shared.Error("VIDEO", $"DecodeLoop exception: {ex}");
        }
        finally
        {
            if (decoder != IntPtr.Zero)
                OpenUUNativeMethods.openuu_decoder_destroy(decoder);
        }
    }

    private void ScheduleUiPresent()
    {
        if (_disposed) return;
        if (Interlocked.Exchange(ref _uiPresentPending, 1) != 0)
            return;

        var app = System.Windows.Application.Current;
        if (app?.Dispatcher == null)
        {
            Interlocked.Exchange(ref _uiPresentPending, 0);
            return;
        }

        app.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.Render, () =>
        {
            Interlocked.Exchange(ref _uiPresentPending, 0);
            if (_disposed) return;

            lock (_stagingLock)
            {
                if (_stagingW <= 0 || _stagingH <= 0 || _bgraStaging.Length < _stagingW * _stagingH * 4)
                    return;

                if (_bitmap == null || _bmpWidth != _stagingW || _bmpHeight != _stagingH)
                {
                    _bmpWidth = _stagingW;
                    _bmpHeight = _stagingH;
                    _bitmap = new WriteableBitmap(_bmpWidth, _bmpHeight, 96, 96, PixelFormats.Bgra32, null);
                    OnBitmapReplaced?.Invoke(_bitmap);
                }

                _bitmap.Lock();
                try
                {
                    unsafe
                    {
                        int srcStride = _bmpWidth * 4;
                        int dstStride = _bitmap.BackBufferStride;
                        byte* pDst = (byte*)_bitmap.BackBuffer;
                        fixed (byte* pSrc = _bgraStaging)
                        {
                            if (srcStride == dstStride)
                            {
                                Buffer.MemoryCopy(pSrc, pDst, (long)dstStride * _bmpHeight, (long)srcStride * _bmpHeight);
                            }
                            else
                            {
                                for (int y = 0; y < _bmpHeight; y++)
                                {
                                    Buffer.MemoryCopy(
                                        pSrc + (long)y * srcStride,
                                        pDst + (long)y * dstStride,
                                        dstStride,
                                        srcStride
                                    );
                                }
                            }
                        }
                    }
                    _bitmap.AddDirtyRect(new Int32Rect(0, 0, _bmpWidth, _bmpHeight));
                }
                finally
                {
                    _bitmap.Unlock();
                }
            }
        });
    }

    private unsafe int DecodeNativePacket(IntPtr decoder, EncodedVideoPacket packet, out int decW, out int decH)
    {
        decW = 0;
        decH = 0;
        int rc;
        lock (_stagingLock)
        {
            fixed (byte* pIn = packet.Data)
            fixed (byte* pOut = _bgraStaging)
            {
                rc = OpenUUNativeMethods.openuu_decoder_decode_annexb(
                    decoder,
                    pIn,
                    packet.Data.Length,
                    packet.TimestampUs,
                    _bgraStaging.Length > 0 ? pOut : null,
                    _stagingW * 4,
                    _bgraStaging.Length,
                    out decW,
                    out decH
                );
            }

            if (rc == 2 && decW > 0 && decH > 0)
            {
                _stagingW = decW;
                _stagingH = decH;
                _bgraStaging = new byte[decW * decH * 4];
                fixed (byte* pOut2 = _bgraStaging)
                {
                    rc = OpenUUNativeMethods.openuu_decoder_copy_last_bgra(
                        decoder,
                        pOut2,
                        decW * 4,
                        _bgraStaging.Length
                    );
                }
            }
        }
        return rc;
    }
}

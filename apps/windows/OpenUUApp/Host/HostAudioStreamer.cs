using System.Diagnostics;

namespace OpenUU.Host;

using OpenUU.Shared;

/// <summary>
/// Captures 48,000 Hz stereo system audio via WASAPI loopback on Windows Host, optionally mutes Host speakers
/// while streaming (auto-restoring on stop/exit), applies a digital silence gate to save 100% network bandwidth
/// when quiet, and encodes 1024-sample AAC-LC (<c>codec = 3</c>) frames with PCM16 (<c>codec = 1</c>) fallback.
/// Windows counterpart to macOS <c>HostAudioStreamer</c>.
/// </summary>
public sealed class HostAudioStreamer : IDisposable
{
    public const byte CodecPcmS16Le = 1;
    public const byte CodecAacLc = 3;
    private const int SampleRate = 48_000;
    private const int Channels = 2;
    private const int AacFrameSamples = 1024; // 1024 stereo frames = 2048 int16 samples

    public delegate void EncodedAudioHandler(
        byte codec,
        byte flags,
        byte channels,
        uint sampleRate,
        ulong ptsUs,
        ReadOnlySpan<byte> data
    );

    public EncodedAudioHandler? OnEncodedAudio { get; set; }

    private readonly object _sync = new();
    private bool _isEnabled = true;
    private bool _muteHostSpeakers = true;
    private bool _hasActiveScope;
    private StreamNetworkTier _networkTier = StreamNetworkTier.Lan;

    private CancellationTokenSource? _cts;
    private Task? _workerTask;
    private IntPtr _activeLoopback;

    public void UpdatePreferences(bool enabled, bool muteHost)
    {
        lock (_sync)
        {
            bool enabledChanged = _isEnabled != enabled;
            bool muteChanged = _muteHostSpeakers != muteHost;
            _isEnabled = enabled;
            _muteHostSpeakers = muteHost;

            if (enabledChanged)
            {
                ReconcileLocked();
            }
            else if (muteChanged && _activeLoopback != IntPtr.Zero)
            {
                OpenUUNativeMethods.openuu_wasapi_loopback_set_mute_host(_activeLoopback, muteHost ? (byte)1 : (byte)0);
            }
        }
    }

    public void SetNetworkTier(StreamNetworkTier tier)
    {
        lock (_sync)
        {
            if (_networkTier == tier) return;
            _networkTier = tier;
        }
    }

    public void UpdateScope(bool isFullDesktop, IReadOnlyCollection<string> sharedAppIds)
    {
        bool wantActive = isFullDesktop || sharedAppIds.Count > 0;
        lock (_sync)
        {
            if (_hasActiveScope == wantActive) return;
            _hasActiveScope = wantActive;
            ReconcileLocked();
        }
    }

    public void Stop()
    {
        CancellationTokenSource? cts;
        Task? task;
        lock (_sync)
        {
            _hasActiveScope = false;
            cts = _cts;
            task = _workerTask;
            _cts = null;
            _workerTask = null;
        }
        if (cts != null)
        {
            cts.Cancel();
            try { task?.Wait(TimeSpan.FromMilliseconds(600)); } catch { }
            cts.Dispose();
        }
    }

    public void Dispose() => Stop();

    private void ReconcileLocked()
    {
        bool shouldRun = _isEnabled && _hasActiveScope;
        if (!shouldRun)
        {
            if (_cts != null)
            {
                var cts = _cts;
                var task = _workerTask;
                _cts = null;
                _workerTask = null;
                cts.Cancel();
                _ = Task.Run(() =>
                {
                    try { task?.Wait(TimeSpan.FromMilliseconds(500)); } catch { }
                    cts.Dispose();
                });
            }
            return;
        }

        if (_workerTask != null) return;

        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        _workerTask = Task.Factory.StartNew(
            () => CaptureAudioLoop(token),
            token,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default
        );
    }

    private unsafe void CaptureAudioLoop(CancellationToken ct)
    {
        OpenUUNativeMethods.openuu_media_startup();

        IntPtr loopback = IntPtr.Zero;
        IntPtr aacEnc = IntPtr.Zero;
        int activeBitrate = 0;

        var readChunk = new short[4096 * Channels];
        var pendingSamples = new List<short>(8192);
        var frameSamples = new short[AacFrameSamples * Channels];
        var aacOutBuf = new byte[4096];
        var pcmBytesBuf = new byte[AacFrameSamples * Channels * sizeof(short)];

        int silentFrameStreak = 0;
        ulong frameCounter = 0;
        var sw = Stopwatch.StartNew();

        try
        {
            bool initialMute;
            lock (_sync) initialMute = _muteHostSpeakers;
            loopback = OpenUUNativeMethods.openuu_wasapi_loopback_create(initialMute ? (byte)1 : (byte)0);
            if (loopback == IntPtr.Zero)
            {
                OpenUULogger.Shared.Warn("AUDIO", "WASAPI loopback unavailable on this machine (no active audio output device)");
                return;
            }
            lock (_sync) _activeLoopback = loopback;
            OpenUULogger.Shared.Info("AUDIO", $"started WASAPI 48kHz stereo loopback (muteHost={initialMute})");

            while (!ct.IsCancellationRequested)
            {
                StreamNetworkTier tier;
                bool wantMute;
                lock (_sync)
                {
                    tier = _networkTier;
                    wantMute = _muteHostSpeakers;
                }
                OpenUUNativeMethods.openuu_wasapi_loopback_set_mute_host(loopback, wantMute ? (byte)1 : (byte)0);

                int desiredBitrate = tier switch
                {
                    StreamNetworkTier.Lan => 128_000,
                    StreamNetworkTier.WanDirect => 96_000,
                    StreamNetworkTier.WanRelay => 96_000,
                    _ => 128_000
                };

                if (aacEnc == IntPtr.Zero || desiredBitrate != activeBitrate)
                {
                    if (aacEnc != IntPtr.Zero)
                    {
                        OpenUUNativeMethods.openuu_aac_encoder_destroy(aacEnc);
                        aacEnc = IntPtr.Zero;
                    }
                    activeBitrate = desiredBitrate;
                    aacEnc = OpenUUNativeMethods.openuu_aac_encoder_create(SampleRate, Channels, desiredBitrate);
                }

                int framesRead;
                fixed (short* pRead = readChunk)
                {
                    framesRead = OpenUUNativeMethods.openuu_wasapi_loopback_read_pcm16(loopback, pRead, 4096);
                }

                if (framesRead < 0)
                {
                    // Audio output endpoint changed (e.g. headphones plugged in) -> recreate cleanly
                    lock (_sync) _activeLoopback = IntPtr.Zero;
                    OpenUUNativeMethods.openuu_wasapi_loopback_destroy(loopback);
                    loopback = IntPtr.Zero;
                    ct.WaitHandle.WaitOne(250);
                    if (ct.IsCancellationRequested) break;
                    loopback = OpenUUNativeMethods.openuu_wasapi_loopback_create(wantMute ? (byte)1 : (byte)0);
                    if (loopback == IntPtr.Zero) break;
                    lock (_sync) _activeLoopback = loopback;
                    continue;
                }

                if (framesRead == 0)
                {
                    ct.WaitHandle.WaitOne(8);
                    continue;
                }

                int samplesRead = framesRead * Channels;
                for (int i = 0; i < samplesRead; i++)
                    pendingSamples.Add(readChunk[i]);

                // Cap accumulation on stall
                const int frameSampleLen = AacFrameSamples * Channels;
                if (pendingSamples.Count > frameSampleLen * 16)
                {
                    pendingSamples.RemoveRange(0, pendingSamples.Count - frameSampleLen * 4);
                }

                while (pendingSamples.Count >= frameSampleLen && !ct.IsCancellationRequested)
                {
                    int peak = 0;
                    for (int i = 0; i < frameSampleLen; i++)
                    {
                        short s = pendingSamples[i];
                        int abs = s == short.MinValue ? 32768 : Math.Abs((int)s);
                        if (abs > peak) peak = abs;
                        frameSamples[i] = s;
                    }
                    pendingSamples.RemoveRange(0, frameSampleLen);

                    if (peak <= 1)
                    {
                        silentFrameStreak++;
                        if (silentFrameStreak > 8)
                        {
                            // Pure digital silence gate: 0 bytes over network while quiet
                            frameCounter++;
                            continue;
                        }
                    }
                    else
                    {
                        silentFrameStreak = 0;
                    }

                    ulong ptsUs = (ulong)sw.Elapsed.TotalMicroseconds + (frameCounter * 1_024_000_000UL / SampleRate);
                    frameCounter++;

                    if (aacEnc != IntPtr.Zero)
                    {
                        int aacBytes;
                        fixed (short* pIn = frameSamples)
                        fixed (byte* pOut = aacOutBuf)
                        {
                            aacBytes = OpenUUNativeMethods.openuu_aac_encoder_encode_pcm16(
                                aacEnc,
                                pIn,
                                AacFrameSamples,
                                ptsUs,
                                pOut,
                                aacOutBuf.Length
                            );
                        }
                        if (aacBytes > 0)
                        {
                            OnEncodedAudio?.Invoke(
                                CodecAacLc,
                                0,
                                Channels,
                                SampleRate,
                                ptsUs,
                                aacOutBuf.AsSpan(0, aacBytes)
                            );
                        }
                    }
                    else
                    {
                        Buffer.BlockCopy(frameSamples, 0, pcmBytesBuf, 0, pcmBytesBuf.Length);
                        OnEncodedAudio?.Invoke(
                            CodecPcmS16Le,
                            0,
                            Channels,
                            SampleRate,
                            ptsUs,
                            pcmBytesBuf
                        );
                    }
                }
            }
        }
        catch (Exception ex)
        {
            OpenUULogger.Shared.Warn("AUDIO", $"HostAudioStreamer loop error: {ex.Message}");
        }
        finally
        {
            lock (_sync) _activeLoopback = IntPtr.Zero;
            if (loopback != IntPtr.Zero)
                OpenUUNativeMethods.openuu_wasapi_loopback_destroy(loopback);
            if (aacEnc != IntPtr.Zero)
                OpenUUNativeMethods.openuu_aac_encoder_destroy(aacEnc);
        }
    }
}

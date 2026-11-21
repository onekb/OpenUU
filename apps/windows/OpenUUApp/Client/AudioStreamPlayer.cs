using System.Threading.Channels;

namespace OpenUU.Client;

using OpenUU.Shared;

/// <summary>
/// Low-latency native audio stream decoder &amp; player for an independent <see cref="RemotePeerSession"/> on Windows.
/// Decodes incoming AAC-LC (<c>codec = 3</c>) via Media Foundation or raw PCM16 (<c>codec = 1</c>) into a ring-buffered
/// <c>WAVE_MAPPER</c> output with bounded ~210ms jitter ceiling and automatic headphone/speaker hot-swap.
/// Windows counterpart to macOS <c>AudioStreamPlayer</c>.
/// </summary>
public sealed class AudioStreamPlayer : IDisposable
{
    private const byte CodecPcmS16Le = 1;
    private const byte CodecAacLc = 3;
    private const byte AudioFlagConfig = 0x02;

    private readonly Channel<EncodedAudioPacket> _channel;
    private readonly CancellationTokenSource _cts = new();
    private readonly Task _workerTask;

    private volatile bool _isMuted;
    private volatile bool _resetRequested;
    private volatile bool _disposed;
    private long _totalDecodedAudioFrames;

    public long TotalDecodedAudioFrames => Interlocked.Read(ref _totalDecodedAudioFrames);

    public AudioStreamPlayer()
    {
        _channel = Channel.CreateBounded<EncodedAudioPacket>(new BoundedChannelOptions(24)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = true,
            SingleWriter = false
        });
        _workerTask = Task.Factory.StartNew(
            PlayLoopAsync,
            _cts.Token,
            TaskCreationOptions.LongRunning,
            TaskScheduler.Default
        ).Unwrap();
    }

    public void SetMuted(bool muted)
    {
        if (_isMuted == muted) return;
        _isMuted = muted;
        if (muted)
        {
            while (_channel.Reader.TryRead(out _)) { }
            _resetRequested = true;
        }
    }

    public void Stop()
    {
        while (_channel.Reader.TryRead(out _)) { }
        _resetRequested = true;
    }

    public void Enqueue(EncodedAudioPacket packet)
    {
        if (_disposed || _isMuted) return;
        if ((packet.Flags & AudioFlagConfig) != 0 || packet.Data.Length == 0) return;
        _channel.Writer.TryWrite(packet);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _channel.Writer.TryComplete();
        _cts.Cancel();
    }

    private async Task PlayLoopAsync()
    {
        OpenUUNativeMethods.openuu_media_startup();

        IntPtr aacDec = IntPtr.Zero;
        IntPtr waveOut = IntPtr.Zero;
        int activeSr = 0;
        int activeCh = 0;
        var pcmScratch = new short[8192];

        try
        {
            var reader = _channel.Reader;
            while (await reader.WaitToReadAsync(_cts.Token).ConfigureAwait(false))
            {
                while (reader.TryRead(out var pkt))
                {
                    if (_cts.IsCancellationRequested) break;
                    if (_resetRequested)
                    {
                        _resetRequested = false;
                        if (waveOut != IntPtr.Zero)
                            OpenUUNativeMethods.openuu_waveout_reset(waveOut);
                    }
                    if (_isMuted || pkt.Data.Length == 0) continue;

                    int sr = pkt.SampleRate > 0 ? (int)pkt.SampleRate : 48_000;
                    int ch = Math.Clamp((int)pkt.Channels, 1, 2);

                    if (sr != activeSr || ch != activeCh)
                    {
                        if (waveOut != IntPtr.Zero)
                        {
                            OpenUUNativeMethods.openuu_waveout_destroy(waveOut);
                            waveOut = IntPtr.Zero;
                        }
                        if (aacDec != IntPtr.Zero)
                        {
                            OpenUUNativeMethods.openuu_aac_decoder_destroy(aacDec);
                            aacDec = IntPtr.Zero;
                        }
                        activeSr = sr;
                        activeCh = ch;
                    }

                    if (waveOut == IntPtr.Zero)
                    {
                        waveOut = OpenUUNativeMethods.openuu_waveout_create(sr, ch);
                    }

                    DecodeAndSubmitPacket(ref aacDec, waveOut, pkt, sr, ch, pcmScratch);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            OpenUULogger.Shared.Warn("AUDIO", $"AudioStreamPlayer loop error: {ex.Message}");
        }
        finally
        {
            if (waveOut != IntPtr.Zero)
                OpenUUNativeMethods.openuu_waveout_destroy(waveOut);
            if (aacDec != IntPtr.Zero)
                OpenUUNativeMethods.openuu_aac_decoder_destroy(aacDec);
        }
    }

    private unsafe void DecodeAndSubmitPacket(
        ref IntPtr aacDec,
        IntPtr waveOut,
        EncodedAudioPacket pkt,
        int sr,
        int ch,
        short[] pcmScratch
    )
    {
        if (pkt.Codec == CodecAacLc)
        {
            if (aacDec == IntPtr.Zero)
            {
                aacDec = OpenUUNativeMethods.openuu_aac_decoder_create(sr, ch);
                if (aacDec == IntPtr.Zero) return;
            }

            int decodedSamples;
            fixed (byte* pIn = pkt.Data)
            fixed (short* pOut = pcmScratch)
            {
                decodedSamples = OpenUUNativeMethods.openuu_aac_decoder_decode_pcm16(
                    aacDec,
                    pIn,
                    pkt.Data.Length,
                    pkt.TimestampUs,
                    pOut,
                    pcmScratch.Length
                );
            }
            if (decodedSamples > 0)
            {
                long count = Interlocked.Increment(ref _totalDecodedAudioFrames);
                if (count == 1 || count == 3)
                    OpenUULogger.Shared.Debug("AUDIO", $"decoded_audio_frames={count} codec=AAC-LC samples={decodedSamples}");

                if (waveOut != IntPtr.Zero)
                {
                    fixed (short* pOut = pcmScratch)
                    {
                        OpenUUNativeMethods.openuu_waveout_submit_pcm16(waveOut, pOut, decodedSamples);
                    }
                }
            }
        }
        else if (pkt.Codec == CodecPcmS16Le)
        {
            int sampleCount = Math.Min(pkt.Data.Length / sizeof(short), pcmScratch.Length);
            if (sampleCount > 0)
            {
                long count = Interlocked.Increment(ref _totalDecodedAudioFrames);
                if (count == 1 || count == 3)
                    OpenUULogger.Shared.Debug("AUDIO", $"decoded_audio_frames={count} codec=PCM16 samples={sampleCount}");

                if (waveOut != IntPtr.Zero)
                {
                    Buffer.BlockCopy(pkt.Data, 0, pcmScratch, 0, sampleCount * sizeof(short));
                    fixed (short* pOut = pcmScratch)
                    {
                        OpenUUNativeMethods.openuu_waveout_submit_pcm16(waveOut, pOut, sampleCount);
                    }
                }
            }
        }
    }
}

package ren.onekb.openuu

import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Process
import android.util.Log
import java.nio.ByteBuffer
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Low-latency hardware/native audio stream decoder & player for Android (`StreamType::Audio` = 0x02).
 * Decodes AAC-LC (`codec = 3`) via `MediaCodec` (`audio/mp4a-latm`) or raw PCM16 (`codec = 1`) into `AudioTrack`
 * with bounded queue shedding so remote audio stays tightly synchronized with live video.
 */
class AudioStreamPlayer {

    private companion object {
        const val TAG = "OpenUUAudio"
        const val CODEC_PCM_S16LE = 1
        const val CODEC_AAC_LC = 3
        const val AUDIO_FLAG_CONFIG = 0x02
        const val MAX_QUEUED_PACKETS = 20
    }

    private class AudioPacket(
        val isStopSignal: Boolean,
        val codec: Int = 0,
        val flags: Int = 0,
        val channels: Int = 2,
        val sampleRate: Int = 48_000,
        val timestampUs: Long = 0L,
        val data: ByteArray = ByteArray(0)
    )

    private val queue = ArrayBlockingQueue<AudioPacket>(MAX_QUEUED_PACKETS + 4)
    private val muted = AtomicBoolean(false)
    private val released = AtomicBoolean(false)
    private val workerThread: Thread

    init {
        workerThread = Thread(::runLoop, "OpenUUAudioPlay").apply {
            isDaemon = true
            start()
        }
    }

    fun setMuted(isMuted: Boolean) {
        val prev = muted.getAndSet(isMuted)
        if (!prev && isMuted) {
            queue.clear()
            queue.offer(AudioPacket(isStopSignal = true))
        }
    }

    fun stop() {
        queue.clear()
        queue.offer(AudioPacket(isStopSignal = true))
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        queue.clear()
        queue.offer(AudioPacket(isStopSignal = true))
        workerThread.interrupt()
    }

    fun submitFrame(
        codec: Int,
        flags: Int,
        channels: Int,
        sampleRate: Int,
        timestampUs: Long,
        data: ByteArray
    ) {
        if (released.get() || muted.get()) return
        if ((flags and AUDIO_FLAG_CONFIG) != 0 || data.isEmpty()) return

        // Drop oldest packet on burst jitter so audio latency never exceeds ~250ms
        while (queue.size >= MAX_QUEUED_PACKETS) {
            queue.poll()
        }
        queue.offer(
            AudioPacket(
                isStopSignal = false,
                codec = codec,
                flags = flags,
                channels = channels.coerceIn(1, 2),
                sampleRate = if (sampleRate > 0) sampleRate else 48_000,
                timestampUs = timestampUs,
                data = data
            )
        )
    }

    private fun runLoop() {
        runCatching {
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)
        }

        var decoder: MediaCodec? = null
        var audioTrack: AudioTrack? = null
        var decSampleRate = 0
        var decChannels = 0
        var trackSampleRate = 0
        var trackChannels = 0
        var trackEncoding = AudioFormat.ENCODING_PCM_16BIT
        val bufferInfo = MediaCodec.BufferInfo()

        fun releasePipeline() {
            runCatching {
                audioTrack?.pause()
                audioTrack?.flush()
                audioTrack?.release()
            }
            audioTrack = null
            trackSampleRate = 0
            trackChannels = 0

            runCatching {
                decoder?.stop()
                decoder?.release()
            }
            decoder = null
            decSampleRate = 0
            decChannels = 0
        }

        fun ensureAudioTrack(sr: Int, ch: Int, pcmEncoding: Int): AudioTrack? {
            if (audioTrack != null && trackSampleRate == sr && trackChannels == ch && trackEncoding == pcmEncoding) {
                return audioTrack
            }
            runCatching {
                audioTrack?.pause()
                audioTrack?.flush()
                audioTrack?.release()
            }
            audioTrack = null

            val channelMask = if (ch == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO
            val minBuf = AudioTrack.getMinBufferSize(sr, channelMask, pcmEncoding)
            if (minBuf <= 0) return null
            val targetBuf = (minBuf * 2).coerceAtLeast(4096)

            return try {
                val track = AudioTrack.Builder()
                    .setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_MEDIA)
                            .setContentType(AudioAttributes.CONTENT_TYPE_MOVIE)
                            .build()
                    )
                    .setAudioFormat(
                        AudioFormat.Builder()
                            .setSampleRate(sr)
                            .setChannelMask(channelMask)
                            .setEncoding(pcmEncoding)
                            .build()
                    )
                    .setTransferMode(AudioTrack.MODE_STREAM)
                    .setPerformanceMode(AudioTrack.PERFORMANCE_MODE_LOW_LATENCY)
                    .setBufferSizeInBytes(targetBuf)
                    .build()
                track.play()
                audioTrack = track
                trackSampleRate = sr
                trackChannels = ch
                trackEncoding = pcmEncoding
                track
            } catch (t: Throwable) {
                Log.w(TAG, "AudioTrack init failed: ${t.message}")
                null
            }
        }

        fun ensureAacDecoder(sr: Int, ch: Int): MediaCodec? {
            if (decoder != null && decSampleRate == sr && decChannels == ch) {
                return decoder
            }
            runCatching {
                decoder?.stop()
                decoder?.release()
            }
            decoder = null

            return try {
                val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sr, ch).apply {
                    setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                    setInteger(MediaFormat.KEY_IS_ADTS, 0)
                    setByteBuffer("csd-0", ByteBuffer.wrap(buildAacLcAudioSpecificConfig(sr, ch)))
                }
                val codec = MediaCodec.createDecoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
                codec.configure(format, null, null, 0)
                codec.start()
                decoder = codec
                decSampleRate = sr
                decChannels = ch
                codec
            } catch (t: Throwable) {
                Log.w(TAG, "AAC MediaCodec init failed: ${t.message}")
                null
            }
        }

        try {
            while (!released.get()) {
                val pkt = try {
                    queue.poll(250L, TimeUnit.MILLISECONDS)
                } catch (_: InterruptedException) {
                    if (released.get()) break
                    null
                } ?: continue

                if (pkt.isStopSignal || muted.get()) {
                    releasePipeline()
                    continue
                }

                when (pkt.codec) {
                    CODEC_PCM_S16LE -> {
                        val track = ensureAudioTrack(pkt.sampleRate, pkt.channels, AudioFormat.ENCODING_PCM_16BIT)
                        track?.write(pkt.data, 0, pkt.data.size, AudioTrack.WRITE_BLOCKING)
                    }
                    CODEC_AAC_LC -> {
                        val codec = ensureAacDecoder(pkt.sampleRate, pkt.channels) ?: continue
                        try {
                            val inIdx = codec.dequeueInputBuffer(8_000L)
                            if (inIdx >= 0) {
                                val inBuf = codec.getInputBuffer(inIdx)
                                if (inBuf != null) {
                                    inBuf.clear()
                                    val copyLen = pkt.data.size.coerceAtMost(inBuf.remaining())
                                    inBuf.put(pkt.data, 0, copyLen)
                                    codec.queueInputBuffer(inIdx, 0, copyLen, pkt.timestampUs, 0)
                                } else {
                                    codec.queueInputBuffer(inIdx, 0, 0, 0L, 0)
                                }
                            }

                            while (true) {
                                val outIdx = codec.dequeueOutputBuffer(bufferInfo, 2_000L)
                                if (outIdx == MediaCodec.INFO_TRY_AGAIN_LATER) {
                                    break
                                } else if (outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                                    val outFmt = codec.outputFormat
                                    val outSr = if (outFmt.containsKey(MediaFormat.KEY_SAMPLE_RATE)) {
                                        outFmt.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                                    } else {
                                        pkt.sampleRate
                                    }
                                    val outCh = if (outFmt.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                        outFmt.getInteger(MediaFormat.KEY_CHANNEL_COUNT).coerceIn(1, 2)
                                    } else {
                                        pkt.channels
                                    }
                                    val outEnc = if (outFmt.containsKey(MediaFormat.KEY_PCM_ENCODING)) {
                                        outFmt.getInteger(MediaFormat.KEY_PCM_ENCODING)
                                    } else {
                                        AudioFormat.ENCODING_PCM_16BIT
                                    }
                                    ensureAudioTrack(outSr, outCh, outEnc)
                                } else if (outIdx >= 0) {
                                    val outBuf = codec.getOutputBuffer(outIdx)
                                    if (outBuf != null && bufferInfo.size > 0 && !muted.get()) {
                                        val track = audioTrack
                                            ?: ensureAudioTrack(pkt.sampleRate, pkt.channels, AudioFormat.ENCODING_PCM_16BIT)
                                        if (track != null) {
                                            outBuf.position(bufferInfo.offset)
                                            outBuf.limit(bufferInfo.offset + bufferInfo.size)
                                            track.write(outBuf, bufferInfo.size, AudioTrack.WRITE_BLOCKING)
                                        }
                                    }
                                    codec.releaseOutputBuffer(outIdx, false)
                                } else {
                                    break
                                }
                            }
                        } catch (t: Throwable) {
                            Log.w(TAG, "AAC decode iteration error, resetting pipeline: ${t.message}")
                            releasePipeline()
                        }
                    }
                }
            }
        } finally {
            releasePipeline()
        }
    }

    private fun buildAacLcAudioSpecificConfig(sampleRate: Int, channels: Int): ByteArray {
        val freqIndex = when (sampleRate) {
            96_000 -> 0
            88_200 -> 1
            64_000 -> 2
            48_000 -> 3
            44_100 -> 4
            32_000 -> 5
            24_000 -> 6
            22_050 -> 7
            16_000 -> 8
            12_000 -> 9
            11_025 -> 10
            8_000 -> 11
            else -> 3 // 48,000 Hz default
        }
        val audioObjectType = 2 // AAC-LC
        val chCfg = channels.coerceIn(1, 7)
        val b0 = ((audioObjectType shl 3) or ((freqIndex shr 1) and 0x07)) and 0xFF
        val b1 = (((freqIndex and 0x01) shl 7) or ((chCfg and 0x0F) shl 3)) and 0xFF
        return byteArrayOf(b0.toByte(), b1.toByte())
    }
}

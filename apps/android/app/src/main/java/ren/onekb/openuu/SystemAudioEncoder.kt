package ren.onekb.openuu

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.Manifest
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.projection.MediaProjection
import android.os.Build
import android.os.Process
import android.util.Log
import androidx.core.content.ContextCompat
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Captures Android 10+ (`API 29+`) internal playback audio via [AudioPlaybackCaptureConfiguration]
 * and hardware-encodes 48kHz stereo raw AAC-LC frames (`codec = 3`) for OpenUU clients.
 */
class SystemAudioEncoder(
    private val context: Context,
    private val mediaProjection: MediaProjection,
    private val onEncodedAudio: (
        codec: Int,
        flags: Int,
        channels: Int,
        sampleRate: Int,
        timestampUs: Long,
        data: ByteArray
    ) -> Unit
) {
    companion object {
        private const val TAG = "OpenUUHostAudio"
        const val CODEC_AAC_LC = 3
        private const val SAMPLE_RATE = 48_000
        private const val CHANNELS = 2
        private const val BITRATE = 128_000
    }

    private val running = AtomicBoolean(false)
    private var workerThread: Thread? = null
    private var didMuteSpeaker = false

    val isActive: Boolean get() = running.get()

    fun start(muteHostSpeaker: Boolean): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val hasPerm = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (!hasPerm) {
            Log.i(TAG, "RECORD_AUDIO not granted; skipping internal audio capture")
            return false
        }
        if (!running.compareAndSet(false, true)) return true

        applyHostSpeakerMute(muteHostSpeaker)
        workerThread = Thread(::captureAndEncodeLoop, "OpenUUHostAudioEnc").apply {
            isDaemon = true
            start()
        }
        return true
    }

    fun updateMuteHost(muteHostSpeaker: Boolean) {
        if (!running.get()) return
        applyHostSpeakerMute(muteHostSpeaker)
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) {
            restoreSpeakerIfMuted()
            return
        }
        val wt = workerThread
        workerThread = null
        if (wt != null && wt !== Thread.currentThread()) {
            wt.interrupt()
            runCatching { wt.join(500L) }
        }
        restoreSpeakerIfMuted()
    }

    private fun applyHostSpeakerMute(shouldMute: Boolean) {
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        runCatching {
            if (shouldMute && !didMuteSpeaker) {
                am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
                didMuteSpeaker = true
            } else if (!shouldMute && didMuteSpeaker) {
                am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
                didMuteSpeaker = false
            }
        }
    }

    private fun restoreSpeakerIfMuted() {
        if (!didMuteSpeaker) return
        didMuteSpeaker = false
        val am = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager ?: return
        runCatching {
            am.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_UNMUTE, 0)
        }
    }

    @SuppressLint("MissingPermission")
    private fun captureAndEncodeLoop() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return
        runCatching { Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO) }

        var record: AudioRecord? = null
        var codec: MediaCodec? = null

        try {
            val captureCfg = AudioPlaybackCaptureConfiguration.Builder(mediaProjection)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()

            val minBuf = AudioRecord.getMinBufferSize(
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_STEREO,
                AudioFormat.ENCODING_PCM_16BIT
            )
            if (minBuf <= 0) {
                running.set(false)
                return
            }

            record = AudioRecord.Builder()
                .setAudioFormat(
                    AudioFormat.Builder()
                        .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                        .setSampleRate(SAMPLE_RATE)
                        .setChannelMask(AudioFormat.CHANNEL_IN_STEREO)
                        .build()
                )
                .setBufferSizeInBytes((minBuf * 2).coerceAtLeast(8192))
                .setAudioPlaybackCaptureConfig(captureCfg)
                .build()

            val fmt = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, SAMPLE_RATE, CHANNELS).apply {
                setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
                setInteger(MediaFormat.KEY_BIT_RATE, BITRATE)
                setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16_384)
            }
            codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
            codec.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            codec.start()
            record.startRecording()

            val pcmBuf = ByteArray(4096) // 1024 stereo 16-bit frames = 4096 bytes (~21.3ms)
            val info = MediaCodec.BufferInfo()
            var totalSamples = 0L

            while (running.get() && !Thread.currentThread().isInterrupted) {
                val readBytes = record.read(pcmBuf, 0, pcmBuf.size)
                if (readBytes > 0) {
                    val inIdx = codec.dequeueInputBuffer(8_000L)
                    if (inIdx >= 0) {
                        val inBuf = codec.getInputBuffer(inIdx)
                        if (inBuf != null) {
                            inBuf.clear()
                            val toCopy = readBytes.coerceAtMost(inBuf.remaining())
                            inBuf.put(pcmBuf, 0, toCopy)
                            val ptsUs = (totalSamples * 1_000_000L) / SAMPLE_RATE
                            totalSamples += (toCopy / (CHANNELS * 2))
                            codec.queueInputBuffer(inIdx, 0, toCopy, ptsUs, 0)
                        } else {
                            codec.queueInputBuffer(inIdx, 0, 0, 0L, 0)
                        }
                    }
                }

                while (true) {
                    val outIdx = codec.dequeueOutputBuffer(info, 0L)
                    if (outIdx < 0) break
                    try {
                        val isConfig = (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0
                        val outBuf = codec.getOutputBuffer(outIdx)
                        if (!isConfig && outBuf != null && info.size > 0) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            val raw = ByteArray(info.size)
                            outBuf.get(raw)
                            val stripped = stripAdtsIfPresent(raw)
                            if (stripped.isNotEmpty()) {
                                val ptsUs = if (info.presentationTimeUs > 0L) {
                                    info.presentationTimeUs
                                } else {
                                    System.nanoTime() / 1_000L
                                }
                                onEncodedAudio(CODEC_AAC_LC, 0, CHANNELS, SAMPLE_RATE, ptsUs, stripped)
                            }
                        }
                    } finally {
                        runCatching { codec.releaseOutputBuffer(outIdx, false) }
                    }
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "AudioPlaybackCapture stopped or unsupported: ${t.message}")
        } finally {
            running.set(false)
            runCatching { record?.stop() }
            runCatching { record?.release() }
            runCatching { codec?.stop() }
            runCatching { codec?.release() }
            restoreSpeakerIfMuted()
        }
    }

    private fun stripAdtsIfPresent(bytes: ByteArray): ByteArray {
        if (bytes.size > 7 && bytes[0] == 0xFF.toByte() && (bytes[1].toInt() and 0xF0) == 0xF0) {
            val protectionAbsent = bytes[1].toInt() and 0x01
            val headerLen = if (protectionAbsent == 1) 7 else 9
            if (bytes.size > headerLen) {
                return bytes.copyOfRange(headerLen, bytes.size)
            }
        }
        return bytes
    }
}

package ren.onekb.openuu

import android.media.MediaCodec
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

class VideoDecoderSurface(
    private val onTelemetry: (VideoTelemetry) -> Unit,
    private val onRequestKeyframe: () -> Unit
) {
    private companion object {
        const val TAG = "OpenUUVideoDecoder"
        const val CODEC_H264 = 1
        const val CODEC_HEVC = 2
        const val FLAG_KEYFRAME = 0x01
        val START_CODE_4 = byteArrayOf(0, 0, 0, 1)
    }

    private val handlerThread = HandlerThread("OpenUUVideoDecoder").apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val released = AtomicBoolean(false)

    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var configuredCodecType: Int = 0
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0

    // Cached Annex-B parameter sets (without start codes)
    private var cachedVps: ByteArray? = null
    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    private var waitingForKeyframe: Boolean = true

    // Live telemetry
    private var totalDecodedFrames: Long = 0L
    private var statsWindowStartMs: Long = 0L
    private var statsFramesInWindow: Int = 0
    private var statsBytesInWindow: Long = 0L
    private var lastTelemetryEmitMs: Long = 0L
    private var currentFps: Int = 0
    private var currentBitrateMbps: Double = 0.0

    fun attachSurface(newSurface: Surface?) {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            if (newSurface == null) {
                surface = null
                stopAndReleaseCodec()
                return@post
            }
            if (surface === newSurface && codec != null) {
                return@post
            }
            surface = newSurface
            stopAndReleaseCodec()
            waitingForKeyframe = true
            if (configuredCodecType != 0 && configuredWidth > 0 && configuredHeight > 0 && hasCachedCsd(configuredCodecType)) {
                configureCodecLocked(configuredCodecType, configuredWidth, configuredHeight)
            }
            onRequestKeyframe()
        }
    }

    fun resetStream() {
        if (released.get()) return
        handler.post {
            stopAndReleaseCodec()
            cachedVps = null
            cachedSps = null
            cachedPps = null
            configuredCodecType = 0
            configuredWidth = 0
            configuredHeight = 0
            waitingForKeyframe = true
            statsWindowStartMs = 0L
            statsFramesInWindow = 0
            statsBytesInWindow = 0L
            currentFps = 0
            currentBitrateMbps = 0.0
        }
    }

    fun submitFrame(
        codecType: Int,
        flags: Int,
        timestampUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    ) {
        if (released.get() || data.isEmpty()) return
        handler.post {
            if (released.get()) return@post
            processFrameOnThread(codecType, flags, timestampUs, width, height, data)
        }
    }

    fun release() {
        if (!released.compareAndSet(false, true)) return
        handler.post {
            surface = null
            stopAndReleaseCodec()
            handlerThread.quitSafely()
        }
    }

    private fun processFrameOnThread(
        codecType: Int,
        flags: Int,
        timestampUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    ) {
        val nalus = splitAnnexBNalus(data)
        if (nalus.isEmpty()) return

        var csdChanged = false
        var hasSlice = false
        var isIdr = (flags and FLAG_KEYFRAME) != 0

        if (codecType == CODEC_HEVC) {
            for (nalu in nalus) {
                if (nalu.isEmpty()) continue
                val naluType = (nalu[0].toInt() shr 1) and 0x3F
                when (naluType) {
                    32 -> if (cachedVps == null || !cachedVps.contentEquals(nalu)) {
                        cachedVps = nalu
                        csdChanged = true
                    }
                    33 -> if (cachedSps == null || !cachedSps.contentEquals(nalu)) {
                        cachedSps = nalu
                        csdChanged = true
                    }
                    34 -> if (cachedPps == null || !cachedPps.contentEquals(nalu)) {
                        cachedPps = nalu
                        csdChanged = true
                    }
                    in 16..21 -> {
                        hasSlice = true
                        isIdr = true
                    }
                    in 0..9 -> {
                        hasSlice = true
                    }
                }
            }
        } else {
            for (nalu in nalus) {
                if (nalu.isEmpty()) continue
                val naluType = nalu[0].toInt() and 0x1F
                when (naluType) {
                    7 -> if (cachedSps == null || !cachedSps.contentEquals(nalu)) {
                        cachedSps = nalu
                        csdChanged = true
                    }
                    8 -> if (cachedPps == null || !cachedPps.contentEquals(nalu)) {
                        cachedPps = nalu
                        csdChanged = true
                    }
                    5 -> {
                        hasSlice = true
                        isIdr = true
                    }
                    1 -> {
                        hasSlice = true
                    }
                }
            }
        }

        val safeW = if (width > 0) width else configuredWidth.coerceAtLeast(1280)
        val safeH = if (height > 0) height else configuredHeight.coerceAtLeast(720)
        val needsReconfigure = codec == null ||
            codecType != configuredCodecType ||
            safeW != configuredWidth ||
            safeH != configuredHeight ||
            csdChanged

        if (needsReconfigure) {
            if (!hasCachedCsd(codecType) || surface == null || surface?.isValid != true) {
                configuredCodecType = codecType
                configuredWidth = safeW
                configuredHeight = safeH
                return
            }
            if (!configureCodecLocked(codecType, safeW, safeH)) {
                return
            }
        }

        if (!hasSlice) return

        if (waitingForKeyframe) {
            if (!isIdr) {
                return
            }
            waitingForKeyframe = false
        }

        val activeCodec = codec ?: return
        val nowMs = System.currentTimeMillis()
        if (statsWindowStartMs == 0L) {
            statsWindowStartMs = nowMs
        }
        statsBytesInWindow += data.size

        try {
            val inIdx = activeCodec.dequeueInputBuffer(10_000L)
            if (inIdx >= 0) {
                val inputBuf = activeCodec.getInputBuffer(inIdx)
                if (inputBuf != null) {
                    inputBuf.clear()
                    if (inputBuf.capacity() < data.size) {
                        Log.w(TAG, "Frame larger than MediaCodec input buffer (${data.size} > ${inputBuf.capacity()})")
                        activeCodec.queueInputBuffer(inIdx, 0, 0, timestampUs, 0)
                    } else {
                        inputBuf.put(data)
                        val bufFlags = if (isIdr) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                        activeCodec.queueInputBuffer(inIdx, 0, data.size, timestampUs, bufFlags)
                    }
                }
            }
            drainOutputLocked(activeCodec, codecType, safeW, safeH)
        } catch (e: Throwable) {
            Log.e(TAG, "MediaCodec decode error, resetting decoder", e)
            stopAndReleaseCodec()
            waitingForKeyframe = true
            onRequestKeyframe()
        }
    }

    private fun drainOutputLocked(
        activeCodec: MediaCodec,
        codecType: Int,
        width: Int,
        height: Int
    ) {
        val info = MediaCodec.BufferInfo()
        val initialTimeoutUs = if (totalDecodedFrames < 5) 4_000L else 0L
        var timeoutUs = initialTimeoutUs
        while (true) {
            val outIdx = activeCodec.dequeueOutputBuffer(info, timeoutUs)
            timeoutUs = 0L
            when {
                outIdx >= 0 -> {
                    val isVideoFrame = (info.flags and (MediaCodec.BUFFER_FLAG_CODEC_CONFIG or MediaCodec.BUFFER_FLAG_END_OF_STREAM)) == 0
                    val render = isVideoFrame && surface?.isValid == true
                    activeCodec.releaseOutputBuffer(outIdx, render)
                    if (render) {
                        totalDecodedFrames++
                        statsFramesInWindow++
                        if (totalDecodedFrames == 1L || totalDecodedFrames == 5L || totalDecodedFrames % 50L == 0L) {
                            Log.i(TAG, "decoded_frames=$totalDecodedFrames ${width}x${height}")
                        }
                        maybeEmitTelemetry(codecType, width, height)
                    }
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.i(TAG, "Output format changed: ${activeCodec.outputFormat}")
                }
                else -> break
            }
        }
    }

    private fun maybeEmitTelemetry(codecType: Int, width: Int, height: Int) {
        val now = System.currentTimeMillis()
        val elapsedMs = (now - statsWindowStartMs).coerceAtLeast(1L)
        if (elapsedMs >= 1000L) {
            currentFps = ((statsFramesInWindow * 1000.0) / elapsedMs).toInt()
            currentBitrateMbps = (statsBytesInWindow * 8.0) / (elapsedMs * 1000.0)
            statsWindowStartMs = now
            statsFramesInWindow = 0
            statsBytesInWindow = 0L
        }
        val shouldEmit = totalDecodedFrames <= 5L || (now - lastTelemetryEmitMs) >= 500L
        if (shouldEmit) {
            lastTelemetryEmitMs = now
            val codecLabel = if (codecType == CODEC_HEVC) "HEVC" else "H.264"
            onTelemetry(
                VideoTelemetry(
                    codec = codecLabel,
                    fps = if (currentFps > 0) currentFps else statsFramesInWindow,
                    bitrateMbps = currentBitrateMbps,
                    width = width,
                    height = height,
                    decodedFrames = totalDecodedFrames
                )
            )
        }
    }

    private fun hasCachedCsd(codecType: Int): Boolean {
        return if (codecType == CODEC_HEVC) {
            cachedVps != null && cachedSps != null && cachedPps != null
        } else {
            cachedSps != null && cachedPps != null
        }
    }

    private fun configureCodecLocked(codecType: Int, width: Int, height: Int): Boolean {
        val targetSurface = surface
        if (targetSurface == null || !targetSurface.isValid) return false
        stopAndReleaseCodec()

        val mime = if (codecType == CODEC_HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        fun buildFormat(withLowLatency: Boolean): MediaFormat {
            val fmt = MediaFormat.createVideoFormat(mime, width, height)
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (withLowLatency && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
            }
            if (codecType == CODEC_HEVC) {
                val out = ByteArrayOutputStream()
                cachedVps?.let { out.write(START_CODE_4); out.write(it) }
                cachedSps?.let { out.write(START_CODE_4); out.write(it) }
                cachedPps?.let { out.write(START_CODE_4); out.write(it) }
                fmt.setByteBuffer("csd-0", ByteBuffer.wrap(out.toByteArray()))
            } else {
                cachedSps?.let { sps ->
                    val b = ByteArray(4 + sps.size)
                    System.arraycopy(START_CODE_4, 0, b, 0, 4)
                    System.arraycopy(sps, 0, b, 4, sps.size)
                    fmt.setByteBuffer("csd-0", ByteBuffer.wrap(b))
                }
                cachedPps?.let { pps ->
                    val b = ByteArray(4 + pps.size)
                    System.arraycopy(START_CODE_4, 0, b, 0, 4)
                    System.arraycopy(pps, 0, b, 4, pps.size)
                    fmt.setByteBuffer("csd-1", ByteBuffer.wrap(b))
                }
            }
            return fmt
        }

        return try {
            var mc = MediaCodec.createDecoderByType(mime)
            try {
                mc.configure(buildFormat(withLowLatency = true), targetSurface, null, 0)
            } catch (e: Throwable) {
                Log.w(TAG, "Low-latency configure failed, retrying standard format", e)
                try {
                    mc.release()
                } catch (_: Throwable) {
                }
                mc = MediaCodec.createDecoderByType(mime)
                mc.configure(buildFormat(withLowLatency = false), targetSurface, null, 0)
            }
            mc.start()
            codec = mc
            configuredCodecType = codecType
            configuredWidth = width
            configuredHeight = height
            waitingForKeyframe = true
            Log.i(TAG, "Configured $mime decoder ${width}x${height} (${mc.name})")
            true
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to configure MediaCodec for $mime ${width}x${height}", e)
            stopAndReleaseCodec()
            false
        }
    }

    private fun stopAndReleaseCodec() {
        val active = codec ?: return
        codec = null
        try {
            active.stop()
        } catch (_: Throwable) {
        }
        try {
            active.release()
        } catch (_: Throwable) {
        }
    }

    private fun splitAnnexBNalus(data: ByteArray): List<ByteArray> {
        val starts = ArrayList<Int>(8)
        val lengths = ArrayList<Int>(8)
        var i = 0
        val n = data.size
        while (i + 3 <= n) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (i + 3 < n && data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    starts.add(i)
                    lengths.add(4)
                    i += 4
                    continue
                } else if (data[i + 2] == 1.toByte()) {
                    starts.add(i)
                    lengths.add(3)
                    i += 3
                    continue
                }
            }
            i++
        }
        if (starts.isEmpty()) return emptyList()
        val result = ArrayList<ByteArray>(starts.size)
        for (idx in starts.indices) {
            val payloadStart = starts[idx] + lengths[idx]
            val payloadEnd = if (idx + 1 < starts.size) starts[idx + 1] else n
            if (payloadEnd > payloadStart) {
                result.add(data.copyOfRange(payloadStart, payloadEnd))
            }
        }
        return result
    }
}

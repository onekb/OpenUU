package ren.onekb.openuu

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
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
    private val isPopover: Boolean = false,
    private val onTelemetry: (VideoTelemetry) -> Unit,
    private val onRequestKeyframe: () -> Unit,
    private val onFirstFrameRendered: (() -> Unit)? = null
) {
    private companion object {
        const val TAG = "OpenUUVideoDecoder"
        const val CODEC_H264 = 1
        const val CODEC_HEVC = 2
        const val FLAG_KEYFRAME = 0x01
        const val MAX_CACHED_GOP_FRAMES = 16
        const val MAX_FIRST_FRAME_BUMPS = 4
        val START_CODE_4 = byteArrayOf(0, 0, 0, 1)
    }

    private class CachedEncodedFrame(
        val codecType: Int,
        val flags: Int,
        val timestampUs: Long,
        val width: Int,
        val height: Int,
        val data: ByteArray,
        val isIdr: Boolean
    )

    private val handlerThread = HandlerThread(
        if (isPopover) "OpenUUPopoverDecoder" else "OpenUUVideoDecoder"
    ).apply { start() }
    private val handler = Handler(handlerThread.looper)
    private val released = AtomicBoolean(false)

    private var surface: Surface? = null
    private var codec: MediaCodec? = null
    private var configuredCodecType: Int = 0
    private var configuredWidth: Int = 0
    private var configuredHeight: Int = 0

    // Cached Annex-B parameter sets (without start codes) & latest GOP for instant Surface replay
    private var cachedVps: ByteArray? = null
    private var cachedSps: ByteArray? = null
    private var cachedPps: ByteArray? = null
    private val cachedGop = ArrayList<CachedEncodedFrame>(8)
    private var waitingForKeyframe: Boolean = true
    private var firstFrameNotified: Boolean = false
    private var firstFrameBumpCount: Int = 0
    private var lastQueuedPtsUs: Long = 0L

    // Live telemetry
    private var totalDecodedFrames: Long = 0L
    private var statsWindowStartMs: Long = 0L
    private var statsFramesInWindow: Int = 0
    private var statsBytesInWindow: Long = 0L
    private var lastTelemetryEmitMs: Long = 0L
    private var currentFps: Int = 0
    private var currentBitrateMbps: Double = 0.0

    private val firstFrameFlushRunnable = object : Runnable {
        override fun run() {
            if (released.get()) return
            val activeCodec = codec ?: return
            val targetSurface = surface
            if (targetSurface == null || !targetSurface.isValid || totalDecodedFrames > 0L) return

            try {
                drainOutputLocked(activeCodec, configuredCodecType, configuredWidth, configuredHeight)
                if (totalDecodedFrames > 0L) return

                // Static right-click menus often emit only 1 single IDR frame before SCStream goes .idle.
                // Many Android H.264/HEVC decoders hold 1 picture in their DPB reorder buffer until a 2nd
                // access unit arrives. Feeding a duplicate of that self-contained IDR picture bumps the
                // held picture out to the Surface immediately while preserving identical DPB reference state!
                val soleIdr = cachedGop.firstOrNull()?.takeIf { cachedGop.size == 1 && it.isIdr }
                if (soleIdr != null && firstFrameBumpCount < MAX_FIRST_FRAME_BUMPS) {
                    firstFrameBumpCount++
                    val bumpPts = lastQueuedPtsUs + 16_666L
                    queueRawSliceLocked(activeCodec, soleIdr.data, bumpPts, isIdr = true)
                    drainOutputLocked(activeCodec, configuredCodecType, configuredWidth, configuredHeight)
                }

                if (totalDecodedFrames == 0L && firstFrameBumpCount < MAX_FIRST_FRAME_BUMPS) {
                    val delayMs = when (firstFrameBumpCount) {
                        0, 1 -> 12L
                        2 -> 24L
                        else -> 45L
                    }
                    handler.postDelayed(this, delayMs)
                }
            } catch (e: Throwable) {
                Log.w(TAG, "First-frame DPB flush error", e)
            }
        }
    }

    private fun cancelFirstFrameFlush() {
        handler.removeCallbacks(firstFrameFlushRunnable)
        firstFrameBumpCount = 0
    }

    private fun scheduleFirstFrameFlushIfNeeded() {
        if (totalDecodedFrames > 0L || codec == null || surface?.isValid != true) return
        handler.removeCallbacks(firstFrameFlushRunnable)
        handler.postDelayed(firstFrameFlushRunnable, 8L)
    }

    fun attachSurface(newSurface: Surface?) {
        if (released.get()) return
        handler.post {
            if (released.get()) return@post
            if (newSurface == null) {
                surface = null
                cancelFirstFrameFlush()
                stopAndReleaseCodec()
                return@post
            }
            if (surface === newSurface && codec != null) {
                return@post
            }
            surface = newSurface
            firstFrameNotified = false
            totalDecodedFrames = 0L
            cancelFirstFrameFlush()
            stopAndReleaseCodec()
            waitingForKeyframe = true

            if (configuredCodecType != 0 && configuredWidth > 0 && configuredHeight > 0 && hasCachedCsd(configuredCodecType)) {
                if (configureCodecLocked(configuredCodecType, configuredWidth, configuredHeight)) {
                    replayCachedGopLocked()
                }
            }
            onRequestKeyframe()
        }
    }

    fun resetStream() {
        if (released.get()) return
        handler.post {
            cancelFirstFrameFlush()
            stopAndReleaseCodec()
            cachedVps = null
            cachedSps = null
            cachedPps = null
            cachedGop.clear()
            configuredCodecType = 0
            configuredWidth = 0
            configuredHeight = 0
            waitingForKeyframe = true
            firstFrameNotified = false
            totalDecodedFrames = 0L
            lastQueuedPtsUs = 0L
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
            cancelFirstFrameFlush()
            surface = null
            cachedGop.clear()
            stopAndReleaseCodec()
            handlerThread.quitSafely()
        }
    }

    private fun replayCachedGopLocked() {
        val activeCodec = codec ?: return
        if (cachedGop.isEmpty()) return
        for (frame in cachedGop) {
            if (waitingForKeyframe) {
                if (!frame.isIdr) continue
                waitingForKeyframe = false
            }
            try {
                queueRawSliceLocked(activeCodec, frame.data, frame.timestampUs, frame.isIdr)
                drainOutputLocked(activeCodec, frame.codecType, frame.width, frame.height)
            } catch (e: Throwable) {
                Log.w(TAG, "Cached GOP replay error", e)
                break
            }
        }
        scheduleFirstFrameFlushIfNeeded()
    }

    private fun queueRawSliceLocked(
        activeCodec: MediaCodec,
        data: ByteArray,
        timestampUs: Long,
        isIdr: Boolean
    ): Boolean {
        val inIdx = activeCodec.dequeueInputBuffer(12_000L)
        if (inIdx < 0) return false
        val inputBuf = activeCodec.getInputBuffer(inIdx) ?: return false
        inputBuf.clear()
        return if (inputBuf.capacity() < data.size) {
            Log.w(TAG, "Frame larger than MediaCodec input buffer (${data.size} > ${inputBuf.capacity()})")
            activeCodec.queueInputBuffer(inIdx, 0, 0, timestampUs, 0)
            false
        } else {
            inputBuf.put(data)
            val safePts = if (timestampUs > lastQueuedPtsUs) timestampUs else (lastQueuedPtsUs + 1_000L)
            lastQueuedPtsUs = safePts
            val bufFlags = if (isIdr) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
            activeCodec.queueInputBuffer(inIdx, 0, data.size, safePts, bufFlags)
            true
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

        val safeW = if (width > 0) width else configuredWidth.coerceAtLeast(if (isPopover) 160 else 1280)
        val safeH = if (height > 0) height else configuredHeight.coerceAtLeast(if (isPopover) 120 else 720)

        // Always cache the latest GOP BEFORE checking Surface readiness so static 1-frame right-click menus
        // whose packet arrives before Compose finishes attaching SurfaceTexture are replayed immediately!
        if (hasSlice) {
            if (isIdr || csdChanged || safeW != configuredWidth || safeH != configuredHeight) {
                cachedGop.clear()
                cachedGop.add(
                    CachedEncodedFrame(
                        codecType = codecType,
                        flags = flags,
                        timestampUs = timestampUs,
                        width = safeW,
                        height = safeH,
                        data = data.copyOf(),
                        isIdr = isIdr
                    )
                )
            } else if (cachedGop.isNotEmpty() && cachedGop.size < MAX_CACHED_GOP_FRAMES) {
                cachedGop.add(
                    CachedEncodedFrame(
                        codecType = codecType,
                        flags = flags,
                        timestampUs = timestampUs,
                        width = safeW,
                        height = safeH,
                        data = data.copyOf(),
                        isIdr = false
                    )
                )
            }
        }

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
            queueRawSliceLocked(activeCodec, data, timestampUs, isIdr)
            drainOutputLocked(activeCodec, codecType, safeW, safeH)
            scheduleFirstFrameFlushIfNeeded()
        } catch (e: Throwable) {
            Log.e(TAG, "MediaCodec decode error, resetting decoder", e)
            cancelFirstFrameFlush()
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
        var timeoutUs = when {
            totalDecodedFrames == 0L -> 8_000L
            totalDecodedFrames < 5L -> 3_000L
            else -> 0L
        }
        while (true) {
            val outIdx = activeCodec.dequeueOutputBuffer(info, timeoutUs)
            when {
                outIdx >= 0 -> {
                    timeoutUs = 0L
                    val isVideoFrame = (info.flags and (MediaCodec.BUFFER_FLAG_CODEC_CONFIG or MediaCodec.BUFFER_FLAG_END_OF_STREAM)) == 0
                    val render = isVideoFrame && surface?.isValid == true
                    activeCodec.releaseOutputBuffer(outIdx, render)
                    if (render) {
                        totalDecodedFrames++
                        statsFramesInWindow++
                        if (!firstFrameNotified) {
                            firstFrameNotified = true
                            cancelFirstFrameFlush()
                            onFirstFrameRendered?.invoke()
                        }
                        if (totalDecodedFrames == 1L || totalDecodedFrames == 5L || totalDecodedFrames % 50L == 0L) {
                            Log.i(TAG, "decoded_frames=$totalDecodedFrames ${width}x${height} popover=$isPopover")
                        }
                        maybeEmitTelemetry(codecType, width, height)
                    }
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    Log.i(TAG, "Output format changed: ${activeCodec.outputFormat}")
                    // Keep non-zero timeout right after format change when awaiting the very first frame!
                    timeoutUs = if (totalDecodedFrames == 0L) 8_000L else 0L
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

    private fun findPreferredDecoderName(mime: String, width: Int, height: Int): String? {
        return runCatching {
            val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            var swCandidate: String? = null
            var hwSupportsSize = false

            for (info in infos) {
                if (info.isEncoder) continue
                if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) continue
                val nameLower = info.name.lowercase()
                val isSw = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    info.isSoftwareOnly
                } else {
                    nameLower.startsWith("c2.android.") || nameLower.startsWith("omx.google.")
                }
                val sizeOk = runCatching {
                    info.getCapabilitiesForType(mime)?.videoCapabilities?.isSizeSupported(width, height) ?: true
                }.getOrDefault(true)

                if (isSw) {
                    if (swCandidate == null && sizeOk) {
                        swCandidate = info.name
                    }
                } else if (sizeOk) {
                    hwSupportsSize = true
                }
            }

            // Use Android's official C2 software decoder for compact popovers/menus (avoids VPU session contention
            // and small-dimension rejections on Qualcomm/MTK hardware decoders) or when hardware rejects the size.
            if (isPopover || !hwSupportsSize) swCandidate else null
        }.getOrNull()
    }

    private fun configureCodecLocked(codecType: Int, width: Int, height: Int): Boolean {
        val targetSurface = surface
        if (targetSurface == null || !targetSurface.isValid) return false
        cancelFirstFrameFlush()
        stopAndReleaseCodec()

        val mime = if (codecType == CODEC_HEVC) MediaFormat.MIMETYPE_VIDEO_HEVC else MediaFormat.MIMETYPE_VIDEO_AVC
        fun buildFormat(withLowLatency: Boolean): MediaFormat {
            val fmt = MediaFormat.createVideoFormat(mime, width, height)
            fmt.setInteger(MediaFormat.KEY_PRIORITY, 0)
            fmt.setInteger(MediaFormat.KEY_OPERATING_RATE, Short.MAX_VALUE.toInt())
            if (withLowLatency) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    fmt.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                }
                fmt.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                fmt.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
                fmt.setInteger("vendor.mtk-ext-dec-low-latency.enable", 1)
                fmt.setInteger("vendor.hisi-ext-low-latency-video-dec.video-scene-for-low-latency-req", 1)
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

        val preferredName = findPreferredDecoderName(mime, width, height)

        fun instantiateDecoder(byName: String?): MediaCodec {
            return if (byName != null) {
                MediaCodec.createByCodecName(byName)
            } else {
                MediaCodec.createDecoderByType(mime)
            }
        }

        fun tryConfigureAndStart(byName: String?): MediaCodec? {
            return try {
                var mc = instantiateDecoder(byName)
                try {
                    mc.configure(buildFormat(withLowLatency = true), targetSurface, null, 0)
                } catch (e: Throwable) {
                    runCatching { mc.release() }
                    mc = instantiateDecoder(byName)
                    mc.configure(buildFormat(withLowLatency = false), targetSurface, null, 0)
                }
                mc.start()
                mc
            } catch (e: Throwable) {
                Log.w(TAG, "Configure failed for decoder=${byName ?: mime} ${width}x${height}", e)
                null
            }
        }

        val started = (if (preferredName != null) tryConfigureAndStart(preferredName) else null)
            ?: tryConfigureAndStart(null)
        if (started == null) {
            Log.e(TAG, "Failed to configure any MediaCodec for $mime ${width}x${height}")
            stopAndReleaseCodec()
            return false
        }

        codec = started
        configuredCodecType = codecType
        configuredWidth = width
        configuredHeight = height
        waitingForKeyframe = true
        lastQueuedPtsUs = 0L
        Log.i(TAG, "Configured $mime decoder ${width}x${height} (${started.name}) popover=$isPopover")
        return true
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

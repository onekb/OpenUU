package ren.onekb.openuu

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.Surface
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Low-latency H.264 Annex-B Surface encoder for Android Host screen sharing.
 *
 * Outputs Annex-B packets (`codec = 1`) where every IDR keyframe (`flags = 0x01`) is guaranteed
 * to carry prepended Annex-B SPS/PPS parameter sets so macOS, Windows, iOS, and Android decoders
 * can lock onto the stream immediately without waiting for out-of-band CSD.
 */
class ScreenCaptureEncoder(
    val width: Int,
    val height: Int,
    private val fps: Int = 45,
    private val bitrateBps: Int = 4_500_000,
    private val useSyntheticFrames: Boolean = false,
    private val onEncodedPacket: (
        codec: Int,
        flags: Int,
        timestampUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    ) -> Unit
) {
    companion object {
        private const val TAG = "OpenUUScreenEnc"
        const val CODEC_H264 = 1
        const val FLAG_KEYFRAME = 0x01
        private val ANNEX_B_START = byteArrayOf(0, 0, 0, 1)

        fun computeAlignedEncodeSize(physW: Int, physH: Int, maxLongEdge: Int = 1600): Pair<Int, Int> {
            val safeW = physW.coerceAtLeast(320)
            val safeH = physH.coerceAtLeast(320)
            val longEdge = maxOf(safeW, safeH)
            val scale = if (longEdge > maxLongEdge) maxLongEdge.toFloat() / longEdge.toFloat() else 1f
            val alignedW = (((safeW * scale).toInt() + 8) / 16 * 16).coerceIn(256, 2560)
            val alignedH = (((safeH * scale).toInt() + 8) / 16 * 16).coerceIn(256, 2560)
            return alignedW to alignedH
        }
    }

    private val running = AtomicBoolean(false)
    private val pendingSyncRequest = AtomicBoolean(false)
    private val activeBitrate = AtomicInteger(bitrateBps)

    @Volatile
    var inputSurface: Surface? = null
        private set

    private var encoder: MediaCodec? = null
    private var drainThread: Thread? = null
    private var syntheticThread: Thread? = null

    private val csdLock = Any()
    private var cachedAnnexBCsd: ByteArray? = null
    private var latestCompleteIdr: ByteArray? = null

    fun start(): Surface? {
        if (!running.compareAndSet(false, true)) return inputSurface

        val createdCodec = configureAndStartEncoder()
        if (createdCodec == null) {
            running.set(false)
            return null
        }

        val surface = inputSurface
        drainThread = Thread(::drainLoop, "OpenUUScreenEncDrain").apply {
            isDaemon = true
            start()
        }

        if (useSyntheticFrames && surface != null) {
            syntheticThread = Thread({ runSyntheticPainter(surface) }, "OpenUUSyntheticCap").apply {
                isDaemon = true
                start()
            }
        }
        return surface
    }

    fun requestKeyframe() {
        pendingSyncRequest.set(true)
        val enc = encoder
        if (enc != null) {
            runCatching {
                val params = Bundle().apply {
                    putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0)
                }
                enc.setParameters(params)
            }
        }
        // Immediately replay cached IDR so static screens paint in <10ms without waiting for next VSync change
        val replay = synchronized(csdLock) { latestCompleteIdr }
        if (replay != null && running.get()) {
            val nowUs = System.nanoTime() / 1_000L
            onEncodedPacket(CODEC_H264, FLAG_KEYFRAME, nowUs, width, height, replay)
        }
    }

    fun updateBitrate(newBitrateBps: Int) {
        val clamped = newBitrateBps.coerceIn(800_000, 12_000_000)
        if (activeBitrate.getAndSet(clamped) == clamped) return
        val enc = encoder ?: return
        runCatching {
            val params = Bundle().apply {
                putInt(MediaCodec.PARAMETER_KEY_VIDEO_BITRATE, clamped)
            }
            enc.setParameters(params)
        }
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        syntheticThread?.interrupt()
        syntheticThread = null

        val dt = drainThread
        drainThread = null
        if (dt != null && dt !== Thread.currentThread()) {
            runCatching { dt.join(600L) }
        }

        val enc = encoder
        encoder = null
        val surf = inputSurface
        inputSurface = null

        if (enc != null) {
            runCatching { enc.signalEndOfInputStream() }
            runCatching { enc.stop() }
            runCatching { enc.release() }
        }
        runCatching { surf?.release() }
    }

    private fun configureAndStartEncoder(): MediaCodec? {
        val mime = MediaFormat.MIMETYPE_VIDEO_AVC
        val candidates = buildEncoderCandidateNames(mime, width, height)

        for (candidateName in candidates) {
            for (lowLatency in listOf(true, false)) {
                var mc: MediaCodec? = null
                var surf: Surface? = null
                try {
                    mc = if (candidateName != null) {
                        MediaCodec.createByCodecName(candidateName)
                    } else {
                        MediaCodec.createEncoderByType(mime)
                    }
                    val fmt = MediaFormat.createVideoFormat(mime, width, height).apply {
                        setInteger(
                            MediaFormat.KEY_COLOR_FORMAT,
                            MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                        )
                        setInteger(MediaFormat.KEY_BIT_RATE, activeBitrate.get())
                        setInteger(MediaFormat.KEY_FRAME_RATE, fps)
                        setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                        setLong(MediaFormat.KEY_REPEAT_PREVIOUS_FRAME_AFTER, 100_000L)
                        if (lowLatency) {
                            setInteger(MediaFormat.KEY_MAX_B_FRAMES, 0)
                            setInteger(MediaFormat.KEY_PRIORITY, 0)
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                                setInteger(MediaFormat.KEY_PREPEND_HEADER_TO_SYNC_FRAMES, 1)
                            }
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
                            }
                        }
                    }
                    mc.configure(fmt, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                    surf = mc.createInputSurface()
                    mc.start()
                    encoder = mc
                    inputSurface = surf
                    Log.i(TAG, "Started H.264 Surface encoder ${width}x${height}@${fps}fps (${mc.name})")
                    return mc
                } catch (t: Throwable) {
                    runCatching { surf?.release() }
                    runCatching { mc?.release() }
                    Log.w(TAG, "Encoder init attempt failed (name=${candidateName ?: "default"}, ll=$lowLatency): ${t.message}")
                }
            }
        }
        Log.e(TAG, "All H.264 Surface encoder candidates failed for ${width}x${height}")
        return null
    }

    private fun buildEncoderCandidateNames(mime: String, w: Int, h: Int): List<String?> {
        val result = ArrayList<String?>(4)
        result.add(null) // System preferred hardware encoder first
        runCatching {
            val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
            for (info in infos) {
                if (!info.isEncoder) continue
                if (info.supportedTypes.none { it.equals(mime, ignoreCase = true) }) continue
                val caps = runCatching { info.getCapabilitiesForType(mime) }.getOrNull() ?: continue
                val supportsSurface = caps.colorFormats.any {
                    it == MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                }
                val sizeOk = caps.videoCapabilities?.isSizeSupported(w, h) ?: true
                if (supportsSurface && sizeOk && info.name !in result) {
                    result.add(info.name)
                }
            }
        }
        return result
    }

    private fun drainLoop() {
        val enc = encoder ?: return
        val info = MediaCodec.BufferInfo()

        while (running.get()) {
            if (pendingSyncRequest.compareAndSet(true, false)) {
                runCatching {
                    val b = Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) }
                    enc.setParameters(b)
                }
            }

            val outIdx = try {
                enc.dequeueOutputBuffer(info, 15_000L)
            } catch (t: Throwable) {
                if (running.get()) {
                    Log.w(TAG, "Encoder dequeue error: ${t.message}")
                }
                break
            }

            when {
                outIdx == MediaCodec.INFO_TRY_AGAIN_LATER -> continue
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    runCatching {
                        extractCsdFromOutputFormat(enc.outputFormat)
                    }
                }
                outIdx >= 0 -> {
                    try {
                        val outBuf = enc.getOutputBuffer(outIdx)
                        if (outBuf != null && info.size > 0) {
                            outBuf.position(info.offset)
                            outBuf.limit(info.offset + info.size)
                            val raw = ByteArray(info.size)
                            outBuf.get(raw)
                            handleRawEncoderBuffer(raw, info)
                        }
                    } finally {
                        runCatching { enc.releaseOutputBuffer(outIdx, false) }
                    }
                }
            }
        }
    }

    private fun extractCsdFromOutputFormat(fmt: MediaFormat) {
        val out = ByteArrayOutputStream()
        fmt.getByteBuffer("csd-0")?.let { buf ->
            val dup = buf.duplicate()
            val bytes = ByteArray(dup.remaining())
            dup.get(bytes)
            appendNormalizedAnnexB(out, bytes)
        }
        fmt.getByteBuffer("csd-1")?.let { buf ->
            val dup = buf.duplicate()
            val bytes = ByteArray(dup.remaining())
            dup.get(bytes)
            appendNormalizedAnnexB(out, bytes)
        }
        val combined = out.toByteArray()
        if (combined.isNotEmpty()) {
            synchronized(csdLock) {
                cachedAnnexBCsd = combined
            }
        }
    }

    private fun handleRawEncoderBuffer(raw: ByteArray, info: MediaCodec.BufferInfo) {
        if ((info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) return
        val annexB = ensureAnnexB(raw)
        if ((info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0) {
            synchronized(csdLock) {
                cachedAnnexBCsd = annexB
            }
            return
        }

        val isKey = (info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME) != 0 || containsH264IdrSlice(annexB)
        val packetBytes = if (isKey && !containsH264SpsPps(annexB)) {
            val csd = synchronized(csdLock) { cachedAnnexBCsd }
            if (csd != null && csd.isNotEmpty()) {
                ByteArray(csd.size + annexB.size).also { merged ->
                    System.arraycopy(csd, 0, merged, 0, csd.size)
                    System.arraycopy(annexB, 0, merged, csd.size, annexB.size)
                }
            } else {
                annexB
            }
        } else {
            annexB
        }

        if (isKey) {
            synchronized(csdLock) {
                latestCompleteIdr = packetBytes
            }
        }

        val ptsUs = if (info.presentationTimeUs > 0L) info.presentationTimeUs else (System.nanoTime() / 1_000L)
        val wireFlags = if (isKey) FLAG_KEYFRAME else 0
        onEncodedPacket(CODEC_H264, wireFlags, ptsUs, width, height, packetBytes)
    }

    private fun ensureAnnexB(bytes: ByteArray): ByteArray {
        if (bytes.size >= 4 &&
            bytes[0] == 0.toByte() && bytes[1] == 0.toByte() &&
            ((bytes[2] == 0.toByte() && bytes[3] == 1.toByte()) || bytes[2] == 1.toByte())
        ) {
            return bytes
        }
        val out = ByteArrayOutputStream(bytes.size + 4)
        out.write(ANNEX_B_START)
        out.write(bytes)
        return out.toByteArray()
    }

    private fun appendNormalizedAnnexB(out: ByteArrayOutputStream, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        out.write(ensureAnnexB(bytes))
    }

    private fun containsH264SpsPps(data: ByteArray): Boolean {
        var hasSps = false
        var hasPps = false
        forEachH264NaluType(data) { type ->
            if (type == 7) hasSps = true
            if (type == 8) hasPps = true
        }
        return hasSps && hasPps
    }

    private fun containsH264IdrSlice(data: ByteArray): Boolean {
        var found = false
        forEachH264NaluType(data) { type ->
            if (type == 5) found = true
        }
        return found
    }

    private inline fun forEachH264NaluType(data: ByteArray, visitor: (Int) -> Unit) {
        var i = 0
        val n = data.size
        while (i + 4 <= n) {
            if (data[i] == 0.toByte() && data[i + 1] == 0.toByte()) {
                if (data[i + 2] == 0.toByte() && data[i + 3] == 1.toByte()) {
                    if (i + 4 < n) visitor(data[i + 4].toInt() and 0x1F)
                    i += 4
                    continue
                } else if (data[i + 2] == 1.toByte()) {
                    visitor(data[i + 3].toInt() and 0x1F)
                    i += 3
                    continue
                }
            }
            i++
        }
    }

    private fun runSyntheticPainter(surface: Surface) {
        val bgPaint = Paint().apply { style = Paint.Style.FILL }
        val accentPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.rgb(48, 209, 88)
            style = Paint.Style.FILL
        }
        val textPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.WHITE
            textSize = (width * 0.045f).coerceAtLeast(24f)
        }
        var tick = 0
        while (running.get() && !Thread.currentThread().isInterrupted) {
            if (!surface.isValid) break
            runCatching {
                val canvas: Canvas = surface.lockCanvas(null)
                try {
                    bgPaint.color = Color.rgb(16, 18, 24)
                    canvas.drawRect(0f, 0f, width.toFloat(), height.toFloat(), bgPaint)
                    val barY = ((tick * 14) % height.coerceAtLeast(1)).toFloat()
                    canvas.drawRect(24f, barY, (width - 24).toFloat(), barY + 18f, accentPaint)
                    canvas.drawText("OpenUU Android Host #$tick", 36f, height * 0.48f, textPaint)
                } finally {
                    surface.unlockCanvasAndPost(canvas)
                }
            }
            tick++
            try {
                Thread.sleep(33L)
            } catch (_: InterruptedException) {
                break
            }
        }
    }
}

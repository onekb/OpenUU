package ren.onekb.openuu

import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import ren.onekb.openuu.priv.OpenUUPrivServer
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Authenticated loopback TCP client (`127.0.0.1:<port>`) talking to [OpenUUPrivServer] (`UID 2000 / 0`).
 */
class PrivDaemonClient(
    private val port: Int,
    private val authToken: String,
    private val onAppsListJson: (String) -> Unit,
    private val onWindowTopologyJson: (String) -> Unit,
    private val onVideoFrame: (
        windowId: Int,
        codec: Int,
        flags: Int,
        ptsUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    ) -> Unit,
    private val onLog: (String) -> Unit,
    private val onPermissionHint: (String) -> Unit = {},
    private val onFallbackTouch: (
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ) -> Unit = { _, _, _, _, _, _, _ -> },
    private val onFallbackScroll: (
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        dx: Float,
        dy: Float,
        isContinuous: Boolean
    ) -> Unit = { _, _, _, _, _, _, _, _ -> },
    private val onDisconnected: () -> Unit
) {
    companion object {
        private const val TAG = "OpenUUPrivCli"
        const val DEFAULT_PRIV_PORT = 39489

        data class ProbeInfo(
            val alive: Boolean,
            val uid: Int = -1,
            val pid: Int = -1,
            val version: Int = 0
        ) {
            val isCurrentVersion: Boolean
                get() = alive && version >= OpenUUPrivServer.SERVER_VERSION
        }

        fun shutdownDaemon(port: Int, authToken: String, timeoutMs: Int = 500) {
            if (authToken.length < 16 || port <= 0) return
            val sock = Socket()
            try {
                sock.tcpNoDelay = true
                sock.soTimeout = timeoutMs
                sock.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
                val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1024))
                val inp = DataInputStream(BufferedInputStream(sock.getInputStream(), 4096))
                val tokenBytes = authToken.toByteArray(Charsets.UTF_8)
                out.writeInt(OpenUUPrivServer.PROTOCOL_MAGIC)
                out.writeShort(tokenBytes.size)
                out.write(tokenBytes)
                val cmdBytes = """{"cmd":"shutdown"}""".toByteArray(Charsets.UTF_8)
                out.writeByte(OpenUUPrivServer.TYPE_CMD_JSON)
                out.writeInt(cmdBytes.size)
                out.write(cmdBytes)
                out.flush()
                runCatching { inp.readUnsignedByte() }
            } catch (_: Throwable) {
            } finally {
                runCatching { sock.close() }
            }
        }

        fun probeRunning(port: Int, authToken: String, timeoutMs: Int = 450): ProbeInfo {
            if (authToken.length < 16 || port <= 0) return ProbeInfo(false)
            val sock = Socket()
            return try {
                sock.tcpNoDelay = true
                sock.soTimeout = timeoutMs
                sock.connect(InetSocketAddress("127.0.0.1", port), timeoutMs)
                val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 1024))
                val inp = DataInputStream(BufferedInputStream(sock.getInputStream(), 4096))

                val tokenBytes = authToken.toByteArray(Charsets.UTF_8)
                out.writeInt(OpenUUPrivServer.PROTOCOL_MAGIC)
                out.writeShort(tokenBytes.size)
                out.write(tokenBytes)
                out.flush()

                val type = inp.readUnsignedByte()
                val len = inp.readInt()
                if (type != OpenUUPrivServer.TYPE_EVENT_JSON || len <= 0 || len > 65536) {
                    return ProbeInfo(false)
                }
                val buf = ByteArray(len)
                inp.readFully(buf)
                val obj = JSONObject(String(buf, Charsets.UTF_8))
                if (obj.optString("event") == "hello") {
                    ProbeInfo(
                        alive = true,
                        uid = obj.optInt("uid", 2000),
                        pid = obj.optInt("pid", 0),
                        version = obj.optInt("version", 0)
                    )
                } else {
                    ProbeInfo(false)
                }
            } catch (_: Throwable) {
                ProbeInfo(false)
            } finally {
                runCatching { sock.close() }
            }
        }
    }

    private val running = AtomicBoolean(false)
    private val writeLock = Any()
    private var socket: Socket? = null
    private var output: DataOutputStream? = null
    private var readerThread: Thread? = null

    // Tracks logical `(width, height)` per `windowId` for accurate per-window pointer normalization
    private val windowLogicalSizes = ConcurrentHashMap<Int, Pair<Float, Float>>()

    val isConnected: Boolean
        get() = running.get() && socket?.isClosed == false

    fun connect(): Boolean {
        if (isConnected) return true
        disconnect()

        val sock = Socket()
        return try {
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress("127.0.0.1", port), 800)
            sock.soTimeout = 0
            val out = DataOutputStream(BufferedOutputStream(sock.getOutputStream(), 32 * 1024))
            val inp = DataInputStream(BufferedInputStream(sock.getInputStream(), 256 * 1024))

            val tokenBytes = authToken.toByteArray(Charsets.UTF_8)
            out.writeInt(OpenUUPrivServer.PROTOCOL_MAGIC)
            out.writeShort(tokenBytes.size)
            out.write(tokenBytes)
            out.flush()

            // Expect immediate `hello` packet
            val firstType = inp.readUnsignedByte()
            val firstLen = inp.readInt()
            if (firstType != OpenUUPrivServer.TYPE_EVENT_JSON || firstLen <= 0 || firstLen > 65536) {
                sock.close()
                return false
            }
            val helloBytes = ByteArray(firstLen)
            inp.readFully(helloBytes)
            val helloObj = JSONObject(String(helloBytes, Charsets.UTF_8))
            if (helloObj.optString("event") != "hello") {
                sock.close()
                return false
            }

            socket = sock
            output = out
            running.set(true)
            onLog("已连接高阶多窗口引擎 (UID=${helloObj.optInt("uid")}, PID=${helloObj.optInt("pid")})")

            readerThread = Thread({ readLoop(inp) }, "OpenUUPrivReader").apply {
                isDaemon = true
                start()
            }
            true
        } catch (t: Throwable) {
            Log.w(TAG, "Failed to connect to OpenUUPrivServer: ${t.message}")
            runCatching { sock.close() }
            false
        }
    }

    fun disconnect() {
        val wasRunning = running.getAndSet(false)
        synchronized(writeLock) {
            output = null
        }
        runCatching { socket?.close() }
        socket = null
        readerThread = null
        windowLogicalSizes.clear()
        if (wasRunning) {
            onDisconnected()
        }
    }

    fun logicalSizeForWindow(windowId: Int, fallbackW: Float, fallbackH: Float): Pair<Float, Float> {
        if (windowId != 0) {
            windowLogicalSizes[windowId]?.let { return it }
        }
        windowLogicalSizes.values.lastOrNull()?.let { return it }
        return fallbackW to fallbackH
    }

    fun requestApps(): Boolean = sendCmd(JSONObject().put("cmd", "list_apps"))

    fun openWindow(
        bundleId: String,
        width: Int,
        height: Int,
        dpi: Int,
        fps: Int = 45,
        bitrateBps: Int = 4_500_000
    ): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "open_window")
            put("bundle_id", bundleId)
            put("width", width)
            put("height", height)
            put("dpi", dpi)
            put("fps", fps)
            put("bitrate", bitrateBps)
        }
    )

    fun closeWindow(windowId: Int): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "close_window")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
        }
    )

    fun closeAllWindows(): Boolean = sendCmd(JSONObject().put("cmd", "close_all_windows"))

    fun requestKeyframe(windowId: Int): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "request_keyframe")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
        }
    )

    fun updateBitrate(bitrateBps: Int): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "update_bitrate")
            put("bitrate", bitrateBps)
        }
    )

    fun resizeWindow(windowId: Int, width: Int, height: Int, dpi: Int): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "resize_window")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
            put("width", width)
            put("height", height)
            put("dpi", dpi)
        }
    )

    fun sendMouse(
        windowId: Int,
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "mouse")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
            put("norm_x", normX.toDouble())
            put("norm_y", normY.toDouble())
            put("event_type", eventType)
            put("button", button)
        }
    )

    fun sendScroll(
        windowId: Int,
        normX: Float,
        normY: Float,
        dx: Float,
        dy: Float,
        isContinuous: Boolean = true
    ): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "scroll")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
            put("norm_x", normX.toDouble())
            put("norm_y", normY.toDouble())
            put("dx", dx.toDouble())
            put("dy", dy.toDouble())
            put("continuous", isContinuous)
        }
    )

    fun sendKey(
        windowId: Int,
        keyCode: Int,
        isDown: Boolean,
        modifiers: Int
    ): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "key")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
            put("key_code", keyCode)
            put("is_down", isDown)
            put("mods", modifiers)
        }
    )

    fun sendPasteKey(windowId: Int): Boolean = sendCmd(
        JSONObject().apply {
            put("cmd", "paste_key")
            put("window_id", windowId.toLong() and 0xFFFF_FFFFL)
        }
    )

    private fun sendCmd(obj: JSONObject): Boolean {
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        synchronized(writeLock) {
            val out = output ?: return false
            return try {
                out.writeByte(OpenUUPrivServer.TYPE_CMD_JSON)
                out.writeInt(bytes.size)
                out.write(bytes)
                out.flush()
                true
            } catch (t: Throwable) {
                Log.w(TAG, "sendCmd error: ${t.message}")
                false
            }
        }
    }

    private fun readLoop(inp: DataInputStream) {
        try {
            while (running.get()) {
                val frameType = inp.readUnsignedByte()
                val len = inp.readInt()
                if (len < 0 || len > 8 * 1024 * 1024) break

                when (frameType) {
                    OpenUUPrivServer.TYPE_EVENT_JSON -> {
                        val buf = ByteArray(len)
                        if (len > 0) inp.readFully(buf)
                        handleEventJson(String(buf, Charsets.UTF_8))
                    }
                    OpenUUPrivServer.TYPE_FRAME_VIDEO -> {
                        if (len <= 20) {
                            if (len > 0) inp.skipBytes(len)
                            continue
                        }
                        val hdrBytes = ByteArray(20)
                        inp.readFully(hdrBytes)
                        val bb = ByteBuffer.wrap(hdrBytes)
                        val windowId = bb.int
                        val codec = bb.get().toInt() and 0xFF
                        val flags = bb.get().toInt() and 0xFF
                        val width = bb.short.toInt() and 0xFFFF
                        val height = bb.short.toInt() and 0xFFFF
                        bb.short // reserved
                        val ptsUs = bb.long

                        val videoBytes = ByteArray(len - 20)
                        inp.readFully(videoBytes)

                        if (width > 0 && height > 0) {
                            windowLogicalSizes[windowId] =
                                (width / 2.0f).coerceAtLeast(1f) to (height / 2.0f).coerceAtLeast(1f)
                        }
                        onVideoFrame(windowId, codec, flags, ptsUs, width, height, videoBytes)
                    }
                    else -> {
                        val skipBuf = ByteArray(len)
                        if (len > 0) inp.readFully(skipBuf)
                    }
                }
            }
        } catch (_: Throwable) {
            // Disconnected
        } finally {
            disconnect()
        }
    }

    private fun handleEventJson(raw: String) {
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return
        when (obj.optString("event", "")) {
            "apps" -> {
                val arr = obj.optJSONArray("apps") ?: JSONArray()
                onAppsListJson(arr.toString())
            }
            "topology" -> {
                val arr = obj.optJSONArray("windows") ?: JSONArray()
                val seen = HashSet<Int>()
                for (i in 0 until arr.length()) {
                    val wObj = arr.optJSONObject(i) ?: continue
                    val id = wObj.optLong("window_id", 0L).toInt()
                    val lw = wObj.optDouble("width", 0.0).toFloat()
                    val lh = wObj.optDouble("height", 0.0).toFloat()
                    if (id != 0 && lw > 0f && lh > 0f) {
                        seen.add(id)
                        windowLogicalSizes[id] = lw to lh
                    }
                }
                windowLogicalSizes.keys.retainAll(seen)
                onWindowTopologyJson(arr.toString())
            }
            "error" -> {
                val msg = obj.optString("message", "未知高阶引擎错误")
                onLog("高阶引擎提示: $msg")
            }
            "input_permission_hint" -> {
                val reason = obj.optString("reason", "")
                onPermissionHint(reason)
            }
            "fallback_touch" -> {
                onFallbackTouch(
                    obj.optInt("display_id", 0),
                    obj.optInt("display_w", 720),
                    obj.optInt("display_h", 1600),
                    obj.optDouble("norm_x", 0.5).toFloat(),
                    obj.optDouble("norm_y", 0.5).toFloat(),
                    obj.optInt("event_type", 0),
                    obj.optInt("button", 0)
                )
            }
            "fallback_scroll" -> {
                onFallbackScroll(
                    obj.optInt("display_id", 0),
                    obj.optInt("display_w", 720),
                    obj.optInt("display_h", 1600),
                    obj.optDouble("norm_x", 0.5).toFloat(),
                    obj.optDouble("norm_y", 0.5).toFloat(),
                    obj.optDouble("dx", 0.0).toFloat(),
                    obj.optDouble("dy", 0.0).toFloat(),
                    obj.optBoolean("continuous", true)
                )
            }
        }
    }
}

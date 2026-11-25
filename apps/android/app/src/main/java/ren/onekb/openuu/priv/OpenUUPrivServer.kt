package ren.onekb.openuu.priv

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.content.pm.ResolveInfo
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.hardware.input.InputManager
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import android.view.Display
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.MotionEvent
import org.json.JSONArray
import org.json.JSONObject
import ren.onekb.openuu.MacKeyCodes
import ren.onekb.openuu.MacModifiers
import ren.onekb.openuu.OpenUUConstants
import ren.onekb.openuu.ScreenCaptureEncoder
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

/**
 * Self-contained privileged multi-window daemon (`ren.onekb.openuu.priv.OpenUUPrivServer`).
 *
 * Launched directly by OpenUU via built-in Android 11+ Wireless Debugging (`libadb` in `openuu-core`)
 * or Root (`su`), running under `/system/bin/app_process` (`UID 2000 shell` or `UID 0 root`) with
 * zero dependency on external helper apps:
 * - Creates independent `VirtualDisplay` + hardware H.264 `ScreenCaptureEncoder` per opened Android app
 * - Enumerates & launches apps across all Android user profiles (`User 0` + `User 999`/Clone/Work Dual-App WeChat)
 *   directly onto each target `displayId` without triggering "开哪个" chooser sheets or `MediaProjection` popups
 * - Injects touch, wheel scroll, shortcuts, and paste events per `displayId` via `InputManager`
 */
object OpenUUPrivServer {

    const val PROTOCOL_MAGIC: Int = 0x4F555550 // "OUUP"
    const val SERVER_VERSION: Int = 705

    const val TYPE_CMD_JSON: Int = 0x01
    const val TYPE_EVENT_JSON: Int = 0x11
    const val TYPE_FRAME_VIDEO: Int = 0x12

    // DisplayManager virtual display flags (including @hide system flags available to UID 2000 / 0)
    private const val VD_FLAG_PUBLIC = 1 shl 0
    private const val VD_FLAG_PRESENTATION = 1 shl 1
    private const val VD_FLAG_OWN_CONTENT_ONLY = 1 shl 3
    private const val VD_FLAG_AUTO_MIRROR = 1 shl 4
    private const val VD_FLAG_SUPPORTS_TOUCH = 1 shl 6
    private const val VD_FLAG_ROTATES_WITH_CONTENT = 1 shl 7
    private const val VD_FLAG_DESTROY_CONTENT_ON_REMOVAL = 1 shl 8
    private const val VD_FLAG_TRUSTED = 1 shl 10

    private lateinit var systemContext: Context
    private lateinit var callerContext: Context
    private lateinit var mainHandler: Handler
    private lateinit var displayManager: DisplayManager
    private var inputInjector: PerDisplayInputInjector? = null

    private val writeLock = Any()
    private val activeClientStreams = CopyOnWriteArrayList<DataOutputStream>()

    private data class ResolvedAppEntry(
        val bundleId: String,
        val pkg: String,
        val activityName: String,
        val userId: Int,
        val displayName: String,
        val isUserApp: Boolean,
        val iconPngB64: String
    )

    private class ManagedAppWindow(
        val windowId: Int,
        val bundleId: String,
        val pkg: String,
        val userId: Int,
        val isFullDesktopMirror: Boolean,
        var title: String,
        val iconPngB64: String,
        var width: Int,
        var height: Int,
        var dpi: Int,
        var virtualDisplay: VirtualDisplay,
        var encoder: ScreenCaptureEncoder
    ) {
        val displayId: Int
            get() = runCatching { virtualDisplay.display?.displayId ?: Display.DEFAULT_DISPLAY }
                .getOrDefault(Display.DEFAULT_DISPLAY)

        fun liveDisplayBounds(): Pair<Int, Int> {
            return runCatching {
                val pt = android.graphics.Point()
                @Suppress("DEPRECATION")
                virtualDisplay.display?.getRealSize(pt)
                if (pt.x > 32 && pt.y > 32) {
                    pt.x to pt.y
                } else {
                    width to height
                }
            }.getOrDefault(width to height)
        }
    }

    private val windowsLock = Any()
    private val windowsById = LinkedHashMap<Int, ManagedAppWindow>()
    private val resolvedAppsCache = ConcurrentHashMap<String, ResolvedAppEntry>()
    private val iconB64Cache = ConcurrentHashMap<String, String>()
    @Volatile
    private var activeBitrateBps: Int = 4_500_000

    @JvmStatic
    fun main(args: Array<String>) {
        if (args.size < 2) {
            System.err.println("Usage: OpenUUPrivServer <port> <authToken>")
            exitProcess(2)
        }
        val port = args[0].toIntOrNull() ?: 39489
        val expectedToken = args[1].trim()
        if (expectedToken.length < 16) {
            System.err.println("Invalid authToken")
            exitProcess(2)
        }

        bypassHiddenApiRestrictions()

        if (Looper.getMainLooper() == null) {
            Looper.prepareMainLooper()
        }
        mainHandler = Handler(Looper.getMainLooper())

        try {
            val atClass = Class.forName("android.app.ActivityThread")
            val sysMain = atClass.getDeclaredMethod("systemMain").invoke(null)
            val sysCtx = atClass.getDeclaredMethod("getSystemContext").invoke(sysMain) as Context
            systemContext = sysCtx
            callerContext = if (Process.myUid() == 2000) {
                runCatching {
                    sysCtx.createPackageContext("com.android.shell", Context.CONTEXT_IGNORE_SECURITY)
                }.getOrDefault(sysCtx)
            } else {
                sysCtx
            }
            displayManager = callerContext.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            inputInjector = PerDisplayInputInjector(
                context = callerContext,
                handler = mainHandler,
                onLog = ::logLine,
                onEmitFallbackEvent = ::sendEventJson
            )
            logLine("Initialized OpenUUPrivServer uid=${Process.myUid()} pid=${Process.myPid()} port=$port")
        } catch (t: Throwable) {
            System.err.println("OpenUUPrivServer bootstrap failed: ${t.message}")
            t.printStackTrace()
            exitProcess(3)
        }

        val serverSocket = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 4)
            }
        } catch (t: Throwable) {
            System.err.println("Failed to bind 127.0.0.1:$port: ${t.message}")
            exitProcess(4)
        }

        println("OPENUU_PRIV_READY port=$port uid=${Process.myUid()}")
        System.out.flush()

        Thread({
            acceptLoop(serverSocket, expectedToken.toByteArray(Charsets.UTF_8))
        }, "OpenUUPrivAccept").apply {
            isDaemon = true
            start()
        }

        Looper.loop()
    }

    private fun bypassHiddenApiRestrictions() {
        runCatching {
            val vmRuntimeClass = Class.forName("dalvik.system.VMRuntime")
            val runtime = vmRuntimeClass.getDeclaredMethod("getRuntime").invoke(null)
            vmRuntimeClass
                .getDeclaredMethod("setHiddenApiExemptions", Array<String>::class.java)
                .invoke(runtime, arrayOf("L"))
        }
    }

    private fun logLine(msg: String) {
        println("[OpenUUPriv] $msg")
        System.out.flush()
    }

    private fun acceptLoop(serverSocket: ServerSocket, expectedTokenBytes: ByteArray) {
        while (!serverSocket.isClosed) {
            val sock = try {
                serverSocket.accept()
            } catch (_: Throwable) {
                continue
            }
            Thread({
                handleClientConnection(sock, expectedTokenBytes)
            }, "OpenUUPrivClient").apply {
                isDaemon = true
                start()
            }
        }
    }

    private fun handleClientConnection(socket: Socket, expectedTokenBytes: ByteArray) {
        var clientOutRef: DataOutputStream? = null
        try {
            socket.tcpNoDelay = true
            socket.soTimeout = 0
            val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 32 * 1024))
            val output = DataOutputStream(BufferedOutputStream(socket.getOutputStream(), 128 * 1024))

            val magic = input.readInt()
            if (magic != PROTOCOL_MAGIC) {
                socket.close()
                return
            }
            val tokenLen = input.readUnsignedShort()
            if (tokenLen <= 0 || tokenLen > 512) {
                socket.close()
                return
            }
            val tokenBytes = ByteArray(tokenLen)
            input.readFully(tokenBytes)
            if (!MessageDigest.isEqual(tokenBytes, expectedTokenBytes)) {
                logLine("Rejected unauthorized loopback client")
                socket.close()
                return
            }

            clientOutRef = output
            activeClientStreams.add(output)

            sendEventJsonTo(
                output,
                JSONObject().apply {
                    put("event", "hello")
                    put("uid", Process.myUid())
                    put("pid", Process.myPid())
                    put("version", SERVER_VERSION)
                }
            )

            // If windows are already open, push current topology + fresh keyframes immediately
            val existingTopo = buildTopologyJsonArray()
            if (existingTopo.length() > 0) {
                sendEventJsonTo(
                    output,
                    JSONObject().apply {
                        put("event", "topology")
                        put("windows", existingTopo)
                    }
                )
                requestKeyframesInternal(0)
            }

            while (!socket.isClosed) {
                val frameType = input.readUnsignedByte()
                val payloadLen = input.readInt()
                if (payloadLen < 0 || payloadLen > 4 * 1024 * 1024) {
                    break
                }
                val payload = ByteArray(payloadLen)
                if (payloadLen > 0) {
                    input.readFully(payload)
                }
                if (frameType == TYPE_CMD_JSON) {
                    val cmdJson = String(payload, Charsets.UTF_8)
                    dispatchCommandJson(cmdJson, output)
                }
            }
        } catch (_: Throwable) {
            // Client socket closed or reset
        } finally {
            clientOutRef?.let { activeClientStreams.remove(it) }
            runCatching { socket.close() }
        }
    }

    private fun dispatchCommandJson(raw: String, replyStream: DataOutputStream) {
        val obj = runCatching { JSONObject(raw) }.getOrNull() ?: return
        when (obj.optString("cmd", "")) {
            "ping" -> {
                sendEventJsonTo(
                    replyStream,
                    JSONObject().apply {
                        put("event", "pong")
                        put("uid", Process.myUid())
                        put("version", SERVER_VERSION)
                        put("open_windows", synchronized(windowsLock) { windowsById.size })
                    }
                )
            }
            "list_apps" -> {
                val appsArr = enumerateAllUsersAppsJson()
                sendEventJsonTo(
                    replyStream,
                    JSONObject().apply {
                        put("event", "apps")
                        put("apps", appsArr)
                    }
                )
            }
            "open_window" -> {
                val bundleId = obj.optString("bundle_id", "")
                val reqWidth = obj.optInt("width", 720)
                val reqHeight = obj.optInt("height", 1600)
                val reqDpi = obj.optInt("dpi", 360)
                val fps = obj.optInt("fps", 45)
                val bitrate = obj.optInt("bitrate", activeBitrateBps)
                openOrFocusWindow(bundleId, reqWidth, reqHeight, reqDpi, fps, bitrate)
            }
            "close_window" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                if (winId == 0) {
                    closeAllWindows()
                } else {
                    closeSingleWindow(winId)
                }
            }
            "close_all_windows" -> {
                closeAllWindows()
            }
            "request_keyframe" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                requestKeyframesInternal(winId)
            }
            "update_bitrate" -> {
                val bps = obj.optInt("bitrate", 4_500_000).coerceIn(800_000, 12_000_000)
                activeBitrateBps = bps
                synchronized(windowsLock) {
                    windowsById.values.forEach { it.encoder.updateBitrate(bps) }
                }
            }
            "resize_window" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                val reqW = obj.optInt("width", 0)
                val reqH = obj.optInt("height", 0)
                val reqDpi = obj.optInt("dpi", 0)
                if (winId != 0 && reqW > 0 && reqH > 0) {
                    resizeExistingWindow(winId, reqW, reqH, reqDpi)
                }
            }
            "mouse" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                val normX = obj.optDouble("norm_x", 0.5).toFloat()
                val normY = obj.optDouble("norm_y", 0.5).toFloat()
                val eventType = obj.optInt("event_type", 0)
                val button = obj.optInt("button", 0)
                val target = resolveWindowForInput(winId) ?: return
                val (liveW, liveH) = target.liveDisplayBounds()
                inputInjector?.injectMouse(
                    displayId = target.displayId,
                    displayW = liveW,
                    displayH = liveH,
                    normX = normX,
                    normY = normY,
                    eventType = eventType,
                    button = button
                )
            }
            "scroll" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                val normX = obj.optDouble("norm_x", 0.5).toFloat()
                val normY = obj.optDouble("norm_y", 0.5).toFloat()
                val dx = obj.optDouble("dx", 0.0).toFloat()
                val dy = obj.optDouble("dy", 0.0).toFloat()
                val isContinuous = obj.optBoolean("continuous", true)
                val target = resolveWindowForInput(winId) ?: return
                val (liveW, liveH) = target.liveDisplayBounds()
                inputInjector?.injectScroll(
                    displayId = target.displayId,
                    displayW = liveW,
                    displayH = liveH,
                    normX = normX,
                    normY = normY,
                    deltaX = dx,
                    deltaY = dy,
                    isContinuous = isContinuous
                )
            }
            "key" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                val keyCode = obj.optInt("key_code", 0)
                val isDown = obj.optBoolean("is_down", true)
                val mods = obj.optInt("mods", 0)
                val target = resolveWindowForInput(winId) ?: return
                inputInjector?.injectMacKey(
                    displayId = target.displayId,
                    macKeyCode = keyCode,
                    isDown = isDown,
                    macModifiers = mods
                )
            }
            "paste_key" -> {
                val winId = obj.optLong("window_id", 0L).toInt()
                val target = resolveWindowForInput(winId) ?: return
                inputInjector?.injectPasteKey(target.displayId)
            }
            "shutdown" -> {
                closeAllWindows()
                sendEventJsonTo(replyStream, JSONObject().put("event", "bye"))
                exitProcess(0)
            }
        }
    }

    private fun resolveWindowForInput(windowId: Int): ManagedAppWindow? {
        synchronized(windowsLock) {
            if (windowId != 0) {
                windowsById[windowId]?.let { return it }
            }
            return windowsById.values.lastOrNull()
        }
    }

    // ---- Multi-App VirtualDisplay & H.264 Streaming ----

    private fun openOrFocusWindow(
        rawBundleId: String,
        reqWidth: Int,
        reqHeight: Int,
        reqDpi: Int,
        fps: Int,
        bitrateBps: Int
    ) {
        val isFullDesktop = rawBundleId.isBlank() || rawBundleId == OpenUUConstants.FULL_DESKTOP_BUNDLE_ID
        val (pkg, userId) = if (isFullDesktop) {
            OpenUUConstants.FULL_DESKTOP_BUNDLE_ID to 0
        } else {
            parseBundleAndUser(rawBundleId)
        }
        val canonicalBundle = if (isFullDesktop) {
            OpenUUConstants.FULL_DESKTOP_BUNDLE_ID
        } else {
            "$pkg@$userId"
        }
        val windowId = if (isFullDesktop) {
            OpenUUConstants.FULL_DESKTOP_WINDOW_ID
        } else {
            stableWindowIdForBundle(canonicalBundle)
        }

        val (encW, encH) = ScreenCaptureEncoder.computeAlignedEncodeSize(reqWidth, reqHeight)
        val safeDpi = reqDpi.coerceIn(160, 640)

        val existing = synchronized(windowsLock) { windowsById[windowId] }
        if (existing != null) {
            if (!isFullDesktop) {
                launchAppOnDisplay(pkg, userId, existing.displayId)
            }
            publishTopologyEvent()
            existing.encoder.requestKeyframe()
            scheduleWarmupKeyframes(existing.encoder)
            return
        }

        // Ensure app metadata cache is warm if opening a per-app window directly
        if (!isFullDesktop && !resolvedAppsCache.containsKey(canonicalBundle)) {
            runCatching { enumerateAllUsersAppsJson() }
        }
        val meta = resolvedAppsCache[canonicalBundle]
        val devLabel = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim().ifBlank { "Android" }
        val title = when {
            isFullDesktop -> "整台手机屏幕 ($devLabel)"
            meta != null -> meta.displayName
            userId != 0 -> "$pkg (分身)"
            else -> pkg
        }
        val iconB64 = meta?.iconPngB64.orEmpty()

        val encoder = ScreenCaptureEncoder(
            width = encW,
            height = encH,
            fps = fps.coerceIn(24, 60),
            bitrateBps = bitrateBps.coerceIn(800_000, 12_000_000),
            useSyntheticFrames = false,
            onEncodedPacket = { codec, flags, ptsUs, w, h, bytes ->
                sendVideoFramePacket(windowId, codec, flags, w, h, ptsUs, bytes)
            }
        )
        val surface = encoder.start()
        if (surface == null) {
            sendEventJson(JSONObject().apply {
                put("event", "error")
                put("message", "无法为 $title 创建 H.264 硬件编码器（可能超出芯片并发上限）")
            })
            return
        }

        val vd = createPrivilegedVirtualDisplay(
            name = if (isFullDesktop) "OpenUU-Mirror" else "OpenUU-$windowId",
            width = encW,
            height = encH,
            dpi = safeDpi,
            surface = surface,
            mirrorDefaultDisplay = isFullDesktop
        )
        if (vd == null) {
            encoder.stop()
            sendEventJson(JSONObject().apply {
                put("event", "error")
                put("message", "创建独立虚拟屏幕失败 ($title)")
            })
            return
        }

        val managed = ManagedAppWindow(
            windowId = windowId,
            bundleId = canonicalBundle,
            pkg = pkg,
            userId = userId,
            isFullDesktopMirror = isFullDesktop,
            title = title,
            iconPngB64 = iconB64,
            width = encW,
            height = encH,
            dpi = safeDpi,
            virtualDisplay = vd,
            encoder = encoder
        )

        val openCount = synchronized(windowsLock) {
            windowsById[windowId] = managed
            windowsById.size
        }

        val targetDisplayId = managed.displayId
        logLine("Opened windowId=$windowId bundle=$canonicalBundle displayId=$targetDisplayId ${encW}x${encH}@${safeDpi}dpi (active=$openCount)")

        if (!isFullDesktop && targetDisplayId != Display.DEFAULT_DISPLAY) {
            launchAppOnDisplay(pkg, userId, targetDisplayId)
        }

        publishTopologyEvent()
        encoder.requestKeyframe()
        scheduleWarmupKeyframes(encoder)
    }

    private fun scheduleWarmupKeyframes(encoder: ScreenCaptureEncoder) {
        for (delayMs in listOf(160L, 420L, 900L)) {
            mainHandler.postDelayed({
                runCatching { encoder.requestKeyframe() }
            }, delayMs)
        }
    }

    private fun createPrivilegedVirtualDisplay(
        name: String,
        width: Int,
        height: Int,
        dpi: Int,
        surface: android.view.Surface,
        mirrorDefaultDisplay: Boolean
    ): VirtualDisplay? {
        val candidateFlags = if (mirrorDefaultDisplay) {
            listOf(
                VD_FLAG_PUBLIC or VD_FLAG_AUTO_MIRROR,
                VD_FLAG_AUTO_MIRROR,
                VD_FLAG_PUBLIC or VD_FLAG_PRESENTATION or VD_FLAG_AUTO_MIRROR
            )
        } else {
            listOf(
                VD_FLAG_PUBLIC or VD_FLAG_OWN_CONTENT_ONLY or VD_FLAG_SUPPORTS_TOUCH or
                    VD_FLAG_ROTATES_WITH_CONTENT or VD_FLAG_DESTROY_CONTENT_ON_REMOVAL or VD_FLAG_TRUSTED,
                VD_FLAG_PUBLIC or VD_FLAG_PRESENTATION or VD_FLAG_OWN_CONTENT_ONLY or
                    VD_FLAG_SUPPORTS_TOUCH or VD_FLAG_DESTROY_CONTENT_ON_REMOVAL,
                VD_FLAG_PUBLIC or VD_FLAG_OWN_CONTENT_ONLY
            )
        }

        val latch = CountDownLatch(1)
        var created: VirtualDisplay? = null

        val createBlock = Runnable {
            for (flags in candidateFlags) {
                try {
                    val vd = displayManager.createVirtualDisplay(
                        name,
                        width,
                        height,
                        dpi,
                        surface,
                        flags,
                        null,
                        mainHandler
                    )
                    if (vd != null) {
                        created = vd
                        logLine("VirtualDisplay '$name' created with flags=0x${flags.toString(16)} displayId=${vd.display?.displayId}")
                        break
                    }
                } catch (t: Throwable) {
                    logLine("createVirtualDisplay flags=0x${flags.toString(16)} failed: ${t.message}")
                }
            }
            latch.countDown()
        }

        if (Looper.myLooper() == Looper.getMainLooper()) {
            createBlock.run()
        } else {
            mainHandler.post(createBlock)
            latch.await(4, TimeUnit.SECONDS)
        }
        return created
    }

    private fun resizeExistingWindow(windowId: Int, reqLogicalOrPhysW: Int, reqLogicalOrPhysH: Int, reqDpi: Int) {
        val existing = synchronized(windowsLock) { windowsById[windowId] } ?: return
        // Client ResizeWindow sends logical points (half of encode px); scale up to crisp 2x physical bounds
        val targetPhysW = if (reqLogicalOrPhysW <= 960) reqLogicalOrPhysW * 2 else reqLogicalOrPhysW
        val targetPhysH = if (reqLogicalOrPhysH <= 960) reqLogicalOrPhysH * 2 else reqLogicalOrPhysH
        val (newW, newH) = ScreenCaptureEncoder.computeAlignedEncodeSize(targetPhysW, targetPhysH)
        if (newW == existing.width && newH == existing.height) return

        val newDpi = if (reqDpi > 0) reqDpi.coerceIn(160, 640) else existing.dpi
        val newEncoder = ScreenCaptureEncoder(
            width = newW,
            height = newH,
            fps = 45,
            bitrateBps = activeBitrateBps,
            useSyntheticFrames = false,
            onEncodedPacket = { codec, flags, ptsUs, w, h, bytes ->
                sendVideoFramePacket(windowId, codec, flags, w, h, ptsUs, bytes)
            }
        )
        val newSurf = newEncoder.start() ?: return
        val oldEncoder = existing.encoder

        mainHandler.post {
            runCatching {
                existing.virtualDisplay.resize(newW, newH, newDpi)
                existing.virtualDisplay.surface = newSurf
                existing.width = newW
                existing.height = newH
                existing.dpi = newDpi
                existing.encoder = newEncoder
            }
            Thread({
                oldEncoder.stop()
            }, "StopOldEnc").start()
            publishTopologyEvent()
            scheduleWarmupKeyframes(newEncoder)
        }
    }

    private fun closeSingleWindow(windowId: Int) {
        val removed = synchronized(windowsLock) { windowsById.remove(windowId) } ?: return
        teardownManagedWindow(removed)
        publishTopologyEvent()
    }

    private fun closeAllWindows() {
        val all = synchronized(windowsLock) {
            val copy = windowsById.values.toList()
            windowsById.clear()
            copy
        }
        all.forEach { teardownManagedWindow(it) }
        publishTopologyEvent()
    }

    private fun teardownManagedWindow(win: ManagedAppWindow) {
        runCatching { win.virtualDisplay.surface = null }
        runCatching { win.encoder.stop() }
        mainHandler.post {
            runCatching { win.virtualDisplay.release() }
        }
        logLine("Closed windowId=${win.windowId} (${win.bundleId})")
    }

    private fun requestKeyframesInternal(windowId: Int) {
        synchronized(windowsLock) {
            if (windowId == 0) {
                windowsById.values.forEach { it.encoder.requestKeyframe() }
            } else {
                windowsById[windowId]?.encoder?.requestKeyframe()
            }
        }
    }

    private fun buildTopologyJsonArray(): JSONArray {
        val arr = JSONArray()
        synchronized(windowsLock) {
            var idx = 0
            for (win in windowsById.values) {
                val logicalW = (win.width / 2.0f).coerceAtLeast(160f)
                val logicalH = (win.height / 2.0f).coerceAtLeast(160f)
                arr.put(
                    JSONObject().apply {
                        put("window_id", win.windowId.toLong() and 0xFFFF_FFFFL)
                        put("parent_window_id", 0)
                        put("kind", 0)
                        put("rel_x", (idx * 36).toDouble())
                        put("rel_y", (idx * 28).toDouble())
                        put("width", logicalW.toDouble())
                        put("height", logicalH.toDouble())
                        put("title", win.title)
                        if (win.iconPngB64.isNotBlank()) {
                            put("icon_png_b64", win.iconPngB64)
                        }
                    }
                )
                idx++
            }
        }
        return arr
    }

    private fun publishTopologyEvent() {
        val arr = buildTopologyJsonArray()
        sendEventJson(
            JSONObject().apply {
                put("event", "topology")
                put("windows", arr)
            }
        )
    }

    // ---- Cross-User App Discovery & Direct Display Launch (Dual-App WeChat Support) ----

    private fun enumerateAllUsersAppsJson(): JSONArray {
        val pm = systemContext.packageManager
        val userProfiles = discoverUserProfiles()
        val nonZeroCount = userProfiles.count { it.first != 0 }

        val priorityPkgs = setOf(
            "com.tencent.mm",
            "com.tencent.mobileqq",
            "com.ss.android.lark",
            "com.alibaba.android.rimet",
            "com.xingin.xhs",
            "com.ss.android.ugc.aweme",
            "com.eg.android.AlipayGphone",
            "com.android.chrome",
            "com.android.settings"
        )

        val discovered = ArrayList<ResolvedAppEntry>()
        val seenBundles = HashSet<String>()

        for ((userId, profileName) in userProfiles) {
            val activities = queryLauncherActivitiesForUser(userId, pm)
            for ((pkg, cls, riOrNull) in activities) {
                if (pkg.isBlank() || pkg == "ren.onekb.openuu" || pkg == "com.android.shell") continue
                val bundleId = "$pkg@$userId"
                if (!seenBundles.add(bundleId)) continue

                val appInfo = queryAppInfoForUser(pkg, userId, pm) ?: riOrNull?.activityInfo?.applicationInfo
                val rawLabel = runCatching {
                    riOrNull?.loadLabel(pm)?.toString()?.trim()?.takeIf { it.isNotBlank() }
                        ?: appInfo?.loadLabel(pm)?.toString()?.trim()?.takeIf { it.isNotBlank() }
                }.getOrNull() ?: pkg

                val suffix = when {
                    userId == 0 -> ""
                    userId == 999 || profileName.contains("Clone", true) ||
                        profileName.contains("XSpace", true) ||
                        profileName.contains("Multi", true) ||
                        profileName.contains("双开", true) ||
                        profileName.contains("分身", true) -> " (分身)"
                    nonZeroCount == 1 -> " (分身)"
                    else -> " (分身 $userId)"
                }
                val displayName = "$rawLabel$suffix"
                val isUserApp = appInfo != null && (appInfo.flags and ApplicationInfo.FLAG_SYSTEM) == 0

                val iconKey = pkg
                val iconB64 = iconB64Cache.getOrPut(iconKey) {
                    val drawable = runCatching {
                        riOrNull?.loadIcon(pm) ?: appInfo?.loadIcon(pm)
                    }.getOrNull()
                    encodeDrawableToBase64Png(drawable, 56)
                }

                val entry = ResolvedAppEntry(
                    bundleId = bundleId,
                    pkg = pkg,
                    activityName = cls,
                    userId = userId,
                    displayName = displayName,
                    isUserApp = isUserApp,
                    iconPngB64 = iconB64
                )
                resolvedAppsCache[bundleId] = entry
                discovered.add(entry)
            }
        }

        val sorted = discovered.sortedWith(
            compareByDescending<ResolvedAppEntry> { it.pkg in priorityPkgs }
                .thenByDescending { it.isUserApp }
                .thenBy { it.pkg }
                .thenBy { it.userId }
        ).take(32)

        val openBundles = synchronized(windowsLock) {
            windowsById.values.map { it.bundleId }.toSet()
        }

        val out = JSONArray()
        val devLabel = "${android.os.Build.MANUFACTURER} ${android.os.Build.MODEL}".trim().ifBlank { "Android" }
        val openuuIcon = iconB64Cache.getOrPut(OpenUUConstants.FULL_DESKTOP_BUNDLE_ID) {
            val d = runCatching {
                pm.getApplicationInfo("ren.onekb.openuu", 0).loadIcon(pm)
            }.getOrNull()
            encodeDrawableToBase64Png(d, 64)
        }
        out.put(
            JSONObject().apply {
                put("bundle_id", OpenUUConstants.FULL_DESKTOP_BUNDLE_ID)
                put("name", "整台手机屏幕 ($devLabel)")
                put("pid", 0)
                put("window_count", if (OpenUUConstants.FULL_DESKTOP_BUNDLE_ID in openBundles) 1 else 0)
                put("icon_png_b64", openuuIcon)
            }
        )

        for (item in sorted) {
            out.put(
                JSONObject().apply {
                    put("bundle_id", item.bundleId)
                    put("name", item.displayName)
                    put("pid", item.userId)
                    put("window_count", if (item.bundleId in openBundles) 1 else 0)
                    put("icon_png_b64", item.iconPngB64)
                }
            )
        }
        return out
    }

    private fun discoverUserProfiles(): List<Pair<Int, String>> {
        val result = LinkedHashMap<Int, String>()
        result[0] = "Owner"

        // Parse `pm list users` (`UserInfo{0:Owner:4c13} running`, `UserInfo{999:XSpace:800010} running`)
        runCatching {
            val out = execLocalShellQuick(arrayOf("/system/bin/cmd", "user", "list"))
                .ifBlank { execLocalShellQuick(arrayOf("/system/bin/pm", "list", "users")) }
            val regex = Regex("""UserInfo\{(\d+):([^:}]+):""")
            for (match in regex.findAll(out)) {
                val uid = match.groupValues[1].toIntOrNull() ?: continue
                val name = match.groupValues[2].trim()
                result[uid] = name
            }
        }
        return result.entries.sortedBy { it.key }.map { it.key to it.value }
    }

    private fun queryLauncherActivitiesForUser(
        userId: Int,
        pm: PackageManager
    ): List<Triple<String, String, ResolveInfo?>> {
        val out = ArrayList<Triple<String, String, ResolveInfo?>>()
        val mainIntent = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_LAUNCHER)
        }

        // 1. Try Binder IPackageManager.queryIntentActivities(..., userId) for full ResolveInfo + Drawable
        runCatching {
            val atClass = Class.forName("android.app.ActivityThread")
            val ipm = atClass.getDeclaredMethod("getPackageManager").invoke(null)
            if (ipm != null) {
                val method = ipm.javaClass.methods.firstOrNull {
                    it.name == "queryIntentActivities" && it.parameterTypes.size == 4
                }
                if (method != null) {
                    val flagsArg: Any = if (method.parameterTypes[2] == java.lang.Long.TYPE) 0L else 0
                    val slice = method.invoke(ipm, mainIntent, null, flagsArg, userId)
                    if (slice != null) {
                        @Suppress("UNCHECKED_CAST")
                        val list = slice.javaClass.getMethod("getList").invoke(slice) as? List<ResolveInfo>
                        if (!list.isNullOrEmpty()) {
                            for (ri in list) {
                                val pkg = ri.activityInfo?.packageName.orEmpty()
                                val cls = ri.activityInfo?.name.orEmpty()
                                if (pkg.isNotBlank() && cls.isNotBlank()) {
                                    out.add(Triple(pkg, cls, ri))
                                }
                            }
                            return out
                        }
                    }
                }
            }
        }

        // 2. Fallback to PackageManager (for user 0) or `cmd package query-activities --brief --user <userId>`
        if (userId == 0) {
            runCatching {
                val list = pm.queryIntentActivities(mainIntent, 0)
                for (ri in list) {
                    val pkg = ri.activityInfo?.packageName.orEmpty()
                    val cls = ri.activityInfo?.name.orEmpty()
                    if (pkg.isNotBlank() && cls.isNotBlank()) {
                        out.add(Triple(pkg, cls, ri))
                    }
                }
                if (out.isNotEmpty()) return out
            }
        }

        runCatching {
            val raw = execLocalShellQuick(
                arrayOf(
                    "/system/bin/cmd",
                    "package",
                    "query-activities",
                    "--brief",
                    "--user",
                    userId.toString(),
                    "-a",
                    "android.intent.action.MAIN",
                    "-c",
                    "android.intent.category.LAUNCHER"
                )
            )
            for (line in raw.lineSequence()) {
                val trimmed = line.trim()
                if ('/' !in trimmed || ' ' in trimmed || trimmed.startsWith("priority=")) continue
                val comp = ComponentName.unflattenFromString(trimmed) ?: continue
                out.add(Triple(comp.packageName, comp.className, null))
            }
        }
        return out
    }

    private fun queryAppInfoForUser(pkg: String, userId: Int, pm: PackageManager): ApplicationInfo? {
        runCatching {
            val atClass = Class.forName("android.app.ActivityThread")
            val ipm = atClass.getDeclaredMethod("getPackageManager").invoke(null) ?: return@runCatching
            val method = ipm.javaClass.methods.firstOrNull {
                it.name == "getApplicationInfo" && it.parameterTypes.size == 3
            } ?: return@runCatching
            val flagsArg: Any = if (method.parameterTypes[1] == java.lang.Long.TYPE) 0L else 0
            return method.invoke(ipm, pkg, flagsArg, userId) as? ApplicationInfo
        }
        return runCatching { pm.getApplicationInfo(pkg, 0) }.getOrNull()
    }

    private fun launchAppOnDisplay(pkg: String, userId: Int, targetDisplayId: Int) {
        val canonical = "$pkg@$userId"
        var activityName = resolvedAppsCache[canonical]?.activityName.orEmpty()

        if (activityName.isBlank()) {
            val resolved = execLocalShellQuick(
                arrayOf(
                    "/system/bin/cmd",
                    "package",
                    "resolve-activity",
                    "--brief",
                    "--user",
                    userId.toString(),
                    "-c",
                    "android.intent.category.LAUNCHER",
                    pkg
                )
            ).lineSequence().map { it.trim() }.lastOrNull { '/' in it && !it.startsWith("priority=") }.orEmpty()
            val comp = ComponentName.unflattenFromString(resolved)
            if (comp != null) {
                activityName = comp.className
            }
        }

        Thread({
            val cmdArgs = if (activityName.isNotBlank()) {
                arrayOf(
                    "/system/bin/cmd",
                    "activity",
                    "start-activity",
                    "--user",
                    userId.toString(),
                    "--display",
                    targetDisplayId.toString(),
                    "--windowingMode",
                    "1",
                    "-a",
                    "android.intent.action.MAIN",
                    "-c",
                    "android.intent.category.LAUNCHER",
                    "-f",
                    "0x10200000",
                    "-n",
                    "$pkg/$activityName"
                )
            } else {
                arrayOf(
                    "/system/bin/cmd",
                    "activity",
                    "start-activity",
                    "--user",
                    userId.toString(),
                    "--display",
                    targetDisplayId.toString(),
                    "-a",
                    "android.intent.action.MAIN",
                    "-c",
                    "android.intent.category.LAUNCHER",
                    "-f",
                    "0x10200000",
                    pkg
                )
            }
            val out = execLocalShellQuick(cmdArgs)
            logLine("Launch $pkg@$userId -> display=$targetDisplayId ($activityName): ${out.replace('\n', ' ').take(160)}")
        }, "OpenUULaunch-$pkg").apply {
            isDaemon = true
            start()
        }
    }

    private fun execLocalShellQuick(cmd: Array<String>): String {
        return try {
            val proc = ProcessBuilder(*cmd)
                .redirectErrorStream(true)
                .start()
            val text = proc.inputStream.bufferedReader().readText()
            proc.waitFor(4, TimeUnit.SECONDS)
            text.trim()
        } catch (_: Throwable) {
            ""
        }
    }

    private fun parseBundleAndUser(rawBundleId: String): Pair<String, Int> {
        val trimmed = rawBundleId.trim()
        val atIdx = trimmed.lastIndexOf('@')
        if (atIdx <= 0) return trimmed to 0
        val pkg = trimmed.substring(0, atIdx).trim()
        val uid = trimmed.substring(atIdx + 1).toIntOrNull() ?: 0
        return pkg to uid.coerceAtLeast(0)
    }

    fun stableWindowIdForBundle(canonicalBundle: String): Int {
        return 1000 + ((canonicalBundle.hashCode() and 0x3FFF_FFFF) % 900_000)
    }

    private fun encodeDrawableToBase64Png(drawable: Drawable?, sizePx: Int): String {
        if (drawable == null) return ""
        return runCatching {
            val bmp = if (drawable is BitmapDrawable && drawable.bitmap != null) {
                Bitmap.createScaledBitmap(drawable.bitmap, sizePx, sizePx, true)
            } else {
                val created = Bitmap.createBitmap(sizePx, sizePx, Bitmap.Config.ARGB_8888)
                val canvas = Canvas(created)
                drawable.setBounds(0, 0, sizePx, sizePx)
                drawable.draw(canvas)
                created
            }
            val out = ByteArrayOutputStream()
            bmp.compress(Bitmap.CompressFormat.PNG, 90, out)
            Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
        }.getOrDefault("")
    }

    // ---- Binary Socket Wire Helpers ----

    private fun sendEventJson(obj: JSONObject) {
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        synchronized(writeLock) {
            for (out in activeClientStreams) {
                runCatching {
                    out.writeByte(TYPE_EVENT_JSON)
                    out.writeInt(bytes.size)
                    out.write(bytes)
                    out.flush()
                }.onFailure {
                    activeClientStreams.remove(out)
                }
            }
        }
    }

    private fun sendEventJsonTo(target: DataOutputStream, obj: JSONObject) {
        val bytes = obj.toString().toByteArray(Charsets.UTF_8)
        synchronized(writeLock) {
            runCatching {
                target.writeByte(TYPE_EVENT_JSON)
                target.writeInt(bytes.size)
                target.write(bytes)
                target.flush()
            }
        }
    }

    private fun sendVideoFramePacket(
        windowId: Int,
        codec: Int,
        flags: Int,
        width: Int,
        height: Int,
        ptsUs: Long,
        h264Data: ByteArray
    ) {
        val hdr = ByteBuffer.allocate(20).apply {
            putInt(windowId)
            put(codec.toByte())
            put(flags.toByte())
            putShort(width.toShort())
            putShort(height.toShort())
            putShort(0)
            putLong(ptsUs)
        }.array()

        synchronized(writeLock) {
            for (out in activeClientStreams) {
                runCatching {
                    out.writeByte(TYPE_FRAME_VIDEO)
                    out.writeInt(20 + h264Data.size)
                    out.write(hdr)
                    out.write(h264Data)
                    out.flush()
                }.onFailure {
                    activeClientStreams.remove(out)
                }
            }
        }
    }
}

/**
 * Per-`displayId` privileged `InputManager` dispatcher (`UID 2000 shell` / `UID 0 root`).
 * Routes touch, wheel scroll, Back/Home, shortcuts, and paste events to each VirtualDisplay independently.
 */
private class PerDisplayInputInjector(
    context: Context,
    private val handler: Handler,
    private val onLog: (String) -> Unit,
    private val onEmitFallbackEvent: (JSONObject) -> Unit
) {

    private data class TouchState(
        var down: Boolean = false,
        var downTimeMs: Long = 0L,
        var lastX: Float = 0f,
        var lastY: Float = 0f
    )

    private val touchStates = ConcurrentHashMap<Int, TouchState>()
    @Volatile
    private var reportedPermissionBlock = false
    private var loggedFirstOk = false

    private val inputTarget: Any?
    private val injectMethod: java.lang.reflect.Method?

    init {
        val resolved = resolveInputManagerAndMethod(context)
        inputTarget = resolved.first
        injectMethod = resolved.second
        onLog(
            "InputInjector ready target=${inputTarget?.javaClass?.name ?: "null"} " +
                "method=${injectMethod?.name ?: "null"}"
        )
    }

    private fun resolveInputManagerAndMethod(context: Context): Pair<Any?, java.lang.reflect.Method?> {
        val candidates = ArrayList<Any?>()
        // 1. Android 14 / 15+ (`API 34+`): `android.hardware.input.InputManagerGlobal.getInstance()`
        runCatching {
            val globalCls = Class.forName("android.hardware.input.InputManagerGlobal")
            val inst = globalCls.getDeclaredMethod("getInstance").apply { isAccessible = true }.invoke(null)
            if (inst != null) candidates.add(inst)
        }
        // 2. Context system service (`android.hardware.input.InputManager`, API 26-35)
        runCatching {
            val svc = context.getSystemService(Context.INPUT_SERVICE)
            if (svc != null) candidates.add(svc)
        }
        // 3. Legacy Android 8-13 (`InputManager.getInstance()`)
        runCatching {
            val legacy = InputManager::class.java.getDeclaredMethod("getInstance").apply { isAccessible = true }.invoke(null)
            if (legacy != null) candidates.add(legacy)
        }
        // 4. Direct Binder `IInputManager` via `ServiceManager.getService("input")`
        runCatching {
            val smCls = Class.forName("android.os.ServiceManager")
            val binder = smCls.getMethod("getService", String::class.java).invoke(null, "input")
            if (binder != null) {
                val stubCls = Class.forName("android.hardware.input.IInputManager\$Stub")
                val iim = stubCls.getMethod("asInterface", Class.forName("android.os.IBinder")).invoke(null, binder)
                if (iim != null) candidates.add(iim)
            }
        }

        for (target in candidates) {
            if (target == null) continue
            val m = runCatching {
                target.javaClass.getMethod(
                    "injectInputEvent",
                    InputEvent::class.java,
                    Int::class.javaPrimitiveType
                ).apply { isAccessible = true }
            }.getOrNull() ?: runCatching {
                target.javaClass.getDeclaredMethod(
                    "injectInputEvent",
                    InputEvent::class.java,
                    Int::class.javaPrimitiveType
                ).apply { isAccessible = true }
            }.getOrNull()
            if (m != null) {
                return target to m
            }
        }
        return null to null
    }

    private val setDisplayIdMethod = runCatching {
        InputEvent::class.java.getMethod("setDisplayId", Int::class.javaPrimitiveType).apply {
            isAccessible = true
        }
    }.getOrNull() ?: runCatching {
        InputEvent::class.java.getDeclaredMethod("setDisplayId", Int::class.javaPrimitiveType).apply {
            isAccessible = true
        }
    }.getOrNull()

    private fun injectEventOnDisplay(event: InputEvent, displayId: Int): Boolean {
        val target = inputTarget
        val method = injectMethod
        if (target == null || method == null) {
            reportPermissionHintOnce("InputManager unavailable")
            return false
        }
        return try {
            setDisplayIdMethod?.invoke(event, displayId)
            // mode 0 = INJECT_INPUT_EVENT_MODE_ASYNC
            val res = method.invoke(target, event, 0)
            val ok = (res as? Boolean) ?: true
            if (!ok) {
                reportPermissionHintOnce("injectInputEvent returned false on display=$displayId")
            }
            ok
        } catch (t: Throwable) {
            val cause = (t as? java.lang.reflect.InvocationTargetException)?.targetException ?: t
            reportPermissionHintOnce("${cause.javaClass.simpleName}: ${cause.message}")
            false
        }
    }

    private fun reportPermissionHintOnce(reason: String) {
        if (reportedPermissionBlock) return
        reportedPermissionBlock = true
        onLog("INJECT_BLOCKED reason=$reason")
        onEmitFallbackEvent(
            JSONObject().apply {
                put("event", "input_permission_hint")
                put("reason", reason)
            }
        )
    }

    fun injectMouse(
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ) {
        handler.post {
            if (button == 1) {
                if (eventType == 1) {
                    if (!injectKeyTap(displayId, KeyEvent.KEYCODE_BACK, 0)) {
                        emitFallbackTouch(displayId, displayW, displayH, normX, normY, eventType, button)
                    }
                }
                return@post
            }
            if (button == 2) {
                if (eventType == 1) {
                    if (!injectKeyTap(displayId, KeyEvent.KEYCODE_HOME, 0)) {
                        emitFallbackTouch(displayId, displayW, displayH, normX, normY, eventType, button)
                    }
                }
                return@post
            }

            val sx = (normX.coerceIn(0f, 1f) * displayW.coerceAtLeast(2)).coerceIn(1f, (displayW - 2).coerceAtLeast(1).toFloat())
            val sy = (normY.coerceIn(0f, 1f) * displayH.coerceAtLeast(2)).coerceIn(1f, (displayH - 2).coerceAtLeast(1).toFloat())
            val st = touchStates.getOrPut(displayId) { TouchState() }
            val now = SystemClock.uptimeMillis()

            val action = when (eventType) {
                1 -> {
                    st.down = true
                    st.downTimeMs = now
                    st.lastX = sx
                    st.lastY = sy
                    MotionEvent.ACTION_DOWN
                }
                3 -> {
                    if (!st.down) return@post
                    st.lastX = sx
                    st.lastY = sy
                    MotionEvent.ACTION_MOVE
                }
                2 -> {
                    if (!st.down) return@post
                    st.down = false
                    st.lastX = sx
                    st.lastY = sy
                    MotionEvent.ACTION_UP
                }
                else -> return@post
            }

            val props = arrayOf(
                MotionEvent.PointerProperties().apply {
                    id = 0
                    toolType = MotionEvent.TOOL_TYPE_FINGER
                }
            )
            val coords = arrayOf(
                MotionEvent.PointerCoords().apply {
                    x = sx
                    y = sy
                    pressure = if (action == MotionEvent.ACTION_UP) 0f else 1f
                    size = 1f
                }
            )
            val ev = MotionEvent.obtain(
                st.downTimeMs,
                now,
                action,
                1,
                props,
                coords,
                0,
                0,
                1f,
                1f,
                0,
                0,
                InputDevice.SOURCE_TOUCHSCREEN,
                0
            )
            val ok = try {
                injectEventOnDisplay(ev, displayId)
            } finally {
                ev.recycle()
            }
            if (ok) {
                if (!loggedFirstOk && (action == MotionEvent.ACTION_DOWN || action == MotionEvent.ACTION_UP)) {
                    if (action == MotionEvent.ACTION_UP) loggedFirstOk = true
                    onLog("INJECT_MOUSE_OK display=$displayId action=$action x=${sx.toInt()} y=${sy.toInt()}")
                }
            } else {
                emitFallbackTouch(displayId, displayW, displayH, normX, normY, eventType, button)
            }
        }
    }

    private fun emitFallbackTouch(
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        eventType: Int,
        button: Int
    ) {
        onEmitFallbackEvent(
            JSONObject().apply {
                put("event", "fallback_touch")
                put("display_id", displayId)
                put("display_w", displayW)
                put("display_h", displayH)
                put("norm_x", normX.toDouble())
                put("norm_y", normY.toDouble())
                put("event_type", eventType)
                put("button", button)
            }
        )
    }

    fun injectScroll(
        displayId: Int,
        displayW: Int,
        displayH: Int,
        normX: Float,
        normY: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean
    ) {
        handler.post {
            val sx = (normX.coerceIn(0f, 1f) * displayW.coerceAtLeast(2)).coerceIn(4f, (displayW - 4).coerceAtLeast(4).toFloat())
            val sy = (normY.coerceIn(0f, 1f) * displayH.coerceAtLeast(2)).coerceIn(4f, (displayH - 4).coerceAtLeast(4).toFloat())
            val div = if (isContinuous) 28f else 2.4f
            val vScroll = (deltaY / div).coerceIn(-8f, 8f)
            val hScroll = (deltaX / div).coerceIn(-8f, 8f)
            if (kotlin.math.abs(vScroll) < 0.02f && kotlin.math.abs(hScroll) < 0.02f) return@post

            val now = SystemClock.uptimeMillis()
            val props = arrayOf(
                MotionEvent.PointerProperties().apply {
                    id = 0
                    toolType = MotionEvent.TOOL_TYPE_MOUSE
                }
            )
            val coords = arrayOf(
                MotionEvent.PointerCoords().apply {
                    x = sx
                    y = sy
                    setAxisValue(MotionEvent.AXIS_VSCROLL, vScroll)
                    setAxisValue(MotionEvent.AXIS_HSCROLL, hScroll)
                }
            )
            val ev = MotionEvent.obtain(
                now,
                now,
                MotionEvent.ACTION_SCROLL,
                1,
                props,
                coords,
                0,
                0,
                1f,
                1f,
                0,
                0,
                InputDevice.SOURCE_MOUSE,
                0
            )
            val ok = try {
                injectEventOnDisplay(ev, displayId)
            } finally {
                ev.recycle()
            }
            if (!ok) {
                onEmitFallbackEvent(
                    JSONObject().apply {
                        put("event", "fallback_scroll")
                        put("display_id", displayId)
                        put("display_w", displayW)
                        put("display_h", displayH)
                        put("norm_x", normX.toDouble())
                        put("norm_y", normY.toDouble())
                        put("dx", deltaX.toDouble())
                        put("dy", deltaY.toDouble())
                        put("continuous", isContinuous)
                    }
                )
            }
        }
    }

    fun injectPasteKey(displayId: Int) {
        handler.post {
            injectKeyTap(displayId, KeyEvent.KEYCODE_PASTE, 0)
        }
    }

    fun injectMacKey(displayId: Int, macKeyCode: Int, isDown: Boolean, macModifiers: Int) {
        val androidKey = mapMacKeyToAndroidKeyCode(macKeyCode) ?: return
        var meta = 0
        if ((macModifiers and (MacModifiers.COMMAND or MacModifiers.CONTROL)) != 0) {
            meta = meta or KeyEvent.META_CTRL_ON or KeyEvent.META_CTRL_LEFT_ON
        }
        if ((macModifiers and MacModifiers.SHIFT) != 0) {
            meta = meta or KeyEvent.META_SHIFT_ON or KeyEvent.META_SHIFT_LEFT_ON
        }
        if ((macModifiers and MacModifiers.OPTION) != 0) {
            meta = meta or KeyEvent.META_ALT_ON or KeyEvent.META_ALT_LEFT_ON
        }

        handler.post {
            val now = SystemClock.uptimeMillis()
            val action = if (isDown) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP
            val ev = KeyEvent(
                now,
                now,
                action,
                androidKey,
                0,
                meta,
                KeyCharacterMap.VIRTUAL_KEYBOARD,
                0,
                0,
                InputDevice.SOURCE_KEYBOARD
            )
            injectEventOnDisplay(ev, displayId)
        }
    }

    private fun injectKeyTap(displayId: Int, keyCode: Int, metaState: Int): Boolean {
        val now = SystemClock.uptimeMillis()
        val down = KeyEvent(
            now,
            now,
            KeyEvent.ACTION_DOWN,
            keyCode,
            0,
            metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            0,
            0,
            InputDevice.SOURCE_KEYBOARD
        )
        val up = KeyEvent(
            now,
            now + 12L,
            KeyEvent.ACTION_UP,
            keyCode,
            0,
            metaState,
            KeyCharacterMap.VIRTUAL_KEYBOARD,
            0,
            0,
            InputDevice.SOURCE_KEYBOARD
        )
        val okDown = injectEventOnDisplay(down, displayId)
        val okUp = injectEventOnDisplay(up, displayId)
        return okDown && okUp
    }

    private fun mapMacKeyToAndroidKeyCode(mac: Int): Int? = when (mac) {
        MacKeyCodes.RETURN -> KeyEvent.KEYCODE_ENTER
        MacKeyCodes.TAB -> KeyEvent.KEYCODE_TAB
        MacKeyCodes.SPACE -> KeyEvent.KEYCODE_SPACE
        MacKeyCodes.DELETE -> KeyEvent.KEYCODE_DEL
        MacKeyCodes.FORWARD_DELETE -> KeyEvent.KEYCODE_FORWARD_DEL
        MacKeyCodes.ESCAPE -> KeyEvent.KEYCODE_BACK
        MacKeyCodes.LEFT -> KeyEvent.KEYCODE_DPAD_LEFT
        MacKeyCodes.RIGHT -> KeyEvent.KEYCODE_DPAD_RIGHT
        MacKeyCodes.DOWN -> KeyEvent.KEYCODE_DPAD_DOWN
        MacKeyCodes.UP -> KeyEvent.KEYCODE_DPAD_UP
        MacKeyCodes.HOME -> KeyEvent.KEYCODE_MOVE_HOME
        MacKeyCodes.END -> KeyEvent.KEYCODE_MOVE_END
        MacKeyCodes.PAGE_UP -> KeyEvent.KEYCODE_PAGE_UP
        MacKeyCodes.PAGE_DOWN -> KeyEvent.KEYCODE_PAGE_DOWN
        MacKeyCodes.A -> KeyEvent.KEYCODE_A
        MacKeyCodes.B -> KeyEvent.KEYCODE_B
        MacKeyCodes.C -> KeyEvent.KEYCODE_C
        MacKeyCodes.D -> KeyEvent.KEYCODE_D
        MacKeyCodes.E -> KeyEvent.KEYCODE_E
        MacKeyCodes.F -> KeyEvent.KEYCODE_F
        MacKeyCodes.G -> KeyEvent.KEYCODE_G
        MacKeyCodes.H -> KeyEvent.KEYCODE_H
        MacKeyCodes.I -> KeyEvent.KEYCODE_I
        MacKeyCodes.J -> KeyEvent.KEYCODE_J
        MacKeyCodes.K -> KeyEvent.KEYCODE_K
        MacKeyCodes.L -> KeyEvent.KEYCODE_L
        MacKeyCodes.M -> KeyEvent.KEYCODE_M
        MacKeyCodes.N -> KeyEvent.KEYCODE_N
        MacKeyCodes.O -> KeyEvent.KEYCODE_O
        MacKeyCodes.P -> KeyEvent.KEYCODE_P
        MacKeyCodes.Q -> KeyEvent.KEYCODE_Q
        MacKeyCodes.R -> KeyEvent.KEYCODE_R
        MacKeyCodes.S -> KeyEvent.KEYCODE_S
        MacKeyCodes.T -> KeyEvent.KEYCODE_T
        MacKeyCodes.U -> KeyEvent.KEYCODE_U
        MacKeyCodes.V -> KeyEvent.KEYCODE_V
        MacKeyCodes.W -> KeyEvent.KEYCODE_W
        MacKeyCodes.X -> KeyEvent.KEYCODE_X
        MacKeyCodes.Y -> KeyEvent.KEYCODE_Y
        MacKeyCodes.Z -> KeyEvent.KEYCODE_Z
        MacKeyCodes.NUM_0 -> KeyEvent.KEYCODE_0
        MacKeyCodes.NUM_1 -> KeyEvent.KEYCODE_1
        MacKeyCodes.NUM_2 -> KeyEvent.KEYCODE_2
        MacKeyCodes.NUM_3 -> KeyEvent.KEYCODE_3
        MacKeyCodes.NUM_4 -> KeyEvent.KEYCODE_4
        MacKeyCodes.NUM_5 -> KeyEvent.KEYCODE_5
        MacKeyCodes.NUM_6 -> KeyEvent.KEYCODE_6
        MacKeyCodes.NUM_7 -> KeyEvent.KEYCODE_7
        MacKeyCodes.NUM_8 -> KeyEvent.KEYCODE_8
        MacKeyCodes.NUM_9 -> KeyEvent.KEYCODE_9
        MacKeyCodes.MINUS -> KeyEvent.KEYCODE_MINUS
        MacKeyCodes.EQUAL -> KeyEvent.KEYCODE_EQUALS
        MacKeyCodes.LEFT_BRACKET -> KeyEvent.KEYCODE_LEFT_BRACKET
        MacKeyCodes.RIGHT_BRACKET -> KeyEvent.KEYCODE_RIGHT_BRACKET
        MacKeyCodes.BACKSLASH -> KeyEvent.KEYCODE_BACKSLASH
        MacKeyCodes.SEMICOLON -> KeyEvent.KEYCODE_SEMICOLON
        MacKeyCodes.QUOTE -> KeyEvent.KEYCODE_APOSTROPHE
        MacKeyCodes.COMMA -> KeyEvent.KEYCODE_COMMA
        MacKeyCodes.PERIOD -> KeyEvent.KEYCODE_PERIOD
        MacKeyCodes.SLASH -> KeyEvent.KEYCODE_SLASH
        MacKeyCodes.GRAVE -> KeyEvent.KEYCODE_GRAVE
        else -> null
    }
}

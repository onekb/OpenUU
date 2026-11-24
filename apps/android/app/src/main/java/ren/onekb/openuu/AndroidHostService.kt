package ren.onekb.openuu

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.MediaStore
import android.util.Base64
import android.util.DisplayMetrics
import android.util.Log
import android.view.Display
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * Foreground service hosting the Android controlled-device (`Host`) pipeline:
 * - Dedicated `OpenUURuntime` listener (LAN QUIC + mDNS + 9-digit Coord + Iroh P2P/Relay)
 * - Single persistent `MediaProjection` + `VirtualDisplay` (Android 14/15 compliant)
 * - Hardware H.264 Annex-B `ScreenCaptureEncoder` + Android 10+ `SystemAudioEncoder`
 * - Dispatches remote pointer, scroll, shortcut, and IME text events to [OpenUURemoteInputService]
 */
class AndroidHostService : Service(), NativeCallbackListener {

    companion object {
        private const val TAG = "OpenUUHostSvc"
        private const val CHANNEL_ID = "openuu_android_host_channel"
        private const val NOTIF_ID = 39482

        const val ACTION_START_HOST = "ren.onekb.openuu.action.START_HOST"
        const val ACTION_STOP_HOST = "ren.onekb.openuu.action.STOP_HOST"
        const val ACTION_DISCONNECT_CLIENT = "ren.onekb.openuu.action.DISCONNECT_CLIENT"
        const val ACTION_REFRESH_PIN = "ren.onekb.openuu.action.REFRESH_PIN"

        const val EXTRA_RESULT_CODE = "extra_mp_result_code"
        const val EXTRA_RESULT_DATA = "extra_mp_result_data"
        const val EXTRA_PREFERRED_PIN = "extra_preferred_pin"
        const val EXTRA_BIND_PORT = "extra_bind_port"
        const val EXTRA_SYNTHETIC_MODE = "extra_synthetic_mode"

        private val _hostState = MutableStateFlow(LocalHostUiState())
        val hostState: StateFlow<LocalHostUiState> = _hostState.asStateFlow()

        private val _hostLogs = MutableStateFlow<List<String>>(emptyList())
        val hostLogs: StateFlow<List<String>> = _hostLogs.asStateFlow()

        private fun emitHostLog(msg: String) {
            Log.i(TAG, msg)
            _hostLogs.update { prev -> (prev + "[被控端] $msg").takeLast(80) }
        }
    }

    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var hostRuntimeHandle: Long = 0L

    private var mediaProjection: MediaProjection? = null
    private var virtualDisplay: VirtualDisplay? = null
    private var syntheticMode: Boolean = false

    private val streamLock = Any()
    private var videoEncoder: ScreenCaptureEncoder? = null
    private var audioEncoder: SystemAudioEncoder? = null

    @Volatile
    private var activeWindowId: Int = 0
    private var activeWindowTitle: String = "手机屏幕"
    private var activeWindowIconB64: String = ""

    @Volatile
    private var currentEncWidth: Int = 720

    @Volatile
    private var currentEncHeight: Int = 1600

    @Volatile
    private var clientWantsAudio: Boolean = true

    @Volatile
    private var clientWantsMuteHost: Boolean = false

    private val encodedFrameCounter = AtomicLong(0L)
    private val iconCacheB64 = ConcurrentHashMap<String, String>()
    private var lastSyncedClipboardHash: String = ""
    @Volatile
    private var lastAppsPushedAtMs: Long = 0L

    private var clipboardManager: ClipboardManager? = null
    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (_hostState.value.connectedClientName.isBlank()) return@OnPrimaryClipChangedListener
        pushHostClipboardToClient()
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit
        override fun onDisplayChanged(displayId: Int) {
            if (displayId != Display.DEFAULT_DISPLAY) return
            if (activeWindowId == 0) return
            mainHandler.removeCallbacks(recheckOrientationRunnable)
            mainHandler.postDelayed(recheckOrientationRunnable, 180L)
        }
    }

    private val recheckOrientationRunnable = Runnable {
        if (activeWindowId == 0) return@Runnable
        val (physW, physH, dpi) = queryDisplayMetrics()
        val (newEncW, newEncH) = ScreenCaptureEncoder.computeAlignedEncodeSize(physW, physH)
        if (newEncW != currentEncWidth || newEncH != currentEncHeight) {
            emitHostLog("检测到屏幕旋转，切换编码分辨率 ${newEncW}x${newEncH}")
            serviceScope.launch {
                restartVideoStreamForSize(newEncW, newEncH, dpi)
            }
        }
    }

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            emitHostLog("系统屏幕共享授权已结束，自动停止本机被控")
            stopHostCompletely()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        clipboardManager = runCatching {
            getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
        }.getOrNull()
        runCatching {
            clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        }
        runCatching {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
            dm?.registerDisplayListener(displayListener, mainHandler)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP_HOST -> {
                stopHostCompletely()
                return START_NOT_STICKY
            }
            ACTION_DISCONNECT_CLIENT -> {
                val handle = hostRuntimeHandle
                if (handle != 0L) {
                    OpenUUNativeBridge.nativeDisconnect(handle)
                }
                stopActiveMediaStreams()
                _hostState.update {
                    it.copy(
                        connectedClientName = "",
                        linkBadge = "",
                        isStreamingScreen = false,
                        audioCaptureActive = false
                    )
                }
                updateOngoingNotification()
                return START_STICKY
            }
            ACTION_REFRESH_PIN -> {
                val cur = _hostState.value
                if (cur.isRunning && hostRuntimeHandle != 0L) {
                    val freshPin = OpenUUNativeBridge.nativeGenerateAccessCode(false)
                    saveHostPinPref(freshPin)
                    OpenUUNativeBridge.nativeStopHost(hostRuntimeHandle)
                    val started = OpenUUNativeBridge.nativeStartHost(
                        hostRuntimeHandle,
                        cur.boundPort,
                        freshPin
                    )
                    val parsed = parsePortAndPin(started)
                    if (parsed != null) {
                        _hostState.update {
                            it.copy(
                                boundPort = parsed.first,
                                pin = parsed.second,
                                connectedClientName = "",
                                isStreamingScreen = false
                            )
                        }
                        emitHostLog("已刷新本机访问密码")
                        refreshHostIdentityTicketDelayed()
                        updateOngoingNotification()
                    }
                }
                return START_STICKY
            }
            ACTION_START_HOST -> {
                handleStartHostIntent(intent)
                return START_STICKY
            }
            else -> {
                if (!_hostState.value.isRunning) {
                    stopSelf()
                }
                return START_NOT_STICKY
            }
        }
    }

    override fun onDestroy() {
        runCatching {
            clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        }
        runCatching {
            val dm = getSystemService(Context.DISPLAY_SERVICE) as? DisplayManager
            dm?.unregisterDisplayListener(displayListener)
        }
        teardownInternal()
        serviceScope.cancel()
        super.onDestroy()
    }

    private fun handleStartHostIntent(intent: Intent) {
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
        val resultData: Intent? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        val wantSynthetic = intent.getBooleanExtra(EXTRA_SYNTHETIC_MODE, false)
        val preferredPin = intent.getStringExtra(EXTRA_PREFERRED_PIN)?.trim().orEmpty()
            .ifEmpty { loadSavedHostPinPref() }
        val bindPort = intent.getIntExtra(EXTRA_BIND_PORT, OpenUUConstants.DEFAULT_PORT)

        val hasValidProjection = (resultCode == Activity.RESULT_OK && resultData != null)
        if (!hasValidProjection && !wantSynthetic) {
            _hostState.update { it.copy(lastError = "未获得屏幕录制授权") }
            stopSelf()
            return
        }

        // Start foreground BEFORE obtaining MediaProjection (strictly required on Android 14 / API 34+)
        val initialNotif = buildOngoingNotification("正在启动本机被控服务...")
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val fgType = if (hasValidProjection) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                } else {
                    0
                }
                if (fgType != 0) {
                    startForeground(NOTIF_ID, initialNotif, fgType)
                } else {
                    startForeground(NOTIF_ID, initialNotif)
                }
            } else {
                startForeground(NOTIF_ID, initialNotif)
            }
        } catch (t: Throwable) {
            emitHostLog("启动前台服务失败: ${t.message}")
            _hostState.update { it.copy(lastError = "启动前台保活失败: ${t.message}") }
            stopSelf()
            return
        }

        // Clean up any previous projection / runtime if restarting
        stopActiveMediaStreams()
        releaseProjectionAndVirtualDisplay()
        syntheticMode = wantSynthetic && !hasValidProjection

        if (hasValidProjection) {
            try {
                val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                val mp = mpm.getMediaProjection(resultCode, resultData!!)
                if (mp == null) {
                    _hostState.update { it.copy(lastError = "系统拒绝创建 MediaProjection") }
                    stopHostCompletely()
                    return
                }
                mp.registerCallback(projectionCallback, mainHandler)
                val (physW, physH, dpi) = queryDisplayMetrics()
                val (encW, encH) = ScreenCaptureEncoder.computeAlignedEncodeSize(physW, physH)
                currentEncWidth = encW
                currentEncHeight = encH
                // Create the single reusable VirtualDisplay (surface = null while idle)
                val vd = mp.createVirtualDisplay(
                    "OpenUUAndroidHost",
                    encW,
                    encH,
                    dpi,
                    DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                    null,
                    null,
                    mainHandler
                )
                mediaProjection = mp
                virtualDisplay = vd
            } catch (t: Throwable) {
                emitHostLog("初始化屏幕捕获异常: ${t.message}")
                _hostState.update { it.copy(lastError = "初始化录屏失败: ${t.message}") }
                stopHostCompletely()
                return
            }
        } else {
            val (physW, physH, _) = queryDisplayMetrics()
            val (encW, encH) = ScreenCaptureEncoder.computeAlignedEncodeSize(physW, physH)
            currentEncWidth = encW
            currentEncHeight = encH
        }

        if (hostRuntimeHandle == 0L) {
            OpenUUNativeBridge.nativeInitAndroidContext(applicationContext)
            OpenUUNativeBridge.nativeSetAppDirs(filesDir.absolutePath, cacheDir.absolutePath)
            val devName = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifBlank { "OpenUU-Android" }
            hostRuntimeHandle = OpenUUNativeBridge.nativeCreateRuntime(devName, this)
        }

        val handle = hostRuntimeHandle
        if (handle == 0L) {
            _hostState.update { it.copy(lastError = "创建 Host Runtime 失败") }
            stopHostCompletely()
            return
        }

        OpenUUNativeBridge.nativeStopHost(handle)
        val started = OpenUUNativeBridge.nativeStartHost(handle, bindPort, preferredPin)
        val parsed = parsePortAndPin(started)
        if (parsed == null) {
            // Retry on ephemeral UDP port if 39481 is already bound
            val fallbackStarted = OpenUUNativeBridge.nativeStartHost(handle, 0, preferredPin)
            val fallbackParsed = parsePortAndPin(fallbackStarted)
            if (fallbackParsed == null) {
                _hostState.update { it.copy(lastError = "监听端口绑定失败") }
                stopHostCompletely()
                return
            }
            onHostBoundSuccess(fallbackParsed.first, fallbackParsed.second)
        } else {
            onHostBoundSuccess(parsed.first, parsed.second)
        }
    }

    private fun onHostBoundSuccess(boundPort: Int, activePin: String) {
        saveHostPinPref(activePin)
        encodedFrameCounter.set(0L)
        _hostState.update {
            it.copy(
                isRunning = true,
                boundPort = boundPort,
                pin = activePin,
                coordStatus = "正在注册跨网寻址...",
                connectedClientName = "",
                linkBadge = "",
                isStreamingScreen = false,
                encodedFrames = 0L,
                audioCaptureActive = false,
                lastError = ""
            )
        }
        emitHostLog("HOST_READY port=$boundPort pin=$activePin synthetic=$syntheticMode")
        updateOngoingNotification()
        refreshHostIdentityTicketDelayed()
    }

    private fun refreshHostIdentityTicketDelayed() {
        serviceScope.launch {
            var loggedTicket = false
            for (delayMs in listOf(400L, 1200L, 2500L, 5000L)) {
                delay(delayMs)
                val handle = hostRuntimeHandle
                if (handle == 0L || !_hostState.value.isRunning) break
                val snap = IdentitySnapshot.parse(OpenUUNativeBridge.nativeGetIdentityJson(handle))
                if (!loggedTicket && snap.hostTicket.startsWith("openuu://")) {
                    loggedTicket = true
                    emitHostLog("HOST_TICKET_READY ticket=${snap.hostTicket}")
                }
                _hostState.update {
                    it.copy(
                        hostTicket = snap.hostTicket,
                        coordStatus = snap.coordStatus.ifBlank { it.coordStatus }
                    )
                }
            }
        }
    }

    // --- NativeCallbackListener (Host Side) ---

    override fun onStatus(msg: String) {
        emitHostLog(msg)
        when {
            msg.startsWith("client connected:") -> {
                val remoteName = msg.removePrefix("client connected:")
                    .substringBefore("(")
                    .trim()
                    .ifBlank { "远端设备" }
                clientWantsAudio = true
                clientWantsMuteHost = false
                _hostState.update {
                    it.copy(
                        connectedClientName = remoteName,
                        lastError = ""
                    )
                }
                lastAppsPushedAtMs = 0L
                updateOngoingNotification()
                serviceScope.launch {
                    pushInstalledAppsToClient(force = true)
                    refreshHostIdentityTicketDelayed()
                }
            }
            msg.contains("disconnected") -> {
                stopActiveMediaStreams()
                _hostState.update {
                    it.copy(
                        connectedClientName = "",
                        linkBadge = "",
                        isStreamingScreen = false,
                        audioCaptureActive = false
                    )
                }
                updateOngoingNotification()
            }
        }
    }

    override fun onControl(json: String) {
        val evt = ControlEvent.parse(json)
        when (evt) {
            ControlEvent.ListAppsReq -> {
                serviceScope.launch { pushInstalledAppsToClient(force = false) }
            }
            is ControlEvent.StartSession -> {
                emitHostLog("收到远端启动画面请求 bundle=${evt.bundleId}")
                serviceScope.launch { startStreamingSession(evt.bundleId) }
            }
            is ControlEvent.StopSession -> {
                if (evt.windowId == 0 || evt.windowId == activeWindowId) {
                    stopActiveMediaStreams()
                    sendEmptyWindowTopology()
                    _hostState.update { it.copy(isStreamingScreen = false, audioCaptureActive = false) }
                    updateOngoingNotification()
                }
            }
            is ControlEvent.RequestKeyframe -> {
                synchronized(streamLock) {
                    videoEncoder?.requestKeyframe()
                }
            }
            is ControlEvent.AudioControl -> {
                clientWantsAudio = evt.audioEnabled
                clientWantsMuteHost = evt.muteHost
                reconcileAudioCapture()
            }
            is ControlEvent.LinkQuality -> {
                val modeLabel = when (evt.linkMode) {
                    "lan" -> "局域网直连"
                    "p2p", "ipv6", "wan_direct" -> "P2P 直连"
                    "relay", "wan_relay" -> "中继加速"
                    else -> evt.linkMode.uppercase()
                }
                val badge = if (evt.rttMs > 0) "$modeLabel · ${evt.rttMs}ms" else modeLabel
                val targetBps = when (evt.linkMode) {
                    "lan" -> 6_000_000
                    "p2p", "ipv6", "wan_direct" -> 4_000_000
                    else -> 2_200_000
                }
                synchronized(streamLock) {
                    videoEncoder?.updateBitrate(targetBps)
                }
                _hostState.update { it.copy(linkBadge = badge) }
            }
            is ControlEvent.Mouse -> {
                val (normX, normY) = toNormalizedCoords(evt.x, evt.y)
                OpenUURemoteInputService.instance?.dispatchMouse(
                    normX = normX,
                    normY = normY,
                    eventType = evt.eventType,
                    button = evt.button
                )
                if (evt.eventType == 1 || evt.eventType == 2) {
                    Log.d(TAG, "HOST_INPUT mouse type=${evt.eventType} btn=${evt.button} norm=($normX,$normY)")
                }
            }
            is ControlEvent.Scroll -> {
                val (normX, normY) = toNormalizedCoords(evt.x, evt.y)
                OpenUURemoteInputService.instance?.dispatchScroll(
                    normX = normX,
                    normY = normY,
                    deltaX = evt.deltaX,
                    deltaY = evt.deltaY,
                    isContinuous = evt.isContinuous
                )
                Log.d(TAG, "HOST_INPUT scroll dx=${evt.deltaX} dy=${evt.deltaY}")
            }
            is ControlEvent.Key -> {
                OpenUURemoteInputService.instance?.dispatchKey(
                    keyCode = evt.keyCode,
                    isDown = evt.isDown,
                    modifiers = evt.modifiers
                )
                Log.d(TAG, "HOST_INPUT key code=${evt.keyCode} down=${evt.isDown} mods=${evt.modifiers}")
            }
            is ControlEvent.TextCommit -> {
                OpenUURemoteInputService.instance?.dispatchTextCommit(evt.text)
                emitHostLog("HOST_TEXT_COMMIT len=${evt.text.length} text=${evt.text}")
            }
            is ControlEvent.ClipboardSync -> {
                applyIncomingClipboard(evt)
            }
            is ControlEvent.FileDrop -> {
                serviceScope.launch { saveIncomingDroppedFile(evt) }
            }
            else -> Unit
        }
    }

    override fun onVideo(
        codec: Int,
        flags: Int,
        windowId: Int,
        timestampUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    ) = Unit

    override fun onAudio(
        codec: Int,
        flags: Int,
        channels: Int,
        sampleRate: Int,
        timestampUs: Long,
        data: ByteArray
    ) = Unit

    override fun onProbeResult(json: String) = Unit

    // --- Streaming Pipeline ---

    private fun startStreamingSession(bundleId: String) {
        val handle = hostRuntimeHandle
        if (handle == 0L) return

        val deviceLabel = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifBlank { "Android" }
        val isFullScreen = bundleId.isBlank() || bundleId == OpenUUConstants.FULL_DESKTOP_BUNDLE_ID

        if (isFullScreen) {
            activeWindowId = OpenUUConstants.FULL_DESKTOP_WINDOW_ID
            activeWindowTitle = "手机屏幕 ($deviceLabel)"
            activeWindowIconB64 = ""
        } else {
            launchTargetPackageIfPresent(bundleId)
            activeWindowId = stableWindowIdForPackage(bundleId)
            activeWindowTitle = resolveAppLabel(bundleId).ifBlank { bundleId }
            activeWindowIconB64 = iconCacheB64[bundleId].orEmpty()
        }

        val (physW, physH, dpi) = queryDisplayMetrics()
        val (encW, encH) = ScreenCaptureEncoder.computeAlignedEncodeSize(physW, physH)
        restartVideoStreamForSize(encW, encH, dpi)
        reconcileAudioCapture()

        _hostState.update {
            it.copy(
                isStreamingScreen = true,
                audioCaptureActive = audioEncoder?.isActive == true
            )
        }
        updateOngoingNotification()
    }

    private fun restartVideoStreamForSize(encW: Int, encH: Int, dpi: Int) {
        val handle = hostRuntimeHandle
        val winId = activeWindowId
        if (handle == 0L || winId == 0) return

        synchronized(streamLock) {
            currentEncWidth = encW
            currentEncHeight = encH

            virtualDisplay?.surface = null
            videoEncoder?.stop()
            videoEncoder = null

            val enc = ScreenCaptureEncoder(
                width = encW,
                height = encH,
                fps = 45,
                bitrateBps = 4_500_000,
                useSyntheticFrames = syntheticMode,
                onEncodedPacket = { codec, flags, ptsUs, w, h, bytes ->
                    val curWin = activeWindowId
                    val curHandle = hostRuntimeHandle
                    if (curHandle != 0L && curWin != 0) {
                        val rc = OpenUUNativeBridge.nativeSendVideoFrame(
                            curHandle,
                            codec,
                            flags,
                            curWin,
                            ptsUs,
                            w,
                            h,
                            bytes,
                            bytes.size
                        )
                        if (rc == 0) {
                            val total = encodedFrameCounter.incrementAndGet()
                            if (total == 1L || total == 5L || total % 60L == 0L) {
                                if (total <= 5L) {
                                    emitHostLog("HOST_VIDEO_SENT frames=$total ${w}x${h} bytes=${bytes.size}")
                                }
                                _hostState.update { it.copy(encodedFrames = total) }
                            }
                        }
                    }
                }
            )

            val surface = enc.start()
            if (surface == null) {
                emitHostLog("ERROR: 无法创建 H.264 硬件编码器")
                return
            }
            videoEncoder = enc

            if (!syntheticMode) {
                runCatching {
                    virtualDisplay?.resize(encW, encH, dpi)
                    virtualDisplay?.surface = surface
                }.onFailure {
                    emitHostLog("绑定 VirtualDisplay Surface 异常: ${it.message}")
                }
            }

            publishActiveWindowTopology(encW, encH)
            enc.requestKeyframe()
        }
    }

    private fun reconcileAudioCapture() {
        val mp = mediaProjection
        synchronized(streamLock) {
            if (!clientWantsAudio || activeWindowId == 0 || mp == null) {
                audioEncoder?.stop()
                audioEncoder = null
                _hostState.update { it.copy(audioCaptureActive = false) }
                return
            }
            val existing = audioEncoder
            if (existing != null && existing.isActive) {
                existing.updateMuteHost(clientWantsMuteHost)
                return
            }
            val created = SystemAudioEncoder(
                context = applicationContext,
                mediaProjection = mp,
                onEncodedAudio = { codec, flags, ch, sr, ptsUs, bytes ->
                    val curHandle = hostRuntimeHandle
                    if (curHandle != 0L && activeWindowId != 0) {
                        OpenUUNativeBridge.nativeSendAudioFrame(
                            curHandle,
                            codec,
                            flags,
                            ch,
                            sr,
                            ptsUs,
                            bytes,
                            bytes.size
                        )
                    }
                }
            )
            val ok = created.start(clientWantsMuteHost)
            audioEncoder = if (ok) created else null
            _hostState.update { it.copy(audioCaptureActive = ok) }
        }
    }

    private fun publishActiveWindowTopology(encW: Int, encH: Int) {
        val handle = hostRuntimeHandle
        val winId = activeWindowId
        if (handle == 0L || winId == 0) return

        val logicalW = (encW / 2.0f).coerceAtLeast(160f)
        val logicalH = (encH / 2.0f).coerceAtLeast(160f)

        val arr = JSONArray().put(
            JSONObject().apply {
                put("window_id", winId.toLong() and 0xFFFF_FFFFL)
                put("parent_window_id", 0)
                put("kind", 0)
                put("rel_x", 0.0)
                put("rel_y", 0.0)
                put("width", logicalW.toDouble())
                put("height", logicalH.toDouble())
                put("title", activeWindowTitle)
                if (activeWindowIconB64.isNotBlank()) {
                    put("icon_png_b64", activeWindowIconB64)
                }
            }
        )
        OpenUUNativeBridge.nativeSendWindowTopologyJson(handle, arr.toString())
    }

    private fun sendEmptyWindowTopology() {
        val handle = hostRuntimeHandle
        if (handle != 0L) {
            OpenUUNativeBridge.nativeSendWindowTopologyJson(handle, "[]")
        }
    }

    private fun stopActiveMediaStreams() {
        activeWindowId = 0
        synchronized(streamLock) {
            runCatching { virtualDisplay?.surface = null }
            videoEncoder?.stop()
            videoEncoder = null
            audioEncoder?.stop()
            audioEncoder = null
        }
    }

    private fun releaseProjectionAndVirtualDisplay() {
        runCatching { virtualDisplay?.release() }
        virtualDisplay = null
        runCatching {
            mediaProjection?.unregisterCallback(projectionCallback)
            mediaProjection?.stop()
        }
        mediaProjection = null
    }

    private fun stopHostCompletely() {
        teardownInternal()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    private fun teardownInternal() {
        stopActiveMediaStreams()
        releaseProjectionAndVirtualDisplay()
        val handle = hostRuntimeHandle
        hostRuntimeHandle = 0L
        if (handle != 0L) {
            runCatching { OpenUUNativeBridge.nativeStopHost(handle) }
            runCatching { OpenUUNativeBridge.nativeDestroyRuntime(handle) }
        }
        _hostState.update {
            LocalHostUiState(
                isRunning = false,
                pin = loadSavedHostPinPref(),
                coordStatus = "未开启被控"
            )
        }
    }

    // --- App List, Clipboard & File Drop Helpers ---

    private fun pushInstalledAppsToClient(force: Boolean = false) {
        val handle = hostRuntimeHandle
        if (handle == 0L) return
        val now = System.currentTimeMillis()
        if (!force && now - lastAppsPushedAtMs < 900L) {
            return
        }
        lastAppsPushedAtMs = now

        val devLabel = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifBlank { "Android" }
        val arr = JSONArray()

        // 1. Primary Full-Phone Screen entry
        val brandIconB64 = iconCacheB64.getOrPut(OpenUUConstants.FULL_DESKTOP_BUNDLE_ID) {
            encodeDrawableToBase64Png(applicationInfo.loadIcon(packageManager), 64)
        }
        arr.put(
            JSONObject().apply {
                put("bundle_id", OpenUUConstants.FULL_DESKTOP_BUNDLE_ID)
                put("name", "整台手机屏幕 ($devLabel)")
                put("pid", 0)
                put("window_count", 1)
                put("icon_png_b64", brandIconB64)
            }
        )

        // 2. Launchable Android apps (compact 56px icons so WAN/Relay handshake stays <35KB)
        runCatching {
            val mainIntent = Intent(Intent.ACTION_MAIN, null).apply {
                addCategory(Intent.CATEGORY_LAUNCHER)
            }
            val resolved = packageManager.queryIntentActivities(mainIntent, 0)
            val priorityPkgs = setOf(
                "com.tencent.mm",
                "com.tencent.mobileqq",
                "com.ss.android.lark",
                "com.alibaba.android.rimet",
                "com.android.chrome",
                "com.android.settings"
            )
            val seen = HashSet<String>()
            val items = resolved
                .mapNotNull { ri ->
                    val ai = ri.activityInfo?.applicationInfo
                    val pkg = ri.activityInfo?.packageName?.takeIf {
                        it.isNotBlank() && it != packageName && seen.add(it)
                    } ?: return@mapNotNull null
                    val isUserApp = ai != null && (ai.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) == 0
                    val label = ri.loadLabel(packageManager)?.toString()?.trim().orEmpty().ifBlank { pkg }
                    Triple(pkg, label, ri to isUserApp)
                }
                .sortedWith(
                    compareByDescending<Triple<String, String, Pair<android.content.pm.ResolveInfo, Boolean>>> {
                        it.first in priorityPkgs
                    }.thenByDescending {
                        it.third.second
                    }.thenBy {
                        it.second
                    }
                )
                .take(14)

            for ((pkg, label, pair) in items) {
                val iconB64 = iconCacheB64.getOrPut(pkg) {
                    encodeDrawableToBase64Png(pair.first.loadIcon(packageManager), 56)
                }
                arr.put(
                    JSONObject().apply {
                        put("bundle_id", pkg)
                        put("name", label)
                        put("pid", 0)
                        put("window_count", 1)
                        put("icon_png_b64", iconB64)
                    }
                )
            }
        }

        val jsonStr = arr.toString()
        val rc = OpenUUNativeBridge.nativeSendAppListJson(handle, jsonStr)
        emitHostLog("HOST_APPS_SENT count=${arr.length()} bytes=${jsonStr.length} rc=$rc")
    }

    private fun launchTargetPackageIfPresent(pkg: String) {
        runCatching {
            val launchIntent = packageManager.getLaunchIntentForPackage(pkg)?.apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            }
            if (launchIntent != null) {
                startActivity(launchIntent)
            }
        }.onFailure {
            emitHostLog("启动应用 $pkg 失败: ${it.message}")
        }
    }

    private fun resolveAppLabel(pkg: String): String {
        return runCatching {
            val ai = packageManager.getApplicationInfo(pkg, 0)
            packageManager.getApplicationLabel(ai)?.toString()?.trim().orEmpty()
        }.getOrDefault(pkg)
    }

    private fun stableWindowIdForPackage(pkg: String): Int {
        return 1000 + ((pkg.hashCode() and 0x3FFF_FFFF) % 900_000)
    }

    private fun toNormalizedCoords(logicalX: Float, logicalY: Float): Pair<Float, Float> {
        val lw = (currentEncWidth / 2.0f).coerceAtLeast(1f)
        val lh = (currentEncHeight / 2.0f).coerceAtLeast(1f)
        return (logicalX / lw).coerceIn(0f, 1f) to (logicalY / lh).coerceIn(0f, 1f)
    }

    private fun applyIncomingClipboard(evt: ControlEvent.ClipboardSync) {
        if (evt.contentHash.isNotBlank() && evt.contentHash == lastSyncedClipboardHash) return
        if (evt.clipKind == 0 && evt.text.isNotEmpty()) {
            lastSyncedClipboardHash = evt.contentHash.ifBlank { sha256Hex(evt.text.toByteArray()) }
            mainHandler.post {
                runCatching {
                    clipboardManager?.setPrimaryClip(ClipData.newPlainText("OpenUU", evt.text))
                }
            }
            emitHostLog("HOST_CLIPBOARD_SYNC text_len=${evt.text.length} text=${evt.text}")
        } else if (evt.clipKind == 1 && evt.imageB64.isNotEmpty()) {
            runCatching {
                val bytes = Base64.decode(evt.imageB64, Base64.DEFAULT)
                val bmp = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return@runCatching
                val savedName = "openuu_clip_${System.currentTimeMillis()}.png"
                val tmp = File(cacheDir, savedName)
                FileOutputStream(tmp).use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
                saveFileToDownloads(tmp, savedName, "image/png")
                emitHostLog("已保存远端剪贴板图片至下载目录: $savedName")
            }
        }
    }

    private fun pushHostClipboardToClient() {
        val handle = hostRuntimeHandle
        if (handle == 0L) return
        val text = runCatching {
            val clip = clipboardManager?.primaryClip
            if (clip != null && clip.itemCount > 0) {
                clip.getItemAt(0).coerceToText(this)?.toString().orEmpty()
            } else {
                ""
            }
        }.getOrDefault("")
        if (text.isEmpty()) return
        val hash = sha256Hex(text.toByteArray(Charsets.UTF_8))
        if (hash == lastSyncedClipboardHash) return
        lastSyncedClipboardHash = hash
        OpenUUNativeBridge.nativeSendClipboardText(handle, hash, text)
    }

    private fun saveIncomingDroppedFile(evt: ControlEvent.FileDrop) {
        val src = File(evt.localPath)
        if (!src.exists() || !src.isFile) return
        val safeName = src.name.ifBlank { "openuu_${System.currentTimeMillis()}.bin" }
        val ok = saveFileToDownloads(src, safeName, "*/*")
        if (ok) {
            emitHostLog("已接收远端文件并存入下载目录/OpenUU: $safeName")
        }
    }

    private fun saveFileToDownloads(srcFile: File, displayName: String, mimeType: String): Boolean {
        return runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, displayName)
                    put(MediaStore.Downloads.MIME_TYPE, mimeType)
                    put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/OpenUU")
                    put(MediaStore.Downloads.IS_PENDING, 1)
                }
                val resolver = contentResolver
                val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values) ?: return false
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(srcFile).use { input -> input.copyTo(out) }
                }
                values.clear()
                values.put(MediaStore.Downloads.IS_PENDING, 0)
                resolver.update(uri, values, null, null)
                true
            } else {
                val dir = File(getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS), "OpenUU")
                dir.mkdirs()
                srcFile.copyTo(File(dir, displayName), overwrite = true)
                true
            }
        }.getOrDefault(false)
    }

    private fun queryDisplayMetrics(): Triple<Int, Int, Int> {
        val wm = getSystemService(Context.WINDOW_SERVICE) as? WindowManager
            ?: return Triple(1080, 2400, 420)
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val bounds = wm.maximumWindowMetrics.bounds
            val dpi = resources.configuration.densityDpi.coerceAtLeast(160)
            Triple(bounds.width().coerceAtLeast(320), bounds.height().coerceAtLeast(320), dpi)
        } else {
            val dm = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay?.getRealMetrics(dm)
            Triple(dm.widthPixels.coerceAtLeast(320), dm.heightPixels.coerceAtLeast(320), dm.densityDpi.coerceAtLeast(160))
        }
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

    private fun parsePortAndPin(raw: String): Pair<Int, String>? {
        val idx = raw.indexOf(':')
        if (idx <= 0) return null
        val port = raw.substring(0, idx).toIntOrNull() ?: return null
        val pin = raw.substring(idx + 1).trim()
        if (port <= 0 || pin.isEmpty()) return null
        return port to pin
    }

    private fun loadSavedHostPinPref(): String {
        val prefs = getSharedPreferences("openuu_host_prefs", Context.MODE_PRIVATE)
        val existing = prefs.getString("host_pin", "")?.trim().orEmpty()
        if (existing.isNotEmpty()) return existing
        val generated = OpenUUNativeBridge.nativeGenerateAccessCode(false).ifBlank { "123456" }
        prefs.edit().putString("host_pin", generated).apply()
        return generated
    }

    private fun saveHostPinPref(pin: String) {
        if (pin.isBlank()) return
        getSharedPreferences("openuu_host_prefs", Context.MODE_PRIVATE)
            .edit()
            .putString("host_pin", pin.trim())
            .apply()
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    // --- Foreground Notification ---

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                CHANNEL_ID,
                "OpenUU 本机被控服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保持本机远程被控连接与屏幕共享在后台稳定运行"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun buildOngoingNotification(overrideBody: String? = null): Notification {
        val st = _hostState.value
        val body = overrideBody ?: when {
            st.connectedClientName.isNotBlank() && st.isStreamingScreen ->
                "正在向 ${st.connectedClientName} 共享屏幕 · 点击管理或随时断开"
            st.connectedClientName.isNotBlank() ->
                "${st.connectedClientName} 已连接 · 等待打开画面"
            else ->
                "等待远端连接 · 访问密码 ${st.pin}"
        }

        val openIntent = PendingIntent.getActivity(
            this,
            1,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val stopIntent = PendingIntent.getService(
            this,
            2,
            Intent(this, AndroidHostService::class.java).apply { action = ACTION_STOP_HOST },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("OpenUU 本机被控已开启")
            .setContentText(body)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openIntent)
            .addAction(0, "停止被控", stopIntent)
            .build()
    }

    private fun updateOngoingNotification() {
        if (!_hostState.value.isRunning) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        runCatching { nm.notify(NOTIF_ID, buildOngoingNotification()) }
    }
}

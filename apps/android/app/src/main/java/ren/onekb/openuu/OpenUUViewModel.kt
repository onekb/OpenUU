package ren.onekb.openuu

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.graphics.BitmapFactory
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.OpenableColumns
import android.util.Base64
import android.util.Log
import android.view.Surface
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicReference

enum class MainTab(val label: String) {
    CONNECT("连接"),
    DEVICES("设备簿"),
    REMOTE("远控视窗"),
    SETTINGS("设置与日志")
}

private data class E2EConfig(
    val target: String,
    val pin: String,
    val appBundleId: String,
    val autoTest: Boolean,
    var openedApp: Boolean = false,
    var autoTestSent: Boolean = false
)

class OpenUUViewModel(application: Application) : AndroidViewModel(application), NativeCallbackListener {

    private companion object {
        const val TAG = "OpenUUVM"
        const val E2E_TAG = "OpenUUE2E"
        const val MAX_LOGS = 200
    }

    private val appContext = application.applicationContext
    private val deviceBookRepo = DeviceBookRepository(appContext.filesDir)
    private val clipboardManager: ClipboardManager? = runCatching {
        appContext.getSystemService(Context.CLIPBOARD_SERVICE) as? ClipboardManager
    }.getOrNull()
    private var multicastLock: WifiManager.MulticastLock? = null
    private var nsdManager: NsdManager? = null
    private var nsdDiscoveryListener: NsdManager.DiscoveryListener? = null
    private val nsdResolveQueue = Channel<NsdServiceInfo>(Channel.UNLIMITED)
    private val nsdPeersMap = ConcurrentHashMap<String, DiscoveredPeer>()
    private val rustPeersRef = AtomicReference<List<DiscoveredPeer>>(emptyList())

    @Volatile
    private var runtimeHandle: Long = 0L

    @Volatile
    private var activeWindowIdAtomic: Int = 0

    @Volatile
    private var e2eConfig: E2EConfig? = null

    private var lastSyncedClipHash: String = ""

    private val _selectedTab = MutableStateFlow(MainTab.CONNECT)
    val selectedTab: StateFlow<MainTab> = _selectedTab.asStateFlow()

    private val _connectionPhase = MutableStateFlow<ConnectionPhase>(ConnectionPhase.Idle)
    val connectionPhase: StateFlow<ConnectionPhase> = _connectionPhase.asStateFlow()

    private val _statusMessage = MutableStateFlow("未连接")
    val statusMessage: StateFlow<String> = _statusMessage.asStateFlow()

    private val _linkMode = MutableStateFlow("")
    val linkMode: StateFlow<String> = _linkMode.asStateFlow()

    private val _linkRttMs = MutableStateFlow(0)
    val linkRttMs: StateFlow<Int> = _linkRttMs.asStateFlow()

    private val _linkBadge = MutableStateFlow("")
    val linkBadge: StateFlow<String> = _linkBadge.asStateFlow()

    private val _discoveredPeers = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    val discoveredPeers: StateFlow<List<DiscoveredPeer>> = _discoveredPeers.asStateFlow()

    private val _identity = MutableStateFlow(IdentitySnapshot())
    val identity: StateFlow<IdentitySnapshot> = _identity.asStateFlow()

    private val _deviceBook = MutableStateFlow<List<DeviceBookEntry>>(emptyList())
    val deviceBook: StateFlow<List<DeviceBookEntry>> = _deviceBook.asStateFlow()

    private val _probeResults = MutableStateFlow<Map<String, DeviceProbeResult>>(emptyMap())
    val probeResults: StateFlow<Map<String, DeviceProbeResult>> = _probeResults.asStateFlow()

    private val _remoteApps = MutableStateFlow<List<RemoteAppSummary>>(emptyList())
    val remoteApps: StateFlow<List<RemoteAppSummary>> = _remoteApps.asStateFlow()

    private val _appIcons = MutableStateFlow<Map<String, ImageBitmap>>(emptyMap())
    val appIcons: StateFlow<Map<String, ImageBitmap>> = _appIcons.asStateFlow()

    private val _remoteWindows = MutableStateFlow<List<WindowTopologyItem>>(emptyList())
    val remoteWindows: StateFlow<List<WindowTopologyItem>> = _remoteWindows.asStateFlow()

    private val _selectedWindowId = MutableStateFlow(0)
    val selectedWindowId: StateFlow<Int> = _selectedWindowId.asStateFlow()

    private val _showAppLauncher = MutableStateFlow(true)
    val showAppLauncher: StateFlow<Boolean> = _showAppLauncher.asStateFlow()

    private val _showDebugHud = MutableStateFlow(false)
    val showDebugHud: StateFlow<Boolean> = _showDebugHud.asStateFlow()

    private val _touchMode = MutableStateFlow(TouchMode.DIRECT_TOUCH)
    val touchMode: StateFlow<TouchMode> = _touchMode.asStateFlow()

    private val _manualFullscreen = MutableStateFlow(false)
    val manualFullscreen: StateFlow<Boolean> = _manualFullscreen.asStateFlow()

    private val _videoFitMode = MutableStateFlow(VideoFitMode.FIT)
    val videoFitMode: StateFlow<VideoFitMode> = _videoFitMode.asStateFlow()

    private val _cursorPos = MutableStateFlow(Offset(0.5f, 0.5f))
    val cursorPos: StateFlow<Offset> = _cursorPos.asStateFlow()

    private val _cursorKind = MutableStateFlow("arrow")
    val cursorKind: StateFlow<String> = _cursorKind.asStateFlow()

    private val _stickyModifiers = MutableStateFlow(0)
    val stickyModifiers: StateFlow<Int> = _stickyModifiers.asStateFlow()

    private val _videoTelemetry = MutableStateFlow(VideoTelemetry())
    val videoTelemetry: StateFlow<VideoTelemetry> = _videoTelemetry.asStateFlow()

    private val _notificationBanner = MutableStateFlow<RemoteNotificationBanner?>(null)
    val notificationBanner: StateFlow<RemoteNotificationBanner?> = _notificationBanner.asStateFlow()

    private val _logs = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = _logs.asStateFlow()

    val videoDecoder = VideoDecoderSurface(
        onTelemetry = { telemetry ->
            _videoTelemetry.value = telemetry
            checkAndRunE2EAutoTest(telemetry.decodedFrames)
        },
        onRequestKeyframe = {
            val winId = activeWindowIdAtomic
            if (runtimeHandle != 0L && winId != 0) {
                OpenUUNativeBridge.nativeRequestKeyframe(runtimeHandle, winId)
            }
        }
    )

    private val clipboardListener = ClipboardManager.OnPrimaryClipChangedListener {
        if (!_connectionPhase.value.isConnected) return@OnPrimaryClipChangedListener
        pushLocalClipboardToHost(silent = true)
    }

    init {
        acquireMulticastLock()
        initNativeRuntime()
        runCatching {
            clipboardManager?.addPrimaryClipChangedListener(clipboardListener)
        }.onFailure {
            Log.w(TAG, "Clipboard listener registration restricted by OEM", it)
        }
        startNsdDiscovery()
        startDiscoveryPollingLoop()
    }

    private fun acquireMulticastLock() {
        try {
            val wifi = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            multicastLock = wifi?.createMulticastLock("openuu-mdns-lock")?.apply {
                setReferenceCounted(false)
                acquire()
            }
            appendLog("已启用局域网 mDNS 多播锁")
        } catch (e: Throwable) {
            appendLog("多播锁获取失败: ${e.message}")
        }
    }

    private fun initNativeRuntime() {
        try {
            val tlsRc = OpenUUNativeBridge.nativeInitAndroidContext(appContext)
            if (tlsRc != 0) {
                Log.w(TAG, "nativeInitAndroidContext returned $tlsRc")
                appendLog("Android TLS 校验器初始化异常 (rc=$tlsRc)")
            } else {
                appendLog("Android TLS 校验器已初始化")
            }

            val cfgDir = appContext.filesDir.absolutePath
            val cacheDir = appContext.cacheDir.absolutePath
            OpenUUNativeBridge.nativeSetAppDirs(cfgDir, cacheDir)

            val deviceName = "${Build.MANUFACTURER} ${Build.MODEL}".trim().ifBlank { "OpenUU-Android" }
            runtimeHandle = OpenUUNativeBridge.nativeCreateRuntime(deviceName, this)
            if (runtimeHandle == 0L) {
                appendLog("ERROR: openuu_runtime_create 失败")
                return
            }

            OpenUUNativeBridge.nativeStartDiscovery(runtimeHandle)
            refreshIdentityAndDeviceBook()
            appendLog("OpenUU Core 已就绪 ($deviceName)")
        } catch (e: Throwable) {
            Log.e(TAG, "Failed to init native runtime", e)
            appendLog("初始化内核异常: ${e.message}")
        }
    }

    private fun publishMergedPeers() {
        val merged = LinkedHashMap<String, DiscoveredPeer>()
        for (peer in rustPeersRef.get()) {
            val key = peer.deviceId.ifBlank { "${peer.primaryAddress}:${peer.port}" }
            merged[key] = peer
        }
        for (peer in nsdPeersMap.values) {
            val key = peer.deviceId.ifBlank { "${peer.primaryAddress}:${peer.port}" }
            val existing = merged[key]
            if (existing == null) {
                merged[key] = peer
            } else {
                val combinedAddrs = (existing.addresses + peer.addresses).distinct()
                merged[key] = existing.copy(
                    addresses = combinedAddrs,
                    deviceCode = existing.deviceCode.ifBlank { peer.deviceCode },
                    endpointId = existing.endpointId.ifBlank { peer.endpointId }
                )
            }
        }
        _discoveredPeers.value = merged.values.toList()
    }

    private fun startNsdDiscovery() {
        viewModelScope.launch(Dispatchers.IO) {
            for (service in nsdResolveQueue) {
                resolveNsdServiceSequential(service)
            }
        }
        runCatching {
            val mgr = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return
            nsdManager = mgr
            val listener = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(regType: String) {
                    Log.i(TAG, "NSD discovery started: $regType")
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    if (serviceInfo.serviceType.contains("_openuu._udp")) {
                        nsdResolveQueue.trySend(serviceInfo)
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                    if (nsdPeersMap.remove(serviceInfo.serviceName) != null) {
                        publishMergedPeers()
                    }
                }

                override fun onDiscoveryStopped(serviceType: String) {
                    Log.i(TAG, "NSD discovery stopped: $serviceType")
                }

                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD startDiscoveryFailed: $errorCode")
                    runCatching { mgr.stopServiceDiscovery(this) }
                }

                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "NSD stopDiscoveryFailed: $errorCode")
                }
            }
            nsdDiscoveryListener = listener
            mgr.discoverServices("_openuu._udp.", NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            Log.w(TAG, "NSD discovery init failed", it)
        }
    }

    @Suppress("DEPRECATION")
    private suspend fun resolveNsdServiceSequential(serviceInfo: NsdServiceInfo) {
        val mgr = nsdManager ?: return
        val deferred = CompletableDeferred<NsdServiceInfo?>()
        runCatching {
            mgr.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    deferred.complete(null)
                }

                override fun onServiceResolved(info: NsdServiceInfo) {
                    deferred.complete(info)
                }
            })
        }.onFailure {
            deferred.complete(null)
        }
        val resolved = withTimeoutOrNull(4000L) { deferred.await() } ?: return
        runCatching {
            val hostAddr = resolved.host?.hostAddress?.substringBefore('%')?.trim().orEmpty()
            val port = resolved.port
            if (hostAddr.isEmpty() || port <= 0) return
            val attrs = resolved.attributes
            fun txt(key: String): String =
                attrs[key]?.let { String(it, Charsets.UTF_8).trim() }.orEmpty()

            val deviceId = txt("id").ifBlank { resolved.serviceName }
            val selfId = _identity.value.deviceId
            if (selfId.isNotBlank() && deviceId == selfId) return

            val peer = DiscoveredPeer(
                deviceId = deviceId,
                deviceName = txt("name").ifBlank { resolved.serviceName },
                os = txt("os").ifBlank { "macos" },
                addresses = listOf(hostAddr),
                port = port,
                protocolVersion = txt("v").toIntOrNull() ?: 1,
                deviceCode = txt("code"),
                endpointId = txt("pk")
            )
            nsdPeersMap[resolved.serviceName] = peer
            publishMergedPeers()
        }
    }

    private fun startDiscoveryPollingLoop() {
        viewModelScope.launch(Dispatchers.IO) {
            while (true) {
                if (runtimeHandle != 0L) {
                    val json = OpenUUNativeBridge.nativeListPeersJson(runtimeHandle)
                    rustPeersRef.set(DiscoveredPeer.parseList(json))
                    publishMergedPeers()
                }
                delay(2500L)
            }
        }
    }

    fun selectTab(tab: MainTab) {
        _selectedTab.value = tab
    }

    fun refreshIdentityAndDeviceBook() {
        if (runtimeHandle == 0L) return
        val snap = IdentitySnapshot.parse(OpenUUNativeBridge.nativeGetIdentityJson(runtimeHandle))
        _identity.value = snap
        _deviceBook.value = deviceBookRepo.syncFromTrustedPeers(snap.trustedPeers)
    }

    fun connectSmart(target: String, defaultPort: Int = OpenUUConstants.DEFAULT_PORT, pin: String = "") {
        val cleanTarget = target.trim()
        if (cleanTarget.isEmpty() || runtimeHandle == 0L) return
        _connectionPhase.value = ConnectionPhase.Connecting("正在连接 $cleanTarget...")
        _statusMessage.value = "正在连接 $cleanTarget..."
        _linkBadge.value = "握手中..."
        appendLog("发起智能连接: $cleanTarget")
        val rc = OpenUUNativeBridge.nativeConnectSmart(runtimeHandle, cleanTarget, defaultPort, pin.trim())
        if (rc != 0) {
            _connectionPhase.value = ConnectionPhase.Error("连接参数无效 (rc=$rc)")
            appendLog("connectSmart 返回错误码 $rc")
        }
    }

    fun connectDirect(hostIp: String, port: Int, pin: String) {
        val cleanIp = hostIp.trim()
        if (cleanIp.isEmpty() || runtimeHandle == 0L) return
        _connectionPhase.value = ConnectionPhase.Connecting("正在连接 $cleanIp:$port...")
        _statusMessage.value = "正在连接 $cleanIp:$port..."
        _linkBadge.value = "直连握手中..."
        appendLog("发起局域网直连: $cleanIp:$port")
        val rc = OpenUUNativeBridge.nativeConnectClient(runtimeHandle, cleanIp, port, pin.trim())
        if (rc != 0) {
            _connectionPhase.value = ConnectionPhase.Error("直连参数无效 (rc=$rc)")
        }
    }

    fun disconnect() {
        if (runtimeHandle != 0L) {
            OpenUUNativeBridge.nativeDisconnect(runtimeHandle)
        }
        resetSessionState()
        _connectionPhase.value = ConnectionPhase.Idle
        _statusMessage.value = "已断开连接"
        appendLog("已主动断开连接")
    }

    private fun resetSessionState() {
        activeWindowIdAtomic = 0
        _selectedWindowId.value = 0
        _remoteApps.value = emptyList()
        _remoteWindows.value = emptyList()
        _showAppLauncher.value = true
        _manualFullscreen.value = false
        _linkMode.value = ""
        _linkRttMs.value = 0
        _linkBadge.value = ""
        _videoTelemetry.value = VideoTelemetry()
        videoDecoder.resetStream()
    }

    fun refreshRemoteApps() {
        if (runtimeHandle == 0L) return
        OpenUUNativeBridge.nativeRequestAppList(runtimeHandle)
    }

    fun openRemoteApp(bundleId: String, appName: String = bundleId) {
        if (runtimeHandle == 0L) return
        appendLog("打开远程应用: $appName ($bundleId)")
        _showAppLauncher.value = false
        videoDecoder.resetStream()
        activeWindowIdAtomic = 0
        _selectedWindowId.value = 0
        OpenUUNativeBridge.nativeStartRemoteSession(runtimeHandle, bundleId, 0)
    }

    fun openFullDesktop() {
        openRemoteApp(OpenUUConstants.FULL_DESKTOP_BUNDLE_ID, "整台桌面")
    }

    fun selectRemoteWindow(windowId: Int) {
        if (windowId == activeWindowIdAtomic && !_showAppLauncher.value) return
        activeWindowIdAtomic = windowId
        _selectedWindowId.value = windowId
        _showAppLauncher.value = false
        videoDecoder.resetStream()
        if (runtimeHandle != 0L && windowId != 0) {
            OpenUUNativeBridge.nativeRequestKeyframe(runtimeHandle, windowId)
        }
    }

    fun stopRemoteWindow(windowId: Int) {
        if (runtimeHandle == 0L) return
        OpenUUNativeBridge.nativeStopRemoteSession(runtimeHandle, windowId)
        val remaining = _remoteWindows.value.filterNot { it.windowId == windowId }
        _remoteWindows.value = remaining
        if (activeWindowIdAtomic == windowId) {
            val next = remaining.firstOrNull()?.windowId ?: 0
            activeWindowIdAtomic = next
            _selectedWindowId.value = next
            if (next == 0) {
                _showAppLauncher.value = true
                videoDecoder.resetStream()
            } else {
                OpenUUNativeBridge.nativeRequestKeyframe(runtimeHandle, next)
            }
        }
    }

    fun setShowAppLauncher(show: Boolean) {
        _showAppLauncher.value = show
    }

    fun toggleDebugHud() {
        _showDebugHud.value = !_showDebugHud.value
    }

    fun setTouchMode(mode: TouchMode) {
        _touchMode.value = mode
    }

    fun setManualFullscreen(enabled: Boolean) {
        _manualFullscreen.value = enabled
    }

    fun toggleManualFullscreen() {
        _manualFullscreen.value = !_manualFullscreen.value
    }

    fun setVideoFitMode(mode: VideoFitMode) {
        _videoFitMode.value = mode
    }

    fun toggleVideoFitMode() {
        _videoFitMode.value = if (_videoFitMode.value == VideoFitMode.FIT) {
            VideoFitMode.FILL
        } else {
            VideoFitMode.FIT
        }
    }

    fun updateCursorPos(normalized: Offset) {
        _cursorPos.value = Offset(
            normalized.x.coerceIn(0f, 1f),
            normalized.y.coerceIn(0f, 1f)
        )
    }

    fun toggleStickyModifier(bit: Int) {
        _stickyModifiers.value = _stickyModifiers.value xor bit
    }

    fun clearStickyModifiers() {
        _stickyModifiers.value = 0
    }

    fun dismissNotificationBanner() {
        _notificationBanner.value = null
    }

    fun attachVideoSurface(surface: Surface?) {
        videoDecoder.attachSurface(surface)
    }

    fun currentLogicalSize(): Pair<Float, Float> {
        val winId = activeWindowIdAtomic
        val topo = _remoteWindows.value.firstOrNull { it.windowId == winId }
        if (topo != null && topo.width > 0f && topo.height > 0f) {
            return topo.width to topo.height
        }
        val tel = _videoTelemetry.value
        val w = if (tel.width > 0) tel.width / 2f else 960f
        val h = if (tel.height > 0) tel.height / 2f else 600f
        return w to h
    }

    fun sendMouseNormalized(
        nx: Float,
        ny: Float,
        eventType: Int,
        button: Int,
        clickCount: Int
    ) {
        val (lw, lh) = currentLogicalSize()
        val x = nx.coerceIn(0f, 1f) * lw
        val y = ny.coerceIn(0f, 1f) * lh
        sendMouseLogical(x, y, eventType, button, clickCount, _stickyModifiers.value)
    }

    fun sendMouseLogical(
        x: Float,
        y: Float,
        eventType: Int,
        button: Int,
        clickCount: Int,
        modifiers: Int = _stickyModifiers.value
    ) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0) return
        OpenUUNativeBridge.nativeSendMouseEvent(
            runtimeHandle,
            winId,
            x,
            y,
            eventType,
            button,
            clickCount,
            modifiers
        )
    }

    fun sendScrollNormalized(nx: Float, ny: Float, deltaX: Float, deltaY: Float) {
        val (lw, lh) = currentLogicalSize()
        val x = nx.coerceIn(0f, 1f) * lw
        val y = ny.coerceIn(0f, 1f) * lh
        sendScrollLogical(x, y, deltaX, deltaY, true, _stickyModifiers.value)
    }

    fun sendScrollLogical(
        x: Float,
        y: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean = true,
        modifiers: Int = _stickyModifiers.value
    ) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0) return
        OpenUUNativeBridge.nativeSendScrollEvent(
            runtimeHandle,
            winId,
            x,
            y,
            deltaX,
            deltaY,
            isContinuous,
            modifiers
        )
    }

    fun sendKeyTap(keyCode: Int, explicitModifiers: Int? = null) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0) return
        val mods = explicitModifiers ?: _stickyModifiers.value
        OpenUUNativeBridge.nativeSendKeyEvent(runtimeHandle, winId, keyCode, true, false, mods)
        OpenUUNativeBridge.nativeSendKeyEvent(runtimeHandle, winId, keyCode, false, false, mods)
        if (explicitModifiers == null && _stickyModifiers.value != 0) {
            _stickyModifiers.value = 0
        }
    }

    fun sendTextCommit(text: String) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0 || text.isEmpty()) return
        OpenUUNativeBridge.nativeSendTextCommit(runtimeHandle, winId, text)
    }

    fun requestKeyframeNow() {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0) return
        OpenUUNativeBridge.nativeRequestKeyframe(runtimeHandle, winId)
    }

    fun resizeActiveWindow(width: Float, height: Float) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0 || width <= 0f || height <= 0f) return
        val rc = OpenUUNativeBridge.nativeSendResizeWindow(runtimeHandle, winId, width, height)
        if (rc == 0) {
            appendLog("已请求调整远程窗口尺寸: ${width.toInt()}×${height.toInt()}")
        } else {
            appendLog("调整远程窗口尺寸失败 (rc=$rc)")
        }
    }

    fun readLocalClipboardText(): String {
        return runCatching {
            val clip = clipboardManager?.primaryClip ?: return ""
            if (clip.itemCount <= 0) return ""
            clip.getItemAt(0)?.coerceToText(appContext)?.toString().orEmpty()
        }.getOrDefault("")
    }

    fun copyToLocalClipboard(label: String, text: String) {
        if (text.isEmpty()) return
        runCatching {
            clipboardManager?.setPrimaryClip(ClipData.newPlainText(label, text))
            appendLog("已复制 $label 到剪贴板")
        }
    }

    fun sendClipboardTextToHost(text: String) {
        if (runtimeHandle == 0L || text.isEmpty()) return
        val hash = sha256Hex(text.toByteArray(Charsets.UTF_8))
        lastSyncedClipHash = hash
        OpenUUNativeBridge.nativeSendClipboardText(runtimeHandle, hash, text)
        appendLog("已同步剪贴板文本至 Mac (${text.length} 字)")
    }

    fun pushLocalClipboardToHost(silent: Boolean = false) {
        if (runtimeHandle == 0L) return
        val text = runCatching {
            val clip = clipboardManager?.primaryClip ?: return
            if (clip.itemCount <= 0) return
            clip.getItemAt(0)?.coerceToText(appContext)?.toString().orEmpty()
        }.getOrDefault("")
        if (text.isEmpty()) return
        val hash = sha256Hex(text.toByteArray(Charsets.UTF_8))
        if (silent && hash == lastSyncedClipHash) return
        lastSyncedClipHash = hash
        OpenUUNativeBridge.nativeSendClipboardText(runtimeHandle, hash, text)
        if (!silent) {
            appendLog("已推送本机剪贴板至 Mac (${text.length} 字)")
        }
    }

    fun sendPickedFileUri(uri: Uri) {
        val winId = activeWindowIdAtomic
        if (runtimeHandle == 0L || winId == 0) {
            appendLog("请先打开一个远程窗口再发送文件")
            return
        }
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val filename = resolveDisplayName(uri) ?: "openuu-upload-${System.currentTimeMillis()}"
                val uploadDir = File(appContext.cacheDir, "uploads").apply { mkdirs() }
                val destFile = File(uploadDir, filename)
                appContext.contentResolver.openInputStream(uri)?.use { input ->
                    FileOutputStream(destFile).use { output ->
                        input.copyTo(output)
                    }
                } ?: run {
                    appendLog("无法读取所选文件")
                    return@launch
                }
                val (lw, lh) = currentLogicalSize()
                val blobId = UUID.randomUUID().toString()
                val rc = OpenUUNativeBridge.nativeSendFileBlob(
                    runtimeHandle,
                    winId,
                    lw / 2f,
                    lh / 2f,
                    blobId,
                    filename,
                    destFile.absolutePath
                )
                appendLog(if (rc == 0) "已发送文件至远程窗口: $filename" else "发送文件失败 (rc=$rc)")
            } catch (e: Throwable) {
                appendLog("文件发送异常: ${e.message}")
            }
        }
    }

    private fun resolveDisplayName(uri: Uri): String? {
        appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        return uri.lastPathSegment?.substringAfterLast('/')
    }

    // ---- Device Book & WAN Settings ----

    fun upsertDeviceBookEntry(entry: DeviceBookEntry) {
        _deviceBook.value = deviceBookRepo.upsert(entry)
        probeDeviceBookOnline()
    }

    fun deleteDeviceBookEntry(id: String) {
        _deviceBook.value = deviceBookRepo.delete(id)
    }

    fun toggleDeviceFavorite(id: String) {
        _deviceBook.value = deviceBookRepo.toggleFavorite(id)
    }

    fun probeDeviceBookOnline() {
        if (runtimeHandle == 0L) return
        val devices = _deviceBook.value
        if (devices.isEmpty()) return
        val arr = JSONArray()
        devices.forEach { d ->
            arr.put(JSONObject().apply {
                put("id", d.id)
                put("target", d.target)
            })
        }
        OpenUUNativeBridge.nativeProbeDevicesOnline(runtimeHandle, arr.toString())
    }

    fun saveWanConfig(config: WanConfig) {
        if (runtimeHandle == 0L) return
        val rc = OpenUUNativeBridge.nativeSetWanConfigJson(runtimeHandle, config.toJson())
        if (rc == 0) {
            refreshIdentityAndDeviceBook()
            appendLog("WAN 配置已保存 (${config.coordUrl})")
        } else {
            appendLog("保存 WAN 配置失败 (rc=$rc)")
        }
    }

    fun removeTrustedPeer(deviceId: String) {
        if (runtimeHandle == 0L) return
        val rc = OpenUUNativeBridge.nativeRemoveTrustedPeer(runtimeHandle, deviceId)
        if (rc == 0) {
            refreshIdentityAndDeviceBook()
            appendLog("已移除信任设备: $deviceId")
        }
    }

    fun clearLogs() {
        _logs.value = emptyList()
    }

    // ---- E2E Automated Self-Test Intent Hook ----

    fun handleE2EIntent(target: String, pin: String, appBundleId: String, autoTest: Boolean) {
        val cleanTarget = target.trim()
        if (cleanTarget.isEmpty()) return
        val resolvedApp = appBundleId.trim().ifEmpty { "com.tencent.xinWeChat" }
        if (_connectionPhase.value.isConnected) {
            disconnect()
        }
        e2eConfig = E2EConfig(
            target = cleanTarget,
            pin = pin.trim(),
            appBundleId = resolvedApp,
            autoTest = autoTest
        )
        if (autoTest) {
            _showDebugHud.value = true
        }
        Log.i(E2E_TAG, "CONNECTING target=$cleanTarget app=$resolvedApp autotest=$autoTest")
        appendLog("[E2E] CONNECTING target=$cleanTarget")
        _selectedTab.value = MainTab.REMOTE
        connectSmart(cleanTarget, OpenUUConstants.DEFAULT_PORT, pin.trim())
    }

    private fun checkAndRunE2EAutoTest(decodedFrames: Long) {
        val cfg = e2eConfig ?: return
        if (!cfg.autoTest || cfg.autoTestSent || decodedFrames < 5L) return
        synchronized(cfg) {
            if (cfg.autoTestSent) return
            cfg.autoTestSent = true
        }
        viewModelScope.launch(Dispatchers.IO) {
            val winId = activeWindowIdAtomic
            Log.i(E2E_TAG, "DISPATCHING_AUTOTEST winId=$winId decoded_frames=$decodedFrames")
            // 1. Mouse left-click at (480, 300)
            sendMouseLogical(480f, 300f, 0, 0, 0, 0)
            delay(30)
            sendMouseLogical(480f, 300f, 1, 0, 1, 0)
            delay(30)
            sendMouseLogical(480f, 300f, 2, 0, 1, 0)
            delay(40)
            // 1b. Mouse drag sequence (event_type=3)
            sendMouseLogical(420f, 260f, 0, 0, 0, 0)
            delay(20)
            sendMouseLogical(420f, 260f, 1, 0, 1, 0)
            delay(20)
            sendMouseLogical(470f, 285f, 3, 0, 1, 0)
            delay(20)
            sendMouseLogical(520f, 310f, 3, 0, 1, 0)
            delay(20)
            sendMouseLogical(520f, 310f, 2, 0, 1, 0)
            delay(40)
            // 1c. Mouse right-click (button=1)
            sendMouseLogical(500f, 320f, 0, 1, 0, 0)
            delay(20)
            sendMouseLogical(500f, 320f, 1, 1, 1, 0)
            delay(20)
            sendMouseLogical(500f, 320f, 2, 1, 1, 0)
            delay(50)
            // 2. Scroll at (480, 300), dy=-120
            sendScrollLogical(480f, 300f, 0f, -120f, true, 0)
            delay(50)
            // 3. Text commit
            sendTextCommit("你好，OpenUU 安卓端！")
            delay(50)
            // 4. Cmd+C (keyCode=8, modifiers=8)
            sendKeyTap(MacKeyCodes.C, MacModifiers.COMMAND)
            delay(50)
            // 5. Clipboard text
            sendClipboardTextToHost("Hello from Android E2E")
            Log.i(E2E_TAG, "E2E_ALL_SENT decoded_frames=$decodedFrames")
            appendLog("[E2E] E2E_ALL_SENT decoded_frames=$decodedFrames")
        }
    }

    // ---- NativeCallbackListener ----

    override fun onControl(json: String) {
        val evt = ControlEvent.parse(json)
        viewModelScope.launch(Dispatchers.Main.immediate) {
            when (evt) {
                is ControlEvent.LinkQuality -> {
                    _linkMode.value = evt.linkMode
                    _linkRttMs.value = evt.rttMs
                    val label = when (evt.linkMode) {
                        "lan" -> "LAN 直连"
                        "wan_direct" -> "P2P 直连"
                        "wan_relay" -> "中继"
                        else -> evt.linkMode
                    }
                    _linkBadge.value = if (evt.rttMs > 0) "$label · ${evt.rttMs}ms" else label
                }
                is ControlEvent.ListAppsResp -> {
                    _remoteApps.value = evt.apps
                    decodeAppIconsAsync(evt.apps)
                    Log.i(E2E_TAG, "list_apps_resp count=${evt.apps.size}")
                    val cfg = e2eConfig
                    if (cfg != null && !cfg.openedApp) {
                        cfg.openedApp = true
                        Log.i(E2E_TAG, "LIST_APPS_RECEIVED count=${evt.apps.size} opening=${cfg.appBundleId}")
                        _selectedTab.value = MainTab.REMOTE
                        openRemoteApp(cfg.appBundleId, cfg.appBundleId)
                    }
                }
                is ControlEvent.WindowTopology -> {
                    _remoteWindows.value = evt.windows
                    Log.i(
                        E2E_TAG,
                        "window_topology ids=${evt.windows.joinToString(",") { it.windowId.toString() }}"
                    )
                    if (evt.windows.isNotEmpty()) {
                        val cur = activeWindowIdAtomic
                        val stillPresent = evt.windows.any { it.windowId == cur }
                        if (cur == 0 || !stillPresent) {
                            val chosen = evt.windows.firstOrNull { it.kind == 0 } ?: evt.windows.first()
                            activeWindowIdAtomic = chosen.windowId
                            _selectedWindowId.value = chosen.windowId
                            _showAppLauncher.value = false
                            if (runtimeHandle != 0L) {
                                OpenUUNativeBridge.nativeRequestKeyframe(runtimeHandle, chosen.windowId)
                            }
                        }
                    }
                }
                is ControlEvent.Cursor -> {
                    _cursorKind.value = evt.kind.ifBlank { "arrow" }
                }
                is ControlEvent.ClipboardSync -> {
                    if (evt.clipKind == 0 && evt.text.isNotEmpty() && evt.contentHash != lastSyncedClipHash) {
                        lastSyncedClipHash = evt.contentHash
                        runCatching {
                            clipboardManager?.setPrimaryClip(ClipData.newPlainText("OpenUU", evt.text))
                            appendLog("已接收 Mac 剪贴板文本 (${evt.text.length} 字)")
                        }
                    }
                }
                is ControlEvent.Notification -> {
                    val banner = RemoteNotificationBanner(
                        appBundleId = evt.appBundleId,
                        title = evt.title.ifBlank { evt.appBundleId },
                        subtitle = evt.subtitle,
                        body = evt.body
                    )
                    _notificationBanner.value = banner
                    viewModelScope.launch {
                        delay(4500L)
                        if (_notificationBanner.value?.id == banner.id) {
                            _notificationBanner.value = null
                        }
                    }
                }
                is ControlEvent.BadgeUpdate -> {
                    appendLog("角标更新: ${evt.appBundleId} -> ${evt.badgeText}")
                }
                is ControlEvent.FileDrop -> {
                    appendLog("收到远程文件: ${evt.localPath}")
                }
                is ControlEvent.Unknown -> {}
            }
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
    ) {
        var active = activeWindowIdAtomic
        if (active == 0 && windowId != 0) {
            active = windowId
            activeWindowIdAtomic = windowId
            viewModelScope.launch(Dispatchers.Main.immediate) {
                _selectedWindowId.value = windowId
                _showAppLauncher.value = false
            }
        }
        if (windowId == active) {
            videoDecoder.submitFrame(codec, flags, timestampUs, width, height, data)
        }
    }

    override fun onStatus(msg: String) {
        Log.i(TAG, "status: $msg")
        viewModelScope.launch(Dispatchers.Main.immediate) {
            _statusMessage.value = msg
            appendLog(msg)
            when {
                msg.startsWith("connected to host:") -> {
                    val hostName = msg.removePrefix("connected to host:")
                        .substringBefore(" (")
                        .trim()
                        .ifEmpty { "Mac" }
                    _connectionPhase.value = ConnectionPhase.Connected(hostName)
                    refreshIdentityAndDeviceBook()
                    refreshRemoteApps()
                    _selectedTab.value = MainTab.REMOTE
                    if (e2eConfig != null) {
                        Log.i(E2E_TAG, "CONNECTED host=$hostName")
                    }
                }
                msg.startsWith("connect failed:") -> {
                    val reason = msg.removePrefix("connect failed:").trim()
                    resetSessionState()
                    _connectionPhase.value = ConnectionPhase.Error(reason)
                    if (e2eConfig != null) {
                        Log.e(E2E_TAG, "CONNECT_FAILED reason=$reason")
                    }
                }
                msg.contains("disconnected") -> {
                    resetSessionState()
                    _connectionPhase.value = ConnectionPhase.Idle
                }
            }
        }
    }

    override fun onProbeResult(json: String) {
        val parsed = DeviceProbeResult.parseList(json)
        viewModelScope.launch(Dispatchers.Main.immediate) {
            val merged = _probeResults.value.toMutableMap()
            parsed.forEach { merged[it.id] = it }
            _probeResults.value = merged
        }
    }

    private fun decodeAppIconsAsync(apps: List<RemoteAppSummary>) {
        viewModelScope.launch(Dispatchers.Default) {
            val map = _appIcons.value.toMutableMap()
            var changed = false
            for (app in apps) {
                if (app.iconPngB64.isBlank() || map.containsKey(app.bundleId)) continue
                try {
                    val raw = Base64.decode(app.iconPngB64, Base64.DEFAULT)
                    val bmp = BitmapFactory.decodeByteArray(raw, 0, raw.size)
                    if (bmp != null) {
                        map[app.bundleId] = bmp.asImageBitmap()
                        changed = true
                    }
                } catch (_: Throwable) {
                }
            }
            if (changed) {
                _appIcons.value = map
            }
        }
    }

    private fun appendLog(line: String) {
        val ts = SimpleDateFormat("HH:mm:ss", Locale.getDefault()).format(Date())
        val entry = "[$ts] $line"
        val updated = (_logs.value + entry).takeLast(MAX_LOGS)
        _logs.value = updated
    }

    private fun sha256Hex(bytes: ByteArray): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(bytes)
        return digest.joinToString("") { "%02x".format(it) }
    }

    override fun onCleared() {
        super.onCleared()
        runCatching {
            clipboardManager?.removePrimaryClipChangedListener(clipboardListener)
        }
        runCatching {
            nsdDiscoveryListener?.let { nsdManager?.stopServiceDiscovery(it) }
            nsdDiscoveryListener = null
            nsdResolveQueue.close()
        }
        videoDecoder.release()
        if (runtimeHandle != 0L) {
            val handle = runtimeHandle
            runtimeHandle = 0L
            OpenUUNativeBridge.nativeDestroyRuntime(handle)
        }
        runCatching {
            if (multicastLock?.isHeld == true) {
                multicastLock?.release()
            }
        }
    }
}

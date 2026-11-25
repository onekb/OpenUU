package ren.onekb.openuu

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.RemoteInput
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.TimeUnit

enum class AndroidHostMode(val prefValue: String, val label: String) {
    BASIC_FULLSCREEN("basic", "基础整屏"),
    ENHANCED_MULTI_WINDOW("enhanced", "多窗口增强");

    companion object {
        fun fromPref(raw: String?): AndroidHostMode =
            if (raw == ENHANCED_MULTI_WINDOW.prefValue) ENHANCED_MULTI_WINDOW else BASIC_FULLSCREEN
    }
}

data class EnhancedEngineState(
    val isActive: Boolean = false,
    val uid: Int = -1,
    val pid: Int = -1,
    val pairingPort: Int = 0,
    val connectPort: Int = 0,
    val isListeningMdns: Boolean = false,
    val isBusy: Boolean = false,
    val hasRootCandidate: Boolean = false,
    val statusMessage: String = "未激活",
    val lastError: String = ""
) {
    val privilegeBadge: String
        get() = when {
            !isActive -> "未激活"
            uid == 0 -> "Root 已激活"
            else -> "无线调试已激活"
        }
}

/**
 * Built-in rootless / Shizuku-free privileged engine activator:
 * 1. Android 11+ Wireless Debugging (`_adb-tls-pairing._tcp` + `_adb-tls-connect._tcp` via `libadb` in `openuu-core`)
 *    with notification-shade inline `RemoteInput` so the user enters the 6-digit pairing code directly on top of Settings
 * 2. Local TCP ADB (`127.0.0.1:5555` or custom port)
 * 3. Root (`su -c`) one-tap activation when available
 */
object WirelessAdbActivator {
    private const val TAG = "OpenUUAdbAct"
    private const val PREFS_NAME = "openuu_host_prefs"
    private const val KEY_PRIV_PORT = "priv_daemon_port"
    private const val KEY_PRIV_TOKEN = "priv_daemon_token"
    private const val KEY_LAST_CONNECT_PORT = "last_adb_connect_port"
    private const val KEY_HOST_MODE = "android_host_mode"

    private const val PAIRING_CHANNEL_ID = "openuu_wireless_adb_pairing"
    private const val PAIRING_NOTIF_ID = 39488
    const val ACTION_SUBMIT_PAIRING_CODE = "ren.onekb.openuu.action.SUBMIT_ADB_PAIRING_CODE"
    const val KEY_REMOTE_INPUT_CODE = "openuu_adb_pairing_code"

    private const val SERVICE_ADB_TLS_PAIRING = "_adb-tls-pairing._tcp."
    private const val SERVICE_ADB_TLS_CONNECT = "_adb-tls-connect._tcp."

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _state = MutableStateFlow(EnhancedEngineState(hasRootCandidate = detectSuBinary()))
    val state: StateFlow<EnhancedEngineState> = _state.asStateFlow()

    private var nsdManager: NsdManager? = null
    private var pairingDiscoveryListener: NsdManager.DiscoveryListener? = null
    private var connectDiscoveryListener: NsdManager.DiscoveryListener? = null

    fun loadPreferredMode(context: Context): AndroidHostMode {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return AndroidHostMode.fromPref(prefs.getString(KEY_HOST_MODE, null))
    }

    fun savePreferredMode(context: Context, mode: AndroidHostMode) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_HOST_MODE, mode.prefValue)
            .apply()
    }

    fun ensurePrivCredentials(context: Context): Pair<Int, String> {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val port = prefs.getInt(KEY_PRIV_PORT, PrivDaemonClient.DEFAULT_PRIV_PORT)
            .takeIf { it in 1024..65530 } ?: PrivDaemonClient.DEFAULT_PRIV_PORT
        var token = prefs.getString(KEY_PRIV_TOKEN, "")?.trim().orEmpty()
        if (token.length < 32) {
            val bytes = ByteArray(32)
            SecureRandom().nextBytes(bytes)
            token = bytes.joinToString("") { "%02x".format(it) }
            prefs.edit()
                .putInt(KEY_PRIV_PORT, port)
                .putString(KEY_PRIV_TOKEN, token)
                .apply()
        }
        return port to token
    }

    fun refreshStatusAsync(context: Context, trySilentReconnect: Boolean = false) {
        val appCtx = context.applicationContext
        scope.launch {
            val (privPort, privToken) = ensurePrivCredentials(appCtx)
            val probe = PrivDaemonClient.probeRunning(privPort, privToken)
            if (probe.isCurrentVersion) {
                _state.update {
                    it.copy(
                        isActive = true,
                        uid = probe.uid,
                        pid = probe.pid,
                        isBusy = false,
                        hasRootCandidate = detectSuBinary(),
                        statusMessage = if (probe.uid == 0) "Root 增强引擎运行中" else "多窗口增强引擎运行中 (UID ${probe.uid})",
                        lastError = ""
                    )
                }
                return@launch
            }
            if (probe.alive) {
                Log.i(TAG, "Shutting down outdated OpenUUPrivServer version=${probe.version}")
                PrivDaemonClient.shutdownDaemon(privPort, privToken)
                delay(180L)
            }

            _state.update {
                it.copy(
                    isActive = false,
                    uid = -1,
                    pid = -1,
                    hasRootCandidate = detectSuBinary(),
                    statusMessage = "未激活（重启手机前仅需激活一次）"
                )
            }

            if (trySilentReconnect) {
                val candidatePort = _state.value.connectPort.takeIf { it > 0 }
                    ?: appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        .getInt(KEY_LAST_CONNECT_PORT, 0)
                if (candidatePort > 0) {
                    spawnPrivViaAdbConnectPort(appCtx, candidatePort, silent = true)
                }
            }
        }
    }

    fun startWirelessDiscoveryAndNotification(context: Context) {
        val appCtx = context.applicationContext
        ensureNativeDirsInitialized(appCtx)
        ensurePairingNotificationChannel(appCtx)
        stopWirelessDiscovery()

        val mgr = appCtx.getSystemService(Context.NSD_SERVICE) as? NsdManager
        nsdManager = mgr
        if (mgr != null) {
            val pairListener = createMdnsListener(
                serviceLabel = "pairing",
                onPortFound = { port ->
                    _state.update {
                        it.copy(
                            pairingPort = port,
                            statusMessage = "已发现无线调试配对端口 $port，请在通知栏或下方输入 6 位配对码"
                        )
                    }
                    postOrUpdatePairingNotification(
                        appCtx,
                        title = "已发现配对端口 $port",
                        body = "请点下方「输入 6 位配对码」直接填入屏幕上的 6 位数字（无需切出设置页面）"
                    )
                }
            )
            val connListener = createMdnsListener(
                serviceLabel = "connect",
                onPortFound = { port ->
                    appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        .edit()
                        .putInt(KEY_LAST_CONNECT_PORT, port)
                        .apply()
                    _state.update { it.copy(connectPort = port) }
                    // If previously paired, auto-spawn immediately without needing a pairing code!
                    if (!_state.value.isActive && !_state.value.isBusy) {
                        scope.launch {
                            spawnPrivViaAdbConnectPort(appCtx, port, silent = true)
                        }
                    }
                }
            )
            pairingDiscoveryListener = pairListener
            connectDiscoveryListener = connListener
            runCatching { mgr.discoverServices(SERVICE_ADB_TLS_PAIRING, NsdManager.PROTOCOL_DNS_SD, pairListener) }
            runCatching { mgr.discoverServices(SERVICE_ADB_TLS_CONNECT, NsdManager.PROTOCOL_DNS_SD, connListener) }
            _state.update { it.copy(isListeningMdns = true, lastError = "") }
        }

        postOrUpdatePairingNotification(
            appCtx,
            title = "正在等待无线调试配对码",
            body = "进入「开发者选项 -> 无线调试 -> 使用配对码配对设备」，下拉通知栏直接输入 6 位配对码"
        )
    }

    fun stopWirelessDiscovery() {
        val mgr = nsdManager
        pairingDiscoveryListener?.let { l -> runCatching { mgr?.stopServiceDiscovery(l) } }
        connectDiscoveryListener?.let { l -> runCatching { mgr?.stopServiceDiscovery(l) } }
        pairingDiscoveryListener = null
        connectDiscoveryListener = null
        _state.update { it.copy(isListeningMdns = false) }
    }

    fun openDeveloperSettings(context: Context) {
        val intents = listOf(
            Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS),
            Intent(Settings.ACTION_SETTINGS)
        )
        for (intent in intents) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (runCatching { context.startActivity(intent) }.isSuccess) {
                return
            }
        }
    }

    fun pairAndActivateAsync(
        context: Context,
        pairingCode: String,
        manualPairingPort: Int = 0,
        manualConnectPort: Int = 0,
        fromNotification: Boolean = false
    ) {
        val appCtx = context.applicationContext
        val cleanCode = pairingCode.filter { it.isDigit() }
        if (cleanCode.length < 6) {
            val msg = "请输入完整的 6 位数字配对码"
            _state.update { it.copy(lastError = msg) }
            if (fromNotification) {
                postOrUpdatePairingNotification(appCtx, "配对码格式有误", msg)
            }
            return
        }

        scope.launch {
            ensureNativeDirsInitialized(appCtx)
            val pairPort = manualPairingPort.takeIf { it in 1..65535 } ?: _state.value.pairingPort
            if (pairPort <= 0) {
                val msg = "尚未检测到无线调试配对端口，请保持「使用配对码配对设备」弹窗处于打开状态"
                _state.update { it.copy(isBusy = false, lastError = msg) }
                if (fromNotification) {
                    postOrUpdatePairingNotification(appCtx, "未检测到配对端口", msg)
                }
                return@launch
            }

            _state.update {
                it.copy(
                    isBusy = true,
                    lastError = "",
                    statusMessage = "正在与 127.0.0.1:$pairPort 进行无线调试配对..."
                )
            }
            if (fromNotification) {
                postOrUpdatePairingNotification(appCtx, "正在配对无线调试...", "端口 $pairPort · 正在交换本机安全密钥")
            }

            val pairRaw = OpenUUNativeBridge.nativeAdbPairJson("127.0.0.1", pairPort, cleanCode)
            val pairObj = runCatching { JSONObject(pairRaw) }.getOrNull()
            val pairOk = pairObj?.optBoolean("ok", false) == true
            if (!pairOk) {
                val err = pairObj?.optString("error").orEmpty().ifBlank { "无线调试配对失败" }
                _state.update { it.copy(isBusy = false, lastError = err, statusMessage = "配对失败") }
                if (fromNotification) {
                    postOrUpdatePairingNotification(appCtx, "无线调试配对失败", err)
                }
                return@launch
            }

            _state.update { it.copy(statusMessage = "配对成功！正在启动多窗口增强引擎...") }

            // Wait briefly if `_adb-tls-connect._tcp` mDNS port is still resolving
            var connPort = manualConnectPort.takeIf { it in 1..65535 } ?: _state.value.connectPort
            if (connPort <= 0) {
                repeat(12) {
                    delay(200L)
                    connPort = _state.value.connectPort
                    if (connPort > 0) return@repeat
                }
            }
            if (connPort <= 0) {
                connPort = appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .getInt(KEY_LAST_CONNECT_PORT, 5555)
            }

            val ok = spawnPrivViaAdbConnectPort(appCtx, connPort, silent = false)
            if (ok) {
                savePreferredMode(appCtx, AndroidHostMode.ENHANCED_MULTI_WINDOW)
                stopWirelessDiscovery()
                postActivationSuccessNotification(appCtx)
            } else if (fromNotification) {
                postOrUpdatePairingNotification(
                    appCtx,
                    "已配对成功，等待无线调试连接端口",
                    _state.value.lastError.ifBlank { "请返回 OpenUU 点击「重连增强引擎」" }
                )
            }
        }
    }

    fun activateViaConnectPortAsync(context: Context, connectPort: Int) {
        val appCtx = context.applicationContext
        scope.launch {
            ensureNativeDirsInitialized(appCtx)
            val port = connectPort.takeIf { it in 1..65535 }
                ?: _state.value.connectPort.takeIf { it > 0 }
                ?: appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .getInt(KEY_LAST_CONNECT_PORT, 5555)
            val ok = spawnPrivViaAdbConnectPort(appCtx, port, silent = false)
            if (ok) {
                savePreferredMode(appCtx, AndroidHostMode.ENHANCED_MULTI_WINDOW)
                stopWirelessDiscovery()
                cancelPairingNotification(appCtx)
            }
        }
    }

    fun activateViaRootAsync(context: Context) {
        val appCtx = context.applicationContext
        scope.launch {
            _state.update {
                it.copy(isBusy = true, lastError = "", statusMessage = "正在请求 Root 授权启动增强引擎...")
            }
            val (privPort, privToken) = ensurePrivCredentials(appCtx)
            val cmd = buildLaunchPrivShellCommand(appCtx, privPort, privToken)
            val ran = runCatching {
                val proc = ProcessBuilder("su", "-c", cmd)
                    .redirectErrorStream(true)
                    .start()
                proc.waitFor(8, TimeUnit.SECONDS)
            }.isSuccess

            if (!ran) {
                _state.update {
                    it.copy(
                        isBusy = false,
                        lastError = "未获得 Root 授权或本机未安装 su，请改用「无线调试配对」",
                        statusMessage = "Root 激活失败"
                    )
                }
                return@launch
            }

            val verified = waitUntilDaemonAlive(privPort, privToken)
            if (verified.alive) {
                savePreferredMode(appCtx, AndroidHostMode.ENHANCED_MULTI_WINDOW)
                stopWirelessDiscovery()
                cancelPairingNotification(appCtx)
                _state.update {
                    it.copy(
                        isActive = true,
                        uid = verified.uid,
                        pid = verified.pid,
                        isBusy = false,
                        statusMessage = "Root 多窗口增强引擎已激活",
                        lastError = ""
                    )
                }
            } else {
                _state.update {
                    it.copy(
                        isBusy = false,
                        lastError = "Root 命令已执行，但增强引擎未在本地端口响应",
                        statusMessage = "激活未完成"
                    )
                }
            }
        }
    }

    suspend fun spawnPrivViaAdbConnectPort(
        context: Context,
        connectPort: Int,
        silent: Boolean
    ): Boolean {
        val appCtx = context.applicationContext
        ensureNativeDirsInitialized(appCtx)
        val (privPort, privToken) = ensurePrivCredentials(appCtx)

        val already = PrivDaemonClient.probeRunning(privPort, privToken)
        if (already.isCurrentVersion) {
            _state.update {
                it.copy(
                    isActive = true,
                    uid = already.uid,
                    pid = already.pid,
                    isBusy = false,
                    statusMessage = "多窗口增强引擎运行中 (UID ${already.uid})",
                    lastError = ""
                )
            }
            return true
        }
        if (already.alive) {
            Log.i(TAG, "Shutting down outdated OpenUUPrivServer version=${already.version} before respawn")
            PrivDaemonClient.shutdownDaemon(privPort, privToken)
            delay(180L)
        }

        if (!silent) {
            _state.update {
                it.copy(
                    isBusy = true,
                    lastError = "",
                    statusMessage = "正在通过本机调试端口 $connectPort 启动多窗口引擎..."
                )
            }
        }

        val cmd = buildLaunchPrivShellCommand(appCtx, privPort, privToken)
        val execRaw = OpenUUNativeBridge.nativeAdbExecShellJson("127.0.0.1", connectPort, cmd)
        Log.i(TAG, "ADB exec raw result on port $connectPort: $execRaw")
        val execObj = runCatching { JSONObject(execRaw) }.getOrNull()
        val execOk = execObj?.optBoolean("ok", false) == true
        if (!execOk) {
            val err = execObj?.optString("error").orEmpty().ifBlank { "连接无线调试端口 $connectPort 失败" }
            Log.w(TAG, "ADB exec failed on port $connectPort: $err")
            if (!silent) {
                _state.update {
                    it.copy(isBusy = false, lastError = err, statusMessage = "等待配对或连接")
                }
            }
            return false
        }

        appCtx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putInt(KEY_LAST_CONNECT_PORT, connectPort)
            .apply()

        val verified = waitUntilDaemonAlive(privPort, privToken)
        if (verified.alive) {
            Log.i(TAG, "PRIV_ENGINE_ACTIVE uid=${verified.uid} pid=${verified.pid} port=$privPort")
            _state.update {
                it.copy(
                    isActive = true,
                    uid = verified.uid,
                    pid = verified.pid,
                    isBusy = false,
                    statusMessage = "多窗口增强引擎运行中 (UID ${verified.uid})",
                    lastError = ""
                )
            }
            return true
        }

        if (!silent) {
            _state.update {
                it.copy(
                    isBusy = false,
                    lastError = "进程已拉起但未响应，请重试",
                    statusMessage = "启动超时"
                )
            }
        }
        return false
    }

    private suspend fun waitUntilDaemonAlive(
        privPort: Int,
        privToken: String
    ): PrivDaemonClient.Companion.ProbeInfo {
        repeat(28) {
            val info = PrivDaemonClient.probeRunning(privPort, privToken, timeoutMs = 350)
            if (info.isCurrentVersion) return info
            delay(180L)
        }
        return PrivDaemonClient.Companion.ProbeInfo(false)
    }

    private fun buildLaunchPrivShellCommand(context: Context, privPort: Int, privToken: String): String {
        val apkPath = context.applicationInfo.sourceDir
        return "CLASSPATH='$apkPath' setsid /system/bin/app_process /system/bin " +
            "--nice-name=openuu_priv ren.onekb.openuu.priv.OpenUUPrivServer " +
            "$privPort $privToken >/data/local/tmp/openuu_priv.log 2>&1 </dev/null & " +
            "sleep 0.4; echo OPENUU_PRIV_SPAWNED"
    }

    private fun ensureNativeDirsInitialized(context: Context) {
        runCatching {
            OpenUUNativeBridge.nativeInitAndroidContext(context.applicationContext)
            OpenUUNativeBridge.nativeSetAppDirs(
                context.filesDir.absolutePath,
                context.cacheDir.absolutePath
            )
        }
    }

    private fun detectSuBinary(): Boolean {
        val paths = listOf(
            "/system/bin/su",
            "/system/xbin/su",
            "/sbin/su",
            "/product/bin/su",
            "/apex/com.android.runtime/bin/su",
            "/data/adb/ksu/bin/su",
            "/data/adb/ap/bin/su"
        )
        return paths.any { runCatching { File(it).exists() }.getOrDefault(false) }
    }

    private fun createMdnsListener(
        serviceLabel: String,
        onPortFound: (Int) -> Unit
    ): NsdManager.DiscoveryListener {
        return object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {
                Log.d(TAG, "mDNS started ($serviceLabel): $regType")
            }

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                val mgr = nsdManager ?: return
                runCatching {
                    mgr.resolveService(
                        serviceInfo,
                        object : NsdManager.ResolveListener {
                            override fun onResolveFailed(si: NsdServiceInfo, errCode: Int) {
                                Log.d(TAG, "mDNS resolve failed ($serviceLabel): $errCode")
                            }

                            override fun onServiceResolved(resolved: NsdServiceInfo) {
                                val port = resolved.port
                                if (port in 1..65535) {
                                    Log.i(TAG, "mDNS resolved ($serviceLabel) port=$port host=${resolved.host}")
                                    onPortFound(port)
                                }
                            }
                        }
                    )
                }
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            override fun onDiscoveryStopped(serviceType: String) = Unit
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) = Unit
        }
    }

    private fun ensurePairingNotificationChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
            val channel = NotificationChannel(
                PAIRING_CHANNEL_ID,
                "OpenUU 无线调试一键配对",
                NotificationManager.IMPORTANCE_HIGH
            ).apply {
                description = "用于在「开发者选项 -> 无线调试」页面下拉通知栏直接输入 6 位配对码"
                setShowBadge(false)
            }
            nm.createNotificationChannel(channel)
        }
    }

    private fun postOrUpdatePairingNotification(context: Context, title: String, body: String) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        ensurePairingNotificationChannel(context)

        val remoteInput = RemoteInput.Builder(KEY_REMOTE_INPUT_CODE)
            .setLabel("输入屏幕上的 6 位数字配对码")
            .build()

        val replyIntent = Intent(context, WirelessAdbPairingReceiver::class.java).apply {
            action = ACTION_SUBMIT_PAIRING_CODE
            setPackage(context.packageName)
        }
        val mutableFlags = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
        } else {
            PendingIntent.FLAG_UPDATE_CURRENT
        }
        val replyPendingIntent = PendingIntent.getBroadcast(
            context,
            39488,
            replyIntent,
            mutableFlags
        )

        val replyAction = NotificationCompat.Action.Builder(
            android.R.drawable.ic_menu_send,
            "输入 6 位配对码",
            replyPendingIntent
        )
            .addRemoteInput(remoteInput)
            .setAllowGeneratedReplies(false)
            .build()

        val openAppIntent = PendingIntent.getActivity(
            context,
            39489,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notif = NotificationCompat.Builder(context, PAIRING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setOnlyAlertOnce(false)
            .setAutoCancel(false)
            .setContentIntent(openAppIntent)
            .addAction(replyAction)
            .build()

        runCatching { nm.notify(PAIRING_NOTIF_ID, notif) }
    }

    private fun postActivationSuccessNotification(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        val openAppIntent = PendingIntent.getActivity(
            context,
            39490,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(context, PAIRING_CHANNEL_ID)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("OpenUU 多窗口增强模式已激活")
            .setContentText("点击返回 OpenUU 开启被控，即可免录屏弹窗同时打开多个独立应用与微信分身")
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setAutoCancel(true)
            .setContentIntent(openAppIntent)
            .build()
        runCatching { nm.notify(PAIRING_NOTIF_ID, notif) }
    }

    fun cancelPairingNotification(context: Context) {
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        runCatching { nm.cancel(PAIRING_NOTIF_ID) }
    }
}

class WirelessAdbPairingReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        if (intent?.action != WirelessAdbActivator.ACTION_SUBMIT_PAIRING_CODE) return
        val results = RemoteInput.getResultsFromIntent(intent) ?: return
        val code = results.getCharSequence(WirelessAdbActivator.KEY_REMOTE_INPUT_CODE)?.toString().orEmpty()
        WirelessAdbActivator.pairAndActivateAsync(
            context = context.applicationContext,
            pairingCode = code,
            fromNotification = true
        )
    }
}

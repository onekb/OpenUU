package ren.onekb.openuu

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

enum class UpdateCheckPolicy(val code: String, val label: String) {
    LAUNCH_AND_DAILY("launch_and_daily", "打开时与每天检查"),
    DAILY_ONLY("daily", "每天检查一次"),
    MANUAL_ONLY("manual", "仅手动检查");

    companion object {
        fun fromCode(raw: String?): UpdateCheckPolicy =
            entries.firstOrNull { it.code == raw?.trim() } ?: LAUNCH_AND_DAILY
    }
}

data class ReleaseUpdateInfo(
    val hasUpdate: Boolean,
    val currentVersion: String,
    val latestVersion: String,
    val tagName: String,
    val title: String,
    val releaseNotes: String,
    val publishedAt: String,
    val htmlUrl: String,
    val assetName: String,
    val downloadUrl: String,
    val assetSizeBytes: Long,
    val assetSha256: String
) {
    val formattedSize: String
        get() = if (assetSizeBytes > 0L) {
            String.format(Locale.US, "%.1f MB", assetSizeBytes / 1048576.0)
        } else {
            ""
        }

    val formattedDate: String
        get() = if (publishedAt.length >= 10) publishedAt.substring(0, 10) else publishedAt
}

sealed class ApkInstallState {
    data object Idle : ApkInstallState()
    data class Downloading(val downloadedBytes: Long, val totalBytes: Long) : ApkInstallState()
    data class ReadyToInstall(val apkFile: File, val message: String) : ApkInstallState()
    data class Failed(val error: String) : ApkInstallState()

    val isBusy: Boolean
        get() = this is Downloading
}

class AppUpdater(
    private val appContext: Context,
    private val scope: CoroutineScope,
    private val coordUrlProvider: () -> String,
    private val onLog: (String) -> Unit
) {
    companion object {
        const val GITHUB_LATEST_API = "https://api.github.com/repos/onekb/OpenUU/releases/latest"
        const val GITHUB_RELEASES_PAGE = "https://github.com/onekb/OpenUU/releases/latest"
        private const val PREFS_NAME = "openuu_updater_prefs"
        private const val KEY_POLICY = "policy"
        private const val KEY_LAST_CHECK = "last_check_sec"
        private const val KEY_SKIPPED_VER = "skipped_ver"

        val currentVersion: String
            get() = BuildConfig.VERSION_NAME.ifBlank { "0.7.7" }

        val displayVersion: String
            get() = if (currentVersion.startsWith("v")) currentVersion else "v$currentVersion"

        fun parseSemVer(raw: String): Triple<Int, Int, Int>? {
            val clean = raw.trim().trimStart('v', 'V').substringBefore('-').substringBefore('+')
            val parts = clean.split('.')
            val maj = parts.getOrNull(0)?.toIntOrNull() ?: return null
            val min = parts.getOrNull(1)?.toIntOrNull() ?: 0
            val pat = parts.getOrNull(2)?.toIntOrNull() ?: 0
            return Triple(maj, min, pat)
        }

        fun isNewer(current: String, latest: String): Boolean {
            val c = parseSemVer(current) ?: return false
            val l = parseSemVer(latest) ?: return false
            if (l.first != c.first) return l.first > c.first
            if (l.second != c.second) return l.second > c.second
            return l.third > c.third
        }
    }

    private val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private val _policy = MutableStateFlow(UpdateCheckPolicy.fromCode(prefs.getString(KEY_POLICY, null)))
    val policy: StateFlow<UpdateCheckPolicy> = _policy.asStateFlow()

    private val _isChecking = MutableStateFlow(false)
    val isChecking: StateFlow<Boolean> = _isChecking.asStateFlow()

    private val _releaseInfo = MutableStateFlow<ReleaseUpdateInfo?>(null)
    val releaseInfo: StateFlow<ReleaseUpdateInfo?> = _releaseInfo.asStateFlow()

    private val _statusSummary = MutableStateFlow("当前 $displayVersion")
    val statusSummary: StateFlow<String> = _statusSummary.asStateFlow()

    private val _showUpdateDialog = MutableStateFlow(false)
    val showUpdateDialog: StateFlow<Boolean> = _showUpdateDialog.asStateFlow()

    private val _installState = MutableStateFlow<ApkInstallState>(ApkInstallState.Idle)
    val installState: StateFlow<ApkInstallState> = _installState.asStateFlow()

    private var downloadJob: Job? = null

    init {
        refreshLastCheckLabel()
        startScheduledLoop()
    }

    fun setPolicy(newPolicy: UpdateCheckPolicy) {
        _policy.value = newPolicy
        prefs.edit().putString(KEY_POLICY, newPolicy.code).apply()
    }

    fun setShowUpdateDialog(visible: Boolean) {
        _showUpdateDialog.value = visible
    }

    fun skipCurrentAvailableVersion() {
        val ver = _releaseInfo.value?.latestVersion.orEmpty()
        if (ver.isNotBlank()) {
            prefs.edit().putString(KEY_SKIPPED_VER, ver).apply()
            _showUpdateDialog.value = false
            onLog("[更新] 已忽略版本 v$ver")
        }
    }

    private fun startScheduledLoop() {
        scope.launch {
            delay(2200L)
            runScheduledCheckIfDue(isLaunch = true)
            while (true) {
                delay(6L * 3600L * 1000L)
                runScheduledCheckIfDue(isLaunch = false)
            }
        }
    }

    private fun runScheduledCheckIfDue(isLaunch: Boolean) {
        when (_policy.value) {
            UpdateCheckPolicy.MANUAL_ONLY -> return
            UpdateCheckPolicy.LAUNCH_AND_DAILY -> {
                if (isLaunch || isDailyDue()) checkForUpdates(manual = false)
            }
            UpdateCheckPolicy.DAILY_ONLY -> {
                if (isDailyDue()) checkForUpdates(manual = false)
            }
        }
    }

    private fun isDailyDue(): Boolean {
        val last = prefs.getLong(KEY_LAST_CHECK, 0L)
        if (last <= 0L) return true
        val nowSec = System.currentTimeMillis() / 1000L
        return (nowSec - last) >= 24L * 3600L
    }

    private fun refreshLastCheckLabel() {
        val last = prefs.getLong(KEY_LAST_CHECK, 0L)
        if (last <= 0L) {
            _statusSummary.value = "当前 $displayVersion"
            return
        }
        val fmt = SimpleDateFormat("MM-dd HH:mm", Locale.getDefault())
        _statusSummary.value = "上次检查 ${fmt.format(Date(last * 1000L))}"
    }

    fun checkForUpdates(manual: Boolean) {
        if (_isChecking.value) return
        _isChecking.value = true
        if (manual) {
            _statusSummary.value = "正在检查..."
            if (_installState.value is ApkInstallState.Failed) {
                _installState.value = ApkInstallState.Idle
            }
        }

        scope.launch {
            try {
                val coordBase = coordUrlProvider().trim().trimEnd('/')
                val urls = buildList {
                    if (coordBase.isNotEmpty()) add("$coordBase/v1/latest-release")
                    add(GITHUB_LATEST_API)
                }

                var lastErr = "无法连接更新服务"
                var resolved: ReleaseUpdateInfo? = null

                for (u in urls) {
                    try {
                        val rawJson = withContext(Dispatchers.IO) { fetchUrlText(u) }
                        val parsed = parseReleaseJson(rawJson)
                        if (parsed != null) {
                            resolved = parsed
                            break
                        }
                    } catch (e: Throwable) {
                        lastErr = e.message ?: "网络请求异常"
                    }
                }

                if (resolved != null) {
                    val nowSec = System.currentTimeMillis() / 1000L
                    prefs.edit().putLong(KEY_LAST_CHECK, nowSec).apply()
                    _releaseInfo.value = resolved

                    if (resolved.hasUpdate) {
                        _statusSummary.value = "发现新版本 ${resolved.tagName}"
                        onLog("[更新] 发现新版本 ${resolved.tagName}")
                        val skipped = prefs.getString(KEY_SKIPPED_VER, "").orEmpty()
                        if (manual || skipped != resolved.latestVersion) {
                            _showUpdateDialog.value = true
                        }
                    } else {
                        _statusSummary.value = "已是最新 ($displayVersion)"
                        if (manual) {
                            _showUpdateDialog.value = true
                        }
                    }
                } else if (manual) {
                    _statusSummary.value = "检查失败：$lastErr"
                    onLog("[更新] 检查更新失败: $lastErr")
                }
            } finally {
                _isChecking.value = false
            }
        }
    }

    private fun fetchUrlText(urlStr: String): String {
        val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 6000
            readTimeout = 7000
            instanceFollowRedirects = true
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "OpenUU-Android/$currentVersion")
        }
        try {
            val code = conn.responseCode
            if (code !in 200..299) {
                throw IllegalStateException("HTTP $code")
            }
            return conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    private fun parseReleaseJson(rawJson: String): ReleaseUpdateInfo? {
        val obj = JSONObject(rawJson)
        if (obj.optBoolean("draft", false)) return null
        val rawTag = obj.optString("tag_name", "").trim()
        if (rawTag.isEmpty()) return null

        val curVer = currentVersion
        val latestClean = rawTag.trimStart('v', 'V')
        val newer = isNewer(curVer, rawTag)

        val primaryAbi = Build.SUPPORTED_ABIS.firstOrNull().orEmpty().lowercase()
        val preferX86 = primaryAbi.contains("x86")
        val assetsArr = obj.optJSONArray("assets")

        var chosenName = ""
        var chosenUrl = ""
        var chosenSize = 0L
        var chosenSha = ""

        if (assetsArr != null) {
            var fallbackIdx = -1
            var exactIdx = -1
            for (i in 0 until assetsArr.length()) {
                val a = assetsArr.optJSONObject(i) ?: continue
                val n = a.optString("name", "")
                val dl = a.optString("browser_download_url", "")
                if (!n.lowercase().endsWith(".apk") || dl.isBlank()) continue
                if (fallbackIdx == -1) fallbackIdx = i
                val lc = n.lowercase()
                if ((preferX86 && lc.contains("x86")) || (!preferX86 && lc.contains("arm64"))) {
                    exactIdx = i
                    break
                }
            }
            val pick = if (exactIdx >= 0) exactIdx else fallbackIdx
            if (pick >= 0) {
                val a = assetsArr.getJSONObject(pick)
                chosenName = a.optString("name", "")
                chosenUrl = a.optString("browser_download_url", "")
                chosenSize = a.optLong("size", 0L)
                chosenSha = a.optString("digest", "")
                    .removePrefix("sha256:")
                    .trim()
                    .lowercase()
            }
        }

        return ReleaseUpdateInfo(
            hasUpdate = newer,
            currentVersion = curVer,
            latestVersion = latestClean,
            tagName = if (rawTag.startsWith("v")) rawTag else "v$rawTag",
            title = obj.optString("name", "").ifBlank { "OpenUU $rawTag" },
            releaseNotes = obj.optString("body", "").trim(),
            publishedAt = obj.optString("published_at", ""),
            htmlUrl = obj.optString("html_url", "").ifBlank { GITHUB_RELEASES_PAGE },
            assetName = chosenName,
            downloadUrl = chosenUrl,
            assetSizeBytes = chosenSize,
            assetSha256 = chosenSha
        )
    }

    fun openReleaseInBrowser(context: Context) {
        val url = _releaseInfo.value?.downloadUrl?.takeIf { it.isNotBlank() }
            ?: _releaseInfo.value?.htmlUrl
            ?: GITHUB_RELEASES_PAGE
        runCatching {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(intent)
        }
    }

    fun cancelDownload() {
        downloadJob?.cancel()
        downloadJob = null
        _installState.value = ApkInstallState.Idle
    }

    fun startDownloadAndInstallApk(context: Context) {
        val currentState = _installState.value
        if (currentState is ApkInstallState.ReadyToInstall && currentState.apkFile.exists()) {
            launchSystemApkInstaller(context, currentState.apkFile)
            return
        }
        val info = _releaseInfo.value ?: return
        if (currentState.isBusy) return
        if (info.downloadUrl.isBlank()) {
            openReleaseInBrowser(context)
            return
        }

        _installState.value = ApkInstallState.Downloading(0L, info.assetSizeBytes)
        downloadJob = scope.launch {
            try {
                val apkFile = withContext(Dispatchers.IO) {
                    val dir = File(appContext.cacheDir, "updates").apply { mkdirs() }
                    val target = File(dir, "OpenUU-${info.latestVersion}.apk")
                    val conn = (URL(info.downloadUrl).openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 15000
                        readTimeout = 30000
                        instanceFollowRedirects = true
                        setRequestProperty("User-Agent", "OpenUU-Android/$currentVersion")
                    }
                    try {
                        val code = conn.responseCode
                        if (code !in 200..299) throw IllegalStateException("下载返回 HTTP $code")
                        val total = conn.contentLengthLong.takeIf { it > 0L } ?: info.assetSizeBytes
                        val digest = MessageDigest.getInstance("SHA-256")
                        var downloaded = 0L
                        var lastUiMs = 0L

                        conn.inputStream.use { input ->
                            FileOutputStream(target).use { out ->
                                val buf = ByteArray(65536)
                                while (true) {
                                    ensureActive()
                                    val n = input.read(buf)
                                    if (n <= 0) break
                                    out.write(buf, 0, n)
                                    digest.update(buf, 0, n)
                                    downloaded += n
                                    val now = System.currentTimeMillis()
                                    if (now - lastUiMs >= 80L || (total > 0L && downloaded >= total)) {
                                        lastUiMs = now
                                        _installState.value = ApkInstallState.Downloading(downloaded, total)
                                    }
                                }
                            }
                        }

                        if (info.assetSha256.isNotBlank()) {
                            val actualHex = digest.digest().joinToString("") { "%02x".format(it) }
                            if (!actualHex.equals(info.assetSha256, ignoreCase = true)) {
                                target.delete()
                                throw IllegalStateException("安装包 SHA-256 校验不一致")
                            }
                        }
                        target
                    } finally {
                        conn.disconnect()
                    }
                }

                _installState.value = ApkInstallState.ReadyToInstall(apkFile, "安装包已就绪，正在调起系统安装...")
                launchSystemApkInstaller(context, apkFile)
            } catch (_: CancellationException) {
                _installState.value = ApkInstallState.Idle
            } catch (e: Throwable) {
                val msg = e.message ?: "下载失败"
                _installState.value = ApkInstallState.Failed("下载异常：$msg（可点击「浏览器下载」手动安装）")
                onLog("[更新] APK 下载失败: $msg")
            }
        }
    }

    private fun launchSystemApkInstaller(context: Context, apkFile: File) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !context.packageManager.canRequestPackageInstalls()) {
            _installState.value = ApkInstallState.ReadyToInstall(
                apkFile,
                "安装包已下载完成！请先开启「允许安装未知应用」权限，返回后点击「立即安装」即可。"
            )
            runCatching {
                val permIntent = Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse("package:${context.packageName}")
                ).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                context.startActivity(permIntent)
            }
            return
        }

        runCatching {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                apkFile
            )
            val installIntent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            context.startActivity(installIntent)
        }.onFailure { e ->
            _installState.value = ApkInstallState.Failed("调起安装器失败：${e.message}")
        }
    }
}

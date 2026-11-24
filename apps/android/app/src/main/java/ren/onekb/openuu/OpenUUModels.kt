package ren.onekb.openuu

import org.json.JSONArray
import org.json.JSONObject

object OpenUUConstants {
    const val DEFAULT_PORT = 39481
    const val FULL_DESKTOP_BUNDLE_ID = "__openuu_full_desktop__"
    const val FULL_DESKTOP_WINDOW_ID: Int = 0x7FFF_FF00
    const val DEFAULT_COORD_URL = "https://openuu.1kb.ren"
    const val DEFAULT_RELAY_URL = "https://openuu-relay.1kb.ren"
}

object MacModifiers {
    const val SHIFT = 1
    const val CONTROL = 2
    const val OPTION = 4
    const val COMMAND = 8
}

object MacKeyCodes {
    const val A = 0
    const val S = 1
    const val D = 2
    const val F = 3
    const val H = 4
    const val G = 5
    const val Z = 6
    const val X = 7
    const val C = 8
    const val V = 9
    const val B = 11
    const val Q = 12
    const val W = 13
    const val E = 14
    const val R = 15
    const val Y = 16
    const val T = 17
    const val NUM_1 = 18
    const val NUM_2 = 19
    const val NUM_3 = 20
    const val NUM_4 = 21
    const val NUM_6 = 22
    const val NUM_5 = 23
    const val EQUAL = 24
    const val NUM_9 = 25
    const val NUM_7 = 26
    const val MINUS = 27
    const val NUM_8 = 28
    const val NUM_0 = 29
    const val RIGHT_BRACKET = 30
    const val O = 31
    const val U = 32
    const val LEFT_BRACKET = 33
    const val I = 34
    const val P = 35
    const val RETURN = 36
    const val L = 37
    const val J = 38
    const val QUOTE = 39
    const val K = 40
    const val SEMICOLON = 41
    const val BACKSLASH = 42
    const val COMMA = 43
    const val SLASH = 44
    const val N = 45
    const val M = 46
    const val PERIOD = 47
    const val TAB = 48
    const val SPACE = 49
    const val GRAVE = 50
    const val DELETE = 51
    const val ESCAPE = 53
    const val F5 = 96
    const val F6 = 97
    const val F7 = 98
    const val F3 = 99
    const val F8 = 100
    const val F9 = 101
    const val F11 = 103
    const val F10 = 109
    const val F12 = 111
    const val HOME = 115
    const val PAGE_UP = 116
    const val FORWARD_DELETE = 117
    const val F4 = 118
    const val END = 119
    const val F2 = 120
    const val PAGE_DOWN = 121
    const val F1 = 122
    const val LEFT = 123
    const val RIGHT = 124
    const val DOWN = 125
    const val UP = 126

    /** Maps a single ASCII character to `(keyCode, extraShiftModifier)` when sticky modifiers are active. */
    fun asciiToKeyAndShift(ch: Char): Pair<Int, Int>? {
        return when (ch) {
            'a' -> A to 0; 'A' -> A to MacModifiers.SHIFT
            'b' -> B to 0; 'B' -> B to MacModifiers.SHIFT
            'c' -> C to 0; 'C' -> C to MacModifiers.SHIFT
            'd' -> D to 0; 'D' -> D to MacModifiers.SHIFT
            'e' -> E to 0; 'E' -> E to MacModifiers.SHIFT
            'f' -> F to 0; 'F' -> F to MacModifiers.SHIFT
            'g' -> G to 0; 'G' -> G to MacModifiers.SHIFT
            'h' -> H to 0; 'H' -> H to MacModifiers.SHIFT
            'i' -> I to 0; 'I' -> I to MacModifiers.SHIFT
            'j' -> J to 0; 'J' -> J to MacModifiers.SHIFT
            'k' -> K to 0; 'K' -> K to MacModifiers.SHIFT
            'l' -> L to 0; 'L' -> L to MacModifiers.SHIFT
            'm' -> M to 0; 'M' -> M to MacModifiers.SHIFT
            'n' -> N to 0; 'N' -> N to MacModifiers.SHIFT
            'o' -> O to 0; 'O' -> O to MacModifiers.SHIFT
            'p' -> P to 0; 'P' -> P to MacModifiers.SHIFT
            'q' -> Q to 0; 'Q' -> Q to MacModifiers.SHIFT
            'r' -> R to 0; 'R' -> R to MacModifiers.SHIFT
            's' -> S to 0; 'S' -> S to MacModifiers.SHIFT
            't' -> T to 0; 'T' -> T to MacModifiers.SHIFT
            'u' -> U to 0; 'U' -> U to MacModifiers.SHIFT
            'v' -> V to 0; 'V' -> V to MacModifiers.SHIFT
            'w' -> W to 0; 'W' -> W to MacModifiers.SHIFT
            'x' -> X to 0; 'X' -> X to MacModifiers.SHIFT
            'y' -> Y to 0; 'Y' -> Y to MacModifiers.SHIFT
            'z' -> Z to 0; 'Z' -> Z to MacModifiers.SHIFT
            '0' -> NUM_0 to 0; ')' -> NUM_0 to MacModifiers.SHIFT
            '1' -> NUM_1 to 0; '!' -> NUM_1 to MacModifiers.SHIFT
            '2' -> NUM_2 to 0; '@' -> NUM_2 to MacModifiers.SHIFT
            '3' -> NUM_3 to 0; '#' -> NUM_3 to MacModifiers.SHIFT
            '4' -> NUM_4 to 0; '$' -> NUM_4 to MacModifiers.SHIFT
            '5' -> NUM_5 to 0; '%' -> NUM_5 to MacModifiers.SHIFT
            '6' -> NUM_6 to 0; '^' -> NUM_6 to MacModifiers.SHIFT
            '7' -> NUM_7 to 0; '&' -> NUM_7 to MacModifiers.SHIFT
            '8' -> NUM_8 to 0; '*' -> NUM_8 to MacModifiers.SHIFT
            '9' -> NUM_9 to 0; '(' -> NUM_9 to MacModifiers.SHIFT
            '-' -> MINUS to 0; '_' -> MINUS to MacModifiers.SHIFT
            '=' -> EQUAL to 0; '+' -> EQUAL to MacModifiers.SHIFT
            '[' -> LEFT_BRACKET to 0; '{' -> LEFT_BRACKET to MacModifiers.SHIFT
            ']' -> RIGHT_BRACKET to 0; '}' -> RIGHT_BRACKET to MacModifiers.SHIFT
            '\\' -> BACKSLASH to 0; '|' -> BACKSLASH to MacModifiers.SHIFT
            ';' -> SEMICOLON to 0; ':' -> SEMICOLON to MacModifiers.SHIFT
            '\'' -> QUOTE to 0; '"' -> QUOTE to MacModifiers.SHIFT
            ',' -> COMMA to 0; '<' -> COMMA to MacModifiers.SHIFT
            '.' -> PERIOD to 0; '>' -> PERIOD to MacModifiers.SHIFT
            '/' -> SLASH to 0; '?' -> SLASH to MacModifiers.SHIFT
            '`' -> GRAVE to 0; '~' -> GRAVE to MacModifiers.SHIFT
            ' ' -> SPACE to 0
            else -> null
        }
    }
}

enum class TouchMode(val label: String) {
    DIRECT_TOUCH("直触"),
    TRACKPAD("触控板")
}

enum class VideoFitMode(val label: String) {
    FIT("适应"),
    FILL("铺满")
}

sealed class ConnectionPhase {
    data object Idle : ConnectionPhase()
    data class Connecting(val detail: String = "正在连接...") : ConnectionPhase()
    data class Connected(val hostName: String) : ConnectionPhase()
    data class Error(val reason: String) : ConnectionPhase()

    val isConnected: Boolean get() = this is Connected
    val isConnecting: Boolean get() = this is Connecting
}

data class WanConfig(
    val coordUrl: String = OpenUUConstants.DEFAULT_COORD_URL,
    val relayUrl: String = OpenUUConstants.DEFAULT_RELAY_URL,
    val relayAuthToken: String = "",
    val enablePublicFallback: Boolean = true,
    val allowInsecureTls: Boolean = false
) {
    fun toJson(): String = JSONObject().apply {
        put("coord_url", coordUrl.trim())
        put("relay_url", relayUrl.trim())
        put("relay_auth_token", relayAuthToken.trim())
        put("enable_public_fallback", enablePublicFallback)
        put("allow_insecure_tls", allowInsecureTls)
    }.toString()

    companion object {
        fun fromJson(obj: JSONObject?): WanConfig {
            if (obj == null) return WanConfig()
            return WanConfig(
                coordUrl = obj.optString("coord_url", OpenUUConstants.DEFAULT_COORD_URL),
                relayUrl = obj.optString("relay_url", OpenUUConstants.DEFAULT_RELAY_URL),
                relayAuthToken = obj.optString("relay_auth_token", ""),
                enablePublicFallback = obj.optBoolean("enable_public_fallback", true),
                allowInsecureTls = obj.optBoolean("allow_insecure_tls", false)
            )
        }
    }
}

data class TrustedPeer(
    val deviceId: String,
    val deviceName: String,
    val certFingerprint: String,
    val endpointId: String,
    val deviceCode: String,
    val lastRelayUrl: String,
    val lastTicket: String,
    val lastConnectedMs: Long
) {
    val connectTarget: String
        get() = when {
            deviceCode.length == 9 -> deviceCode
            lastTicket.isNotBlank() -> lastTicket
            deviceId.isNotBlank() -> deviceId
            else -> endpointId
        }

    companion object {
        fun fromJson(obj: JSONObject): TrustedPeer = TrustedPeer(
            deviceId = obj.optString("device_id", ""),
            deviceName = obj.optString("device_name", "Mac"),
            certFingerprint = obj.optString("cert_fingerprint", ""),
            endpointId = obj.optString("endpoint_id", ""),
            deviceCode = obj.optString("device_code", ""),
            lastRelayUrl = obj.optString("last_relay_url", ""),
            lastTicket = obj.optString("last_ticket", ""),
            lastConnectedMs = obj.optLong("last_connected_ms", 0L)
        )
    }
}

data class IdentitySnapshot(
    val deviceId: String = "",
    val deviceName: String = "",
    val deviceCode: String = "",
    val formattedCode: String = "",
    val endpointId: String = "",
    val hostTicket: String = "",
    val coordStatus: String = "",
    val wanConfig: WanConfig = WanConfig(),
    val trustedPeers: List<TrustedPeer> = emptyList()
) {
    companion object {
        fun parse(json: String): IdentitySnapshot {
            return try {
                val obj = JSONObject(json)
                val peersArr = obj.optJSONArray("trusted_peers") ?: JSONArray()
                val peers = buildList {
                    for (i in 0 until peersArr.length()) {
                        peersArr.optJSONObject(i)?.let { add(TrustedPeer.fromJson(it)) }
                    }
                }
                IdentitySnapshot(
                    deviceId = obj.optString("device_id", ""),
                    deviceName = obj.optString("device_name", ""),
                    deviceCode = obj.optString("device_code", ""),
                    formattedCode = obj.optString("formatted_code", ""),
                    endpointId = obj.optString("endpoint_id", ""),
                    hostTicket = obj.optString("host_ticket", ""),
                    coordStatus = obj.optString("coord_status", ""),
                    wanConfig = WanConfig.fromJson(obj.optJSONObject("wan_config")),
                    trustedPeers = peers
                )
            } catch (_: Throwable) {
                IdentitySnapshot()
            }
        }
    }
}

data class DiscoveredPeer(
    val deviceId: String,
    val deviceName: String,
    val os: String,
    val addresses: List<String>,
    val port: Int,
    val protocolVersion: Int,
    val deviceCode: String,
    val endpointId: String
) {
    val primaryAddress: String
        get() = addresses.firstOrNull { !it.contains(":") } ?: addresses.firstOrNull().orEmpty()

    companion object {
        fun parseList(json: String): List<DiscoveredPeer> {
            return try {
                val arr = JSONArray(json)
                buildList {
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        val addrArr = obj.optJSONArray("addresses") ?: JSONArray()
                        val addrs = buildList {
                            for (j in 0 until addrArr.length()) {
                                val a = addrArr.optString(j)
                                if (a.isNotBlank()) add(a)
                            }
                        }
                        add(
                            DiscoveredPeer(
                                deviceId = obj.optString("device_id", ""),
                                deviceName = obj.optString("device_name", "Unknown Mac"),
                                os = obj.optString("os", "macos"),
                                addresses = addrs,
                                port = obj.optInt("port", OpenUUConstants.DEFAULT_PORT),
                                protocolVersion = obj.optInt("protocol_version", 1),
                                deviceCode = obj.optString("device_code", ""),
                                endpointId = obj.optString("endpoint_id", "")
                            )
                        )
                    }
                }
            } catch (_: Throwable) {
                emptyList()
            }
        }
    }
}

data class RemoteAppSummary(
    val bundleId: String,
    val name: String,
    val pid: Long,
    val windowCount: Int,
    val iconPngB64: String
) {
    companion object {
        fun fromJson(obj: JSONObject): RemoteAppSummary = RemoteAppSummary(
            bundleId = obj.optString("bundle_id", ""),
            name = obj.optString("name", ""),
            pid = obj.optLong("pid", 0L),
            windowCount = obj.optInt("window_count", 0),
            iconPngB64 = obj.optString("icon_png_b64", "")
        )
    }
}

data class WindowTopologyItem(
    val windowId: Int,
    val parentWindowId: Int,
    val kind: Int,
    val relX: Float,
    val relY: Float,
    val width: Float,
    val height: Float,
    val title: String,
    val iconPngB64: String
) {
    val unsignedWindowId: UInt get() = windowId.toUInt()

    val displayTitle: String
        get() = when {
            windowId == OpenUUConstants.FULL_DESKTOP_WINDOW_ID -> "Mac 整屏桌面"
            title.isNotBlank() -> title
            else -> "窗口 #$unsignedWindowId"
        }

    companion object {
        fun fromJson(obj: JSONObject): WindowTopologyItem = WindowTopologyItem(
            windowId = obj.optLong("window_id", 0L).toInt(),
            parentWindowId = obj.optLong("parent_window_id", 0L).toInt(),
            kind = obj.optInt("kind", 0),
            relX = obj.optDouble("rel_x", 0.0).toFloat(),
            relY = obj.optDouble("rel_y", 0.0).toFloat(),
            width = obj.optDouble("width", 0.0).toFloat(),
            height = obj.optDouble("height", 0.0).toFloat(),
            title = obj.optString("title", ""),
            iconPngB64 = obj.optString("icon_png_b64", "")
        )
    }
}

data class DeviceBookEntry(
    val id: String,
    val alias: String,
    val target: String,
    val port: Int = OpenUUConstants.DEFAULT_PORT,
    val savedPin: String = "",
    val favorite: Boolean = false,
    val notes: String = "",
    val remoteDeviceId: String = "",
    val deviceCode: String = "",
    val lastConnectedMs: Long = 0L
) {
    val displayTarget: String
        get() {
            val clean = target.trim()
            val digits = clean.filter { it.isDigit() }
            if (digits.length == 9 && clean.all { it.isDigit() || it == ' ' || it == '-' }) {
                return "${digits.substring(0, 3)} ${digits.substring(3, 6)} ${digits.substring(6, 9)}"
            }
            if (clean.startsWith("openuu://")) {
                return if (deviceCode.length == 9) {
                    "${deviceCode.substring(0, 3)} ${deviceCode.substring(3, 6)} ${deviceCode.substring(6, 9)} (连接串)"
                } else {
                    "openuu:// 跨网连接串"
                }
            }
            return if (port == OpenUUConstants.DEFAULT_PORT || clean.contains(":")) clean else "$clean:$port"
        }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("alias", alias)
        put("target", target)
        put("port", port)
        put("savedPin", savedPin)
        put("favorite", favorite)
        put("notes", notes)
        put("remoteDeviceId", remoteDeviceId)
        put("deviceCode", deviceCode)
        put("lastConnectedMs", lastConnectedMs)
    }

    companion object {
        fun fromJson(obj: JSONObject): DeviceBookEntry = DeviceBookEntry(
            id = obj.optString("id", java.util.UUID.randomUUID().toString()),
            alias = obj.optString("alias", "远程 Mac"),
            target = obj.optString("target", ""),
            port = obj.optInt("port", OpenUUConstants.DEFAULT_PORT),
            savedPin = obj.optString("savedPin", ""),
            favorite = obj.optBoolean("favorite", false),
            notes = obj.optString("notes", ""),
            remoteDeviceId = obj.optString("remoteDeviceId", ""),
            deviceCode = obj.optString("deviceCode", ""),
            lastConnectedMs = obj.optLong("lastConnectedMs", 0L)
        )
    }
}

data class DeviceProbeResult(
    val id: String,
    val online: Boolean,
    val via: String,
    val remoteName: String
) {
    val label: String
        get() = when (via) {
            "lan" -> "局域网在线"
            "wan" -> "跨网在线"
            else -> "离线"
        }

    companion object {
        fun parseList(json: String): List<DeviceProbeResult> {
            return try {
                val arr = JSONArray(json)
                buildList {
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        add(
                            DeviceProbeResult(
                                id = obj.optString("id", ""),
                                online = obj.optBoolean("online", false),
                                via = obj.optString("via", "offline"),
                                remoteName = obj.optString("remote_name", "")
                            )
                        )
                    }
                }
            } catch (_: Throwable) {
                emptyList()
            }
        }
    }
}

data class VideoTelemetry(
    val codec: String = "-",
    val fps: Int = 0,
    val bitrateMbps: Double = 0.0,
    val width: Int = 0,
    val height: Int = 0,
    val decodedFrames: Long = 0L
)

data class RemoteNotificationBanner(
    val id: Long = System.currentTimeMillis(),
    val appBundleId: String,
    val title: String,
    val subtitle: String,
    val body: String
)

sealed class ControlEvent {
    data object ListAppsReq : ControlEvent()
    data class ListAppsResp(val apps: List<RemoteAppSummary>) : ControlEvent()
    data class StartSession(val bundleId: String, val windowId: Int) : ControlEvent()
    data class StopSession(val windowId: Int) : ControlEvent()
    data class RequestKeyframe(val windowId: Int) : ControlEvent()
    data class AudioControl(val audioEnabled: Boolean, val muteHost: Boolean) : ControlEvent()
    data class ResizeWindow(val windowId: Int, val width: Float, val height: Float) : ControlEvent()
    data class Mouse(
        val windowId: Int,
        val x: Float,
        val y: Float,
        val eventType: Int,
        val button: Int,
        val clickCount: Int,
        val modifiers: Int
    ) : ControlEvent()
    data class Scroll(
        val windowId: Int,
        val x: Float,
        val y: Float,
        val deltaX: Float,
        val deltaY: Float,
        val isContinuous: Boolean,
        val modifiers: Int
    ) : ControlEvent()
    data class Key(
        val windowId: Int,
        val keyCode: Int,
        val isDown: Boolean,
        val isRepeat: Boolean,
        val modifiers: Int
    ) : ControlEvent()
    data class TextCommit(val windowId: Int, val text: String) : ControlEvent()
    data class WindowTopology(val windows: List<WindowTopologyItem>) : ControlEvent()
    data class LinkQuality(val linkMode: String, val rttMs: Int, val remoteAddr: String) : ControlEvent()
    data class Cursor(val kind: String, val hotspotX: Float, val hotspotY: Float) : ControlEvent()
    data class ClipboardSync(
        val contentHash: String,
        val clipKind: Int,
        val text: String,
        val mimeType: String,
        val imageB64: String
    ) : ControlEvent()
    data class Notification(
        val appBundleId: String,
        val title: String,
        val subtitle: String,
        val body: String,
        val timestampMs: Long
    ) : ControlEvent()
    data class BadgeUpdate(val appBundleId: String, val badgeText: String) : ControlEvent()
    data class FileDrop(
        val windowId: Int,
        val x: Float,
        val y: Float,
        val blobId: String,
        val localPath: String,
        val totalBytes: Long = 0L
    ) : ControlEvent()
    data class Unknown(val rawType: String) : ControlEvent()

    companion object {
        fun parse(json: String): ControlEvent {
            return try {
                val obj = JSONObject(json)
                when (val type = obj.optString("type", "")) {
                    "list_apps_req" -> ListAppsReq
                    "list_apps_resp" -> {
                        val arr = obj.optJSONArray("apps") ?: JSONArray()
                        val list = buildList {
                            for (i in 0 until arr.length()) {
                                arr.optJSONObject(i)?.let { add(RemoteAppSummary.fromJson(it)) }
                            }
                        }
                        ListAppsResp(list)
                    }
                    "start_session" -> StartSession(
                        bundleId = obj.optString("bundle_id", ""),
                        windowId = obj.optLong("window_id", 0L).toInt()
                    )
                    "stop_session" -> StopSession(
                        windowId = obj.optLong("window_id", 0L).toInt()
                    )
                    "request_keyframe" -> RequestKeyframe(
                        windowId = obj.optLong("window_id", 0L).toInt()
                    )
                    "audio_control" -> AudioControl(
                        audioEnabled = obj.optBoolean("audio_enabled", true),
                        muteHost = obj.optBoolean("mute_host", false)
                    )
                    "resize_window" -> ResizeWindow(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        width = obj.optDouble("width", 0.0).toFloat(),
                        height = obj.optDouble("height", 0.0).toFloat()
                    )
                    "mouse" -> Mouse(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        x = obj.optDouble("x", 0.0).toFloat(),
                        y = obj.optDouble("y", 0.0).toFloat(),
                        eventType = obj.optInt("event_type", 0),
                        button = obj.optInt("button", 0),
                        clickCount = obj.optInt("click_count", 1),
                        modifiers = obj.optInt("modifiers", 0)
                    )
                    "scroll" -> Scroll(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        x = obj.optDouble("x", 0.0).toFloat(),
                        y = obj.optDouble("y", 0.0).toFloat(),
                        deltaX = obj.optDouble("delta_x", 0.0).toFloat(),
                        deltaY = obj.optDouble("delta_y", 0.0).toFloat(),
                        isContinuous = obj.optBoolean("is_continuous", true),
                        modifiers = obj.optInt("modifiers", 0)
                    )
                    "key" -> Key(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        keyCode = obj.optInt("key_code", 0),
                        isDown = obj.optBoolean("is_down", true),
                        isRepeat = obj.optBoolean("is_repeat", false),
                        modifiers = obj.optInt("modifiers", 0)
                    )
                    "text_commit" -> TextCommit(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        text = obj.optString("text", "")
                    )
                    "window_topology" -> {
                        val arr = obj.optJSONArray("windows") ?: JSONArray()
                        val list = buildList {
                            for (i in 0 until arr.length()) {
                                arr.optJSONObject(i)?.let { add(WindowTopologyItem.fromJson(it)) }
                            }
                        }
                        WindowTopology(list)
                    }
                    "link_quality" -> LinkQuality(
                        linkMode = obj.optString("link_mode", "lan"),
                        rttMs = obj.optInt("rtt_ms", 0),
                        remoteAddr = obj.optString("remote_addr", "")
                    )
                    "cursor" -> Cursor(
                        kind = obj.optString("kind", "arrow"),
                        hotspotX = obj.optDouble("hotspot_x", 0.0).toFloat(),
                        hotspotY = obj.optDouble("hotspot_y", 0.0).toFloat()
                    )
                    "clipboard_sync" -> ClipboardSync(
                        contentHash = obj.optString("content_hash", ""),
                        clipKind = obj.optInt("clip_kind", 0),
                        text = obj.optString("text", ""),
                        mimeType = obj.optString("mime_type", ""),
                        imageB64 = obj.optString("image_b64", "")
                    )
                    "notification" -> Notification(
                        appBundleId = obj.optString("app_bundle_id", ""),
                        title = obj.optString("title", ""),
                        subtitle = obj.optString("subtitle", ""),
                        body = obj.optString("body", ""),
                        timestampMs = obj.optLong("timestamp_ms", 0L)
                    )
                    "badge_update" -> BadgeUpdate(
                        appBundleId = obj.optString("app_bundle_id", ""),
                        badgeText = obj.optString("badge_text", "")
                    )
                    "file_drop" -> FileDrop(
                        windowId = obj.optLong("window_id", 0L).toInt(),
                        x = obj.optDouble("x", 0.0).toFloat(),
                        y = obj.optDouble("y", 0.0).toFloat(),
                        blobId = obj.optString("blob_id", ""),
                        localPath = obj.optString("local_path", ""),
                        totalBytes = obj.optLong("total_bytes", 0L)
                    )
                    else -> Unknown(type)
                }
            } catch (_: Throwable) {
                Unknown("parse_error")
            }
        }
    }
}

data class LocalHostUiState(
    val isRunning: Boolean = false,
    val boundPort: Int = OpenUUConstants.DEFAULT_PORT,
    val pin: String = "",
    val hostTicket: String = "",
    val coordStatus: String = "未开启被控",
    val connectedClientName: String = "",
    val linkBadge: String = "",
    val isStreamingScreen: Boolean = false,
    val encodedFrames: Long = 0L,
    val audioCaptureActive: Boolean = false,
    val lastError: String = ""
)

package ren.onekb.openuu

import android.content.Context

interface NativeCallbackListener {
    fun onControl(json: String)
    fun onVideo(
        codec: Int,
        flags: Int,
        windowId: Int,
        timestampUs: Long,
        width: Int,
        height: Int,
        data: ByteArray
    )
    fun onStatus(msg: String)
    fun onProbeResult(json: String)
}

object OpenUUNativeBridge {
    init {
        System.loadLibrary("openuu_jni")
    }

    @JvmStatic
    external fun nativeInitAndroidContext(context: Context): Int

    @JvmStatic
    external fun nativeSetAppDirs(configDir: String?, cacheDir: String?): Int

    @JvmStatic
    external fun nativeCreateRuntime(deviceName: String, listener: NativeCallbackListener): Long

    @JvmStatic
    external fun nativeDestroyRuntime(handle: Long)

    @JvmStatic
    external fun nativeStartDiscovery(handle: Long): Int

    @JvmStatic
    external fun nativeListPeersJson(handle: Long): String

    @JvmStatic
    external fun nativeConnectSmart(
        handle: Long,
        target: String,
        defaultPort: Int,
        pin: String
    ): Int

    @JvmStatic
    external fun nativeConnectClient(
        handle: Long,
        hostIp: String,
        port: Int,
        pin: String
    ): Int

    @JvmStatic
    external fun nativeDisconnect(handle: Long)

    @JvmStatic
    external fun nativeGetIdentityJson(handle: Long): String

    @JvmStatic
    external fun nativeSetWanConfigJson(handle: Long, wanJson: String): Int

    @JvmStatic
    external fun nativeRemoveTrustedPeer(handle: Long, deviceId: String): Int

    @JvmStatic
    external fun nativeProbeDevicesOnline(handle: Long, queriesJson: String): Int

    @JvmStatic
    external fun nativeRequestAppList(handle: Long): Int

    @JvmStatic
    external fun nativeStartRemoteSession(handle: Long, bundleId: String, windowId: Int): Int

    @JvmStatic
    external fun nativeStopRemoteSession(handle: Long, windowId: Int): Int

    @JvmStatic
    external fun nativeSendMouseEvent(
        handle: Long,
        windowId: Int,
        x: Float,
        y: Float,
        eventType: Int,
        button: Int,
        clickCount: Int,
        modifiers: Int
    ): Int

    @JvmStatic
    external fun nativeSendScrollEvent(
        handle: Long,
        windowId: Int,
        x: Float,
        y: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Boolean,
        modifiers: Int
    ): Int

    @JvmStatic
    external fun nativeSendKeyEvent(
        handle: Long,
        windowId: Int,
        keyCode: Int,
        isDown: Boolean,
        isRepeat: Boolean,
        modifiers: Int
    ): Int

    @JvmStatic
    external fun nativeSendTextCommit(handle: Long, windowId: Int, utf8Text: String): Int

    @JvmStatic
    external fun nativeRequestKeyframe(handle: Long, windowId: Int): Int

    @JvmStatic
    external fun nativeSendResizeWindow(
        handle: Long,
        windowId: Int,
        width: Float,
        height: Float
    ): Int

    @JvmStatic
    external fun nativeSendClipboardText(
        handle: Long,
        contentHash: String,
        utf8Text: String
    ): Int

    @JvmStatic
    external fun nativeSendClipboardImage(
        handle: Long,
        contentHash: String,
        mimeType: String,
        imageData: ByteArray
    ): Int

    @JvmStatic
    external fun nativeSendFileBlob(
        handle: Long,
        windowId: Int,
        x: Float,
        y: Float,
        blobId: String,
        filename: String,
        localPath: String
    ): Int
}

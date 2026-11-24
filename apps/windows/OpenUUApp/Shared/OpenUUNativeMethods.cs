using System.Runtime.InteropServices;

namespace OpenUU.Shared;

internal static unsafe class OpenUUNativeMethods
{
    private const string CoreDll = "openuu_core";
    private const string MediaDll = "openuu_win_media";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void ControlCallback(IntPtr userCtx, IntPtr eventJsonUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void VideoCallback(
        IntPtr userCtx,
        byte codec,
        byte flags,
        uint windowId,
        ulong timestampUs,
        ushort width,
        ushort height,
        IntPtr dataPtr,
        nuint dataLen
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void StatusCallback(IntPtr userCtx, IntPtr statusUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void AudioCallback(
        IntPtr userCtx,
        byte codec,
        byte flags,
        byte channels,
        uint sampleRate,
        ulong timestampUs,
        IntPtr dataPtr,
        nuint dataLen
    );

    // ========================================================================
    // 1. openuu_core.dll (Rust Core FFI)
    // ========================================================================

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_set_app_dirs(byte* configDirUtf8, byte* cacheDirUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_runtime_create(byte* deviceNameUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_runtime_create_with_dir(byte* deviceNameUtf8, byte* configDirUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_runtime_destroy(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ushort openuu_start_host(
        IntPtr rt,
        ushort bindPort,
        byte* outPinBuf,
        nuint outPinBufLen,
        ControlCallback? onControl,
        VideoCallback? onVideo,
        StatusCallback? onStatus,
        IntPtr userCtx
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_start_discovery(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_list_peers_json(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_connect_client(
        IntPtr rt,
        byte* hostIpUtf8,
        ushort port,
        byte* pinUtf8,
        ControlCallback? onControl,
        VideoCallback? onVideo,
        StatusCallback? onStatus,
        IntPtr userCtx
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_connect_smart(
        IntPtr rt,
        byte* targetUtf8,
        ushort defaultPort,
        byte* pinUtf8,
        ControlCallback? onControl,
        VideoCallback? onVideo,
        StatusCallback? onStatus,
        IntPtr userCtx
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_get_identity_json(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_set_wan_config_json(IntPtr rt, byte* wanJsonUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_remove_trusted_peer(IntPtr rt, byte* deviceIdUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_generate_access_code([MarshalAs(UnmanagedType.I1)] bool strongAlphanumeric);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_probe_devices_online(
        IntPtr rt,
        byte* queriesJsonUtf8,
        StatusCallback? onResult,
        IntPtr userCtx
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_disconnect(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_stop_host(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_video_frame(
        IntPtr rt,
        byte codec,
        byte flags,
        uint windowId,
        ulong timestampUs,
        ushort width,
        ushort height,
        byte* data,
        nuint dataLen
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_set_audio_callback(
        IntPtr rt,
        AudioCallback? onAudio,
        IntPtr userCtx
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_audio_frame(
        IntPtr rt,
        byte codec,
        byte flags,
        byte channels,
        uint sampleRate,
        ulong timestampUs,
        byte* data,
        nuint dataLen
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_audio_control(
        IntPtr rt,
        [MarshalAs(UnmanagedType.I1)] bool enabled,
        [MarshalAs(UnmanagedType.I1)] bool muteHost
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_mouse_event(
        IntPtr rt,
        uint windowId,
        float x,
        float y,
        byte eventType,
        uint button,
        uint clickCount,
        uint modifiers
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_scroll_event(
        IntPtr rt,
        uint windowId,
        float x,
        float y,
        float deltaX,
        float deltaY,
        [MarshalAs(UnmanagedType.I1)] bool isContinuous,
        uint modifiers
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_key_event(
        IntPtr rt,
        uint windowId,
        uint keyCode,
        [MarshalAs(UnmanagedType.I1)] bool isDown,
        [MarshalAs(UnmanagedType.I1)] bool isRepeat,
        uint modifiers
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_text_commit(IntPtr rt, uint windowId, byte* utf8Text);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_request_keyframe(IntPtr rt, uint windowId);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_cursor_update(
        IntPtr rt,
        byte* kindUtf8,
        byte* pngData,
        nuint pngLen,
        float hotspotX,
        float hotspotY
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_window_topology_json(IntPtr rt, byte* windowsJsonUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_resize_window(IntPtr rt, uint windowId, float width, float height);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_clipboard_text(IntPtr rt, byte* contentHashUtf8, byte* utf8Text);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_clipboard_image(
        IntPtr rt,
        byte* contentHashUtf8,
        byte* mimeTypeUtf8,
        byte* imageData,
        nuint imageLen
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_notification(
        IntPtr rt,
        byte* appBundleIdUtf8,
        byte* titleUtf8,
        byte* subtitleUtf8,
        byte* bodyUtf8,
        ulong timestampMs
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_badge_update(IntPtr rt, byte* appBundleIdUtf8, byte* badgeTextUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_file_blob(
        IntPtr rt,
        uint windowId,
        float x,
        float y,
        byte* blobIdUtf8,
        byte* filenameUtf8,
        byte* localPathUtf8
    );

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_cancel_file_blob(byte* blobIdUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_request_app_list(IntPtr rt);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_send_app_list_json(IntPtr rt, byte* appsJsonUtf8);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_start_remote_session(IntPtr rt, byte* bundleIdUtf8, uint windowId);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_stop_remote_session(IntPtr rt, uint windowId);

    [DllImport(CoreDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_free_string(IntPtr ptr);

    // ========================================================================
    // 2. openuu_win_media.dll (Native Media Foundation & Capture Helper)
    // ========================================================================

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_media_startup();

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_encoder_create(
        int width,
        int height,
        int fps,
        int bitrateBps,
        byte preferredCodec,
        out byte outActualCodec,
        out byte outIsHw
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_encoder_destroy(IntPtr enc);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_encoder_force_keyframe(IntPtr enc);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_encoder_set_bitrate(IntPtr enc, int bitrateBps, int fps);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_encoder_encode_bgra(
        IntPtr enc,
        byte* bgraData,
        int bgraStride,
        ulong timestampUs,
        byte* outBuf,
        int outBufCapacity,
        out byte outIsKeyframe
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_decoder_create(byte codec);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_decoder_destroy(IntPtr dec);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_decoder_decode_annexb(
        IntPtr dec,
        byte* annexbData,
        int annexbLen,
        ulong timestampUs,
        byte* outBgra,
        int outBgraStride,
        int outCapacity,
        out int outWidth,
        out int outHeight
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_decoder_copy_last_bgra(
        IntPtr dec,
        byte* outBgra,
        int outBgraStride,
        int outCapacity
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_capture_hwnd_bgra(
        IntPtr hwnd,
        int dstWidth,
        int dstHeight,
        byte* outBgra,
        int outStride,
        out ulong outFrameHash
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_dxgi_capturer_create(out int outScreenW, out int outScreenH);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_dxgi_capturer_destroy(IntPtr cap);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_dxgi_capturer_grab_bgra(
        IntPtr cap,
        int dstWidth,
        int dstHeight,
        byte* outBgra,
        int outStride,
        out ulong outFrameHash
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_aac_encoder_create(int sampleRate, int channels, int bitrateBps);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_aac_encoder_destroy(IntPtr enc);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_aac_encoder_encode_pcm16(
        IntPtr enc,
        short* pcmSamples,
        int frameCount,
        ulong timestampUs,
        byte* outAac,
        int outCapacity
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_aac_decoder_create(int sampleRate, int channels);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_aac_decoder_destroy(IntPtr dec);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_aac_decoder_decode_pcm16(
        IntPtr dec,
        byte* aacData,
        int aacLen,
        ulong timestampUs,
        short* outPcm16,
        int maxSamples
    );

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_wasapi_loopback_create(byte muteHostSpeakers);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_wasapi_loopback_set_mute_host(IntPtr cap, byte muteHostSpeakers);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_wasapi_loopback_read_pcm16(IntPtr cap, short* outPcm16, int maxFrames);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_wasapi_loopback_destroy(IntPtr cap);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr openuu_waveout_create(int sampleRate, int channels);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int openuu_waveout_submit_pcm16(IntPtr player, short* pcmSamples, int sampleCount);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_waveout_reset(IntPtr player);

    [DllImport(MediaDll, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void openuu_waveout_destroy(IntPtr player);
}

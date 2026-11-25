#ifndef OPENUU_CORE_H
#define OPENUU_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpenUURuntime OpenUURuntime;

/// Callback invoked when a control message arrives (serialized as UTF-8 JSON for easy Swift Codable decoding).
typedef void (*OpenUUControlCallback)(void *user_ctx, const char *event_json);

/// Callback invoked when a hardware-encoded video frame arrives.
/// Pointer `data` is only valid during the callback; copy or wrap immediately.
typedef void (*OpenUUVideoCallback)(
    void *user_ctx,
    uint8_t codec,
    uint8_t flags,
    uint32_t window_id,
    uint64_t timestamp_us,
    uint16_t width,
    uint16_t height,
    const uint8_t *data,
    size_t data_len
);

/// Callback invoked on connection state changes (UTF-8 status message).
typedef void (*OpenUUStatusCallback)(void *user_ctx, const char *status);

/// Callback invoked when an encoded audio frame arrives (`StreamType::Audio` = 0x02).
/// `codec`: 1 = PCM S16LE, 2 = Opus, 3 = AAC-LC.
/// Pointer `data` is only valid during the callback; copy immediately.
typedef void (*OpenUUAudioCallback)(
    void *user_ctx,
    uint8_t codec,
    uint8_t flags,
    uint8_t channels,
    uint32_t sample_rate,
    uint64_t timestamp_us,
    const uint8_t *data,
    size_t data_len
);

/// Initialize Android TLS certificate verification (`rustls-platform-verifier`) with JNIEnv* and Android Context.
/// Must be called before any TLS / HTTPS / Iroh WAN calls on Android. No-op (returns 0) on non-Android platforms.
int32_t openuu_init_android_tls(void *jni_env, void *app_context);

/// Configure process-wide config and cache directories (recommended on iOS/Android sandboxes).
/// Passing NULL or empty string clears the respective override. Returns 0 on success.
int32_t openuu_set_app_dirs(const char *config_dir, const char *cache_dir);

OpenUURuntime *openuu_runtime_create(const char *device_name);

/// Create a OpenUURuntime using an explicit `config_dir` for `identity.json` (falls back to default if NULL/empty).
OpenUURuntime *openuu_runtime_create_with_dir(const char *device_name, const char *config_dir);

void openuu_runtime_destroy(OpenUURuntime *rt);

/// Start Host QUIC server + mDNS advertisement.
/// Returns the bound UDP port (>0) on success, or 0 on failure.
/// Writes the 6-digit pairing PIN into `out_pin_buf` (must be >= 7 bytes).
uint16_t openuu_start_host(
    OpenUURuntime *rt,
    uint16_t bind_port,
    char *out_pin_buf,
    size_t out_pin_buf_len,
    OpenUUControlCallback on_control,
    OpenUUVideoCallback on_video,
    OpenUUStatusCallback on_status,
    void *user_ctx
);

/// Start browsing for OpenUU Hosts on the LAN via mDNS.
int32_t openuu_start_discovery(OpenUURuntime *rt);

/// Returns a newly allocated JSON array of discovered peers. Caller must free with `openuu_free_string`.
char *openuu_list_peers_json(OpenUURuntime *rt);

/// Connect as Client to a Host at `host_ip:port` using `pin`. Returns 0 on success.
int32_t openuu_connect_client(
    OpenUURuntime *rt,
    const char *host_ip,
    uint16_t port,
    const char *pin,
    OpenUUControlCallback on_control,
    OpenUUVideoCallback on_video,
    OpenUUStatusCallback on_status,
    void *user_ctx
);

/// Smart 5-layer cascading connect: accepts a 9-digit device code ("839 201 475"), a `openuu://` ticket,
/// a TrustedPeer `device_id`/`endpoint_id`, or `host[:port]` (IPv4 / IPv6 / DDNS domain).
/// Automatically cascades: LAN mDNS -> Global IPv6 / STUN P2P -> Self-hosted HK Relay -> Public n0 Fallback.
int32_t openuu_connect_smart(
    OpenUURuntime *rt,
    const char *target,
    uint16_t default_port,
    const char *pin,
    OpenUUControlCallback on_control,
    OpenUUVideoCallback on_video,
    OpenUUStatusCallback on_status,
    void *user_ctx
);

/// Returns JSON snapshot of local identity, 9-digit device code, live `openuu://` ticket, WAN config, and trusted peers.
/// Caller must free with `openuu_free_string`.
char *openuu_get_identity_json(OpenUURuntime *rt);

/// Updates and persists WAN configuration (`coord_url`, `relay_url`, `enable_public_fallback`, `allow_insecure_tls`).
int32_t openuu_set_wan_config_json(OpenUURuntime *rt, const char *wan_json);

/// Removes a trusted peer by `device_id` (revoking passwordless reconnect). Returns 0 if removed.
int32_t openuu_remove_trusted_peer(OpenUURuntime *rt, const char *device_id);

/// Generates a fresh pairing code (6-digit numeric if `strong_alphanumeric == false`, 8-char alphanumeric if `true`).
/// Caller must free with `openuu_free_string`.
char *openuu_generate_access_code(bool strong_alphanumeric);

/// Asynchronously probes online status of saved devices (`[{"id":"...","target":"..."}]`).
/// Invokes `on_result(user_ctx, results_json)` when finished.
int32_t openuu_probe_devices_online(
    OpenUURuntime *rt,
    const char *queries_json,
    OpenUUStatusCallback on_result,
    void *user_ctx
);

/// Disconnect current active session (Host client or Client connection).
void openuu_disconnect(OpenUURuntime *rt);

/// Stop Host QUIC server, unregister mDNS, and disconnect any connected client.
void openuu_stop_host(OpenUURuntime *rt);

/// Send a video frame (Host -> Client). Returns 0 on success.
int32_t openuu_send_video_frame(
    OpenUURuntime *rt,
    uint8_t codec,
    uint8_t flags,
    uint32_t window_id,
    uint64_t timestamp_us,
    uint16_t width,
    uint16_t height,
    const uint8_t *data,
    size_t data_len
);

/// Register (or clear with NULL) a callback for incoming audio frames (`StreamType::Audio`).
int32_t openuu_set_audio_callback(
    OpenUURuntime *rt,
    OpenUUAudioCallback on_audio,
    void *user_ctx
);

/// Send an encoded audio frame (Host -> Client). Returns 0 on success.
int32_t openuu_send_audio_frame(
    OpenUURuntime *rt,
    uint8_t codec,
    uint8_t flags,
    uint8_t channels,
    uint32_t sample_rate,
    uint64_t timestamp_us,
    const uint8_t *data,
    size_t data_len
);

/// Send remote audio enable & host-speaker-mute preference (Client -> Host).
int32_t openuu_send_audio_control(
    OpenUURuntime *rt,
    bool enabled,
    bool mute_host
);

/// Send a mouse event (Client -> Host). event_type: 0=Move, 1=Down, 2=Up, 3=Drag.
int32_t openuu_send_mouse_event(
    OpenUURuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    uint8_t event_type,
    uint32_t button,
    uint32_t click_count,
    uint32_t modifiers
);

/// Send a scroll event (Client -> Host).
int32_t openuu_send_scroll_event(
    OpenUURuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    float delta_x,
    float delta_y,
    bool is_continuous,
    uint32_t modifiers
);

/// Send a keyboard event (Client -> Host).
int32_t openuu_send_key_event(
    OpenUURuntime *rt,
    uint32_t window_id,
    uint32_t key_code,
    bool is_down,
    bool is_repeat,
    uint32_t modifiers
);

/// Send composed UTF-8 text from local IME (Client -> Host).
int32_t openuu_send_text_commit(
    OpenUURuntime *rt,
    uint32_t window_id,
    const char *utf8_text
);

/// Send a request for a keyframe (Client -> Host).
int32_t openuu_request_keyframe(OpenUURuntime *rt, uint32_t window_id);

/// Send cursor shape update (Host -> Client).
int32_t openuu_send_cursor_update(
    OpenUURuntime *rt,
    const char *kind,
    const uint8_t *png_data,
    size_t png_len,
    float hotspot_x,
    float hotspot_y
);

/// Send active window topology list as JSON array (Host -> Client).
/// Format: [{"window_id":123,"title":"WeChat","width":900,"height":600,"kind":0}]
int32_t openuu_send_window_topology_json(
    OpenUURuntime *rt,
    const char *windows_json
);

/// Request Host to resize a specific remote window to logical `(width, height)` (Client -> Host).
int32_t openuu_send_resize_window(
    OpenUURuntime *rt,
    uint32_t window_id,
    float width,
    float height
);

/// Send UTF-8 clipboard text to peer (bidirectional).
int32_t openuu_send_clipboard_text(
    OpenUURuntime *rt,
    const char *content_hash,
    const char *utf8_text
);

/// Send clipboard image bytes (PNG/JPEG) to peer (bidirectional).
int32_t openuu_send_clipboard_image(
    OpenUURuntime *rt,
    const char *content_hash,
    const char *mime_type,
    const uint8_t *image_data,
    size_t image_len
);

/// Forward a remote app notification banner (Host -> Client).
int32_t openuu_send_notification(
    OpenUURuntime *rt,
    const char *app_bundle_id,
    const char *title,
    const char *subtitle,
    const char *body,
    uint64_t timestamp_ms
);

/// Forward a remote app Dock unread badge update (Host -> Client).
int32_t openuu_send_badge_update(
    OpenUURuntime *rt,
    const char *app_bundle_id,
    const char *badge_text
);

/// Stream a local file over a dedicated QUIC Blob Stream (0x03) to drop into a remote window (Client -> Host).
int32_t openuu_send_file_blob(
    OpenUURuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    const char *blob_id,
    const char *filename,
    const char *local_path
);

/// Cancel an in-flight incoming QUIC Blob Stream by its blob_id (aborts QUIC stream and cleans partial file).
int32_t openuu_cancel_file_blob(const char *blob_id);

/// Request list of running apps/windows from Host (Client -> Host).
int32_t openuu_request_app_list(OpenUURuntime *rt);

/// Send list of running apps/windows as JSON array (Host -> Client).
/// Format: [{"bundle_id":"com.tencent.xinWeChat","name":"WeChat","pid":123,"window_count":1}]
int32_t openuu_send_app_list_json(
    OpenUURuntime *rt,
    const char *apps_json
);

/// Request Host to start streaming a specific app/window (Client -> Host).
int32_t openuu_start_remote_session(
    OpenUURuntime *rt,
    const char *bundle_id,
    uint32_t window_id
);

/// Request Host to stop streaming a specific window (Client -> Host).
int32_t openuu_stop_remote_session(
    OpenUURuntime *rt,
    uint32_t window_id
);

/// Returns the compiled OpenUU Core semantic version string (e.g. "0.7.0").
/// Caller must free with `openuu_free_string`.
char *openuu_get_core_version(void);

/// Asynchronously checks for a newer OpenUU release (via Coord edge mirror + GitHub Releases fallback)
/// and invokes `on_result(user_ctx, update_json)` with `UpdateCheckResult` JSON.
int32_t openuu_check_update(
    OpenUURuntime *rt,
    const char *current_version,
    const char *platform,
    const char *arch,
    OpenUUStatusCallback on_result,
    void *user_ctx
);

/// Free strings returned by OpenUU FFI functions.
void openuu_free_string(char *ptr);

/// Pair with Android 11+ built-in Wireless Debugging (`adb pair`) on `host:pairing_port` using `pairing_code`.
/// Returns newly allocated JSON `{"ok":bool,"guid":"...","error":"..."}`; free with `openuu_free_string`.
char *openuu_adb_pair_json(
    const char *host,
    uint16_t pairing_port,
    const char *pairing_code
);

/// Connect to paired Wireless Debugging (`STLS` or plain TCP ADB) on `host:connect_port` and execute `shell_cmd`.
/// Returns newly allocated JSON `{"ok":bool,"output":"...","error":"..."}`; free with `openuu_free_string`.
char *openuu_adb_exec_shell_json(
    const char *host,
    uint16_t connect_port,
    const char *shell_cmd
);

#ifdef __cplusplus
}
#endif

#endif // OPENUU_CORE_H

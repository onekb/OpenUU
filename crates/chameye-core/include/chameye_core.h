#ifndef CHAMEYE_CORE_H
#define CHAMEYE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ChameyeRuntime ChameyeRuntime;

/// Callback invoked when a control message arrives (serialized as UTF-8 JSON for easy Swift Codable decoding).
typedef void (*ChameyeControlCallback)(void *user_ctx, const char *event_json);

/// Callback invoked when a hardware-encoded video frame arrives.
/// Pointer `data` is only valid during the callback; copy or wrap immediately.
typedef void (*ChameyeVideoCallback)(
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
typedef void (*ChameyeStatusCallback)(void *user_ctx, const char *status);

ChameyeRuntime *chameye_runtime_create(const char *device_name);
void chameye_runtime_destroy(ChameyeRuntime *rt);

/// Start Host QUIC server + mDNS advertisement.
/// Returns the bound UDP port (>0) on success, or 0 on failure.
/// Writes the 6-digit pairing PIN into `out_pin_buf` (must be >= 7 bytes).
uint16_t chameye_start_host(
    ChameyeRuntime *rt,
    uint16_t bind_port,
    char *out_pin_buf,
    size_t out_pin_buf_len,
    ChameyeControlCallback on_control,
    ChameyeVideoCallback on_video,
    ChameyeStatusCallback on_status,
    void *user_ctx
);

/// Start browsing for Chameye Hosts on the LAN via mDNS.
int32_t chameye_start_discovery(ChameyeRuntime *rt);

/// Returns a newly allocated JSON array of discovered peers. Caller must free with `chameye_free_string`.
char *chameye_list_peers_json(ChameyeRuntime *rt);

/// Connect as Client to a Host at `host_ip:port` using `pin`. Returns 0 on success.
int32_t chameye_connect_client(
    ChameyeRuntime *rt,
    const char *host_ip,
    uint16_t port,
    const char *pin,
    ChameyeControlCallback on_control,
    ChameyeVideoCallback on_video,
    ChameyeStatusCallback on_status,
    void *user_ctx
);

/// Disconnect current active session (Host client or Client connection).
void chameye_disconnect(ChameyeRuntime *rt);

/// Stop Host QUIC server, unregister mDNS, and disconnect any connected client.
void chameye_stop_host(ChameyeRuntime *rt);

/// Send a video frame (Host -> Client). Returns 0 on success.
int32_t chameye_send_video_frame(
    ChameyeRuntime *rt,
    uint8_t codec,
    uint8_t flags,
    uint32_t window_id,
    uint64_t timestamp_us,
    uint16_t width,
    uint16_t height,
    const uint8_t *data,
    size_t data_len
);

/// Send a mouse event (Client -> Host). event_type: 0=Move, 1=Down, 2=Up, 3=Drag.
int32_t chameye_send_mouse_event(
    ChameyeRuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    uint8_t event_type,
    uint32_t button,
    uint32_t click_count,
    uint32_t modifiers
);

/// Send a scroll event (Client -> Host).
int32_t chameye_send_scroll_event(
    ChameyeRuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    float delta_x,
    float delta_y,
    bool is_continuous,
    uint32_t modifiers
);

/// Send a keyboard event (Client -> Host).
int32_t chameye_send_key_event(
    ChameyeRuntime *rt,
    uint32_t window_id,
    uint32_t key_code,
    bool is_down,
    bool is_repeat,
    uint32_t modifiers
);

/// Send composed UTF-8 text from local IME (Client -> Host).
int32_t chameye_send_text_commit(
    ChameyeRuntime *rt,
    uint32_t window_id,
    const char *utf8_text
);

/// Send a request for a keyframe (Client -> Host).
int32_t chameye_request_keyframe(ChameyeRuntime *rt, uint32_t window_id);

/// Send cursor shape update (Host -> Client).
int32_t chameye_send_cursor_update(
    ChameyeRuntime *rt,
    const char *kind,
    const uint8_t *png_data,
    size_t png_len,
    float hotspot_x,
    float hotspot_y
);

/// Send active window topology list as JSON array (Host -> Client).
/// Format: [{"window_id":123,"title":"WeChat","width":900,"height":600,"kind":0}]
int32_t chameye_send_window_topology_json(
    ChameyeRuntime *rt,
    const char *windows_json
);

/// Request Host to resize a specific remote window to logical `(width, height)` (Client -> Host).
int32_t chameye_send_resize_window(
    ChameyeRuntime *rt,
    uint32_t window_id,
    float width,
    float height
);

/// Send UTF-8 clipboard text to peer (bidirectional).
int32_t chameye_send_clipboard_text(
    ChameyeRuntime *rt,
    const char *content_hash,
    const char *utf8_text
);

/// Send clipboard image bytes (PNG/JPEG) to peer (bidirectional).
int32_t chameye_send_clipboard_image(
    ChameyeRuntime *rt,
    const char *content_hash,
    const char *mime_type,
    const uint8_t *image_data,
    size_t image_len
);

/// Forward a remote app notification banner (Host -> Client).
int32_t chameye_send_notification(
    ChameyeRuntime *rt,
    const char *app_bundle_id,
    const char *title,
    const char *subtitle,
    const char *body,
    uint64_t timestamp_ms
);

/// Forward a remote app Dock unread badge update (Host -> Client).
int32_t chameye_send_badge_update(
    ChameyeRuntime *rt,
    const char *app_bundle_id,
    const char *badge_text
);

/// Stream a local file over a dedicated QUIC Blob Stream (0x03) to drop into a remote window (Client -> Host).
int32_t chameye_send_file_blob(
    ChameyeRuntime *rt,
    uint32_t window_id,
    float x,
    float y,
    const char *blob_id,
    const char *filename,
    const char *local_path
);

/// Request list of running apps/windows from Host (Client -> Host).
int32_t chameye_request_app_list(ChameyeRuntime *rt);

/// Send list of running apps/windows as JSON array (Host -> Client).
/// Format: [{"bundle_id":"com.tencent.xinWeChat","name":"WeChat","pid":123,"window_count":1}]
int32_t chameye_send_app_list_json(
    ChameyeRuntime *rt,
    const char *apps_json
);

/// Request Host to start streaming a specific app/window (Client -> Host).
int32_t chameye_start_remote_session(
    ChameyeRuntime *rt,
    const char *bundle_id,
    uint32_t window_id
);

/// Request Host to stop streaming a specific window (Client -> Host).
int32_t chameye_stop_remote_session(
    ChameyeRuntime *rt,
    uint32_t window_id
);

/// Free strings returned by Chameye FFI functions.
void chameye_free_string(char *ptr);

#ifdef __cplusplus
}
#endif

#endif // CHAMEYE_CORE_H

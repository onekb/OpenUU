#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#define OPENUU_MEDIA_API __declspec(dllexport)
#else
#define OPENUU_MEDIA_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OpenUUWinEncoder OpenUUWinEncoder;
typedef struct OpenUUWinDecoder OpenUUWinDecoder;
typedef struct OpenUUDxgiCapturer OpenUUDxgiCapturer;
typedef struct OpenUUWinAacEncoder OpenUUWinAacEncoder;
typedef struct OpenUUWinAacDecoder OpenUUWinAacDecoder;
typedef struct OpenUUWasapiLoopback OpenUUWasapiLoopback;
typedef struct OpenUUWaveOutPlayer OpenUUWaveOutPlayer;

/// Initialize Media Foundation for the current process. Safe to call multiple times.
OPENUU_MEDIA_API int32_t openuu_media_startup(void);

/// Create a low-latency H.264 (codec=1) or HEVC (codec=2, auto-falls back to H.264 if unavailable) encoder.
/// Writes the actual negotiated codec (1=H.264, 2=HEVC) into `*out_actual_codec` and hardware flag into `*out_is_hw`.
OPENUU_MEDIA_API OpenUUWinEncoder *openuu_encoder_create(
    int32_t width,
    int32_t height,
    int32_t fps,
    int32_t bitrate_bps,
    uint8_t preferred_codec,
    uint8_t *out_actual_codec,
    uint8_t *out_is_hw
);

OPENUU_MEDIA_API void openuu_encoder_destroy(OpenUUWinEncoder *enc);

OPENUU_MEDIA_API void openuu_encoder_force_keyframe(OpenUUWinEncoder *enc);

OPENUU_MEDIA_API int32_t openuu_encoder_set_bitrate(OpenUUWinEncoder *enc, int32_t bitrate_bps, int32_t fps);

/// Encode a top-down BGRA32 frame into Annex-B NALUs.
/// Returns number of bytes written to `out_buf` (>0 if a frame was emitted, 0 if no output, <0 on error).
/// Sets `*out_is_keyframe = 1` when the emitted Annex-B packet is an IDR keyframe (with SPS/PPS prepended).
OPENUU_MEDIA_API int32_t openuu_encoder_encode_bgra(
    OpenUUWinEncoder *enc,
    const uint8_t *bgra_data,
    int32_t bgra_stride,
    uint64_t timestamp_us,
    uint8_t *out_buf,
    int32_t out_buf_capacity,
    uint8_t *out_is_keyframe
);

/// Create a low-latency Annex-B H.264 (codec=1) or HEVC (codec=2) decoder.
OPENUU_MEDIA_API OpenUUWinDecoder *openuu_decoder_create(uint8_t codec);

OPENUU_MEDIA_API void openuu_decoder_destroy(OpenUUWinDecoder *dec);

/// Feed an Annex-B packet into the decoder and convert the latest decoded frame to top-down BGRA32.
/// If `out_bgra` is NULL or `out_capacity` is smaller than `width * height * 4`, still decodes and populates
/// `*out_width` and `*out_height` and returns 2 (caller should allocate/resize buffer and call `openuu_decoder_read_bgra`).
/// Returns:
///   1 = frame decoded and written to `out_bgra`
///   2 = frame decoded, buffer resize needed (`*out_width` / `*out_height` updated)
///   0 = packet accepted, more data needed (e.g. parameter sets only)
///  <0 = decode error
OPENUU_MEDIA_API int32_t openuu_decoder_decode_annexb(
    OpenUUWinDecoder *dec,
    const uint8_t *annexb_data,
    int32_t annexb_len,
    uint64_t timestamp_us,
    uint8_t *out_bgra,
    int32_t out_bgra_stride,
    int32_t out_capacity,
    int32_t *out_width,
    int32_t *out_height
);

/// Copy the most recently decoded NV12 frame into `out_bgra` (used right after `openuu_decoder_decode_annexb` returns 2).
OPENUU_MEDIA_API int32_t openuu_decoder_copy_last_bgra(
    OpenUUWinDecoder *dec,
    uint8_t *out_bgra,
    int32_t out_bgra_stride,
    int32_t out_capacity
);

/// Capture a single Win32 HWND's private DWM surface (`PrintWindow` with `PW_RENDERFULLCONTENT`) scaled into
/// an even-sized `dst_width x dst_height` top-down BGRA32 buffer, computing a fast pixel-change hash.
/// Returns 1 on success, 0 if window invalid/minimized, <0 on error.
OPENUU_MEDIA_API int32_t openuu_capture_hwnd_bgra(
    void *hwnd,
    int32_t dst_width,
    int32_t dst_height,
    uint8_t *out_bgra,
    int32_t out_stride,
    uint64_t *out_frame_hash
);

/// Create a DXGI Desktop Duplication capturer (with automatic GDI BitBlt fallback) for the primary monitor.
OPENUU_MEDIA_API OpenUUDxgiCapturer *openuu_dxgi_capturer_create(int32_t *out_screen_w, int32_t *out_screen_h);

OPENUU_MEDIA_API void openuu_dxgi_capturer_destroy(OpenUUDxgiCapturer *cap);

/// Capture the desktop scaled into `dst_width x dst_height` top-down BGRA32.
/// Returns 1 on frame captured, 0 on unchanged/timeout, <0 on error.
OPENUU_MEDIA_API int32_t openuu_dxgi_capturer_grab_bgra(
    OpenUUDxgiCapturer *cap,
    int32_t dst_width,
    int32_t dst_height,
    uint8_t *out_bgra,
    int32_t out_stride,
    uint64_t *out_frame_hash
);

// ============================================================================
// Remote Audio (AAC-LC Codec + WASAPI Loopback + Host Auto-Mute + WaveOut)
// ============================================================================

OPENUU_MEDIA_API OpenUUWinAacEncoder *openuu_aac_encoder_create(
    int32_t sample_rate,
    int32_t channels,
    int32_t bitrate_bps
);

OPENUU_MEDIA_API void openuu_aac_encoder_destroy(OpenUUWinAacEncoder *enc);

/// Encode interleaved S16LE PCM frames (`frame_count` frames, typically 1024) into raw AAC-LC access unit (no ADTS).
/// Returns bytes written (>0), 0 if buffered, <0 on error.
OPENUU_MEDIA_API int32_t openuu_aac_encoder_encode_pcm16(
    OpenUUWinAacEncoder *enc,
    const int16_t *pcm_samples,
    int32_t frame_count,
    uint64_t timestamp_us,
    uint8_t *out_aac,
    int32_t out_capacity
);

OPENUU_MEDIA_API OpenUUWinAacDecoder *openuu_aac_decoder_create(
    int32_t sample_rate,
    int32_t channels
);

OPENUU_MEDIA_API void openuu_aac_decoder_destroy(OpenUUWinAacDecoder *dec);

/// Decode a raw AAC-LC access unit into interleaved S16LE PCM samples.
/// Returns total `int16_t` samples written (`frames * channels`), 0 if buffered, <0 on error.
OPENUU_MEDIA_API int32_t openuu_aac_decoder_decode_pcm16(
    OpenUUWinAacDecoder *dec,
    const uint8_t *aac_data,
    int32_t aac_len,
    uint64_t timestamp_us,
    int16_t *out_pcm16,
    int32_t max_samples
);

/// Start 48,000 Hz stereo S16LE WASAPI loopback capture on the default output endpoint,
/// optionally muting the Host's physical speakers while preserving loopback audio capture.
OPENUU_MEDIA_API OpenUUWasapiLoopback *openuu_wasapi_loopback_create(uint8_t mute_host_speakers);

OPENUU_MEDIA_API void openuu_wasapi_loopback_set_mute_host(
    OpenUUWasapiLoopback *cap,
    uint8_t mute_host_speakers
);

/// Drain up to `max_frames` stereo frames (each frame = 2 x int16_t) into `out_pcm16`.
/// Returns number of stereo frames read (>=0), or <0 if endpoint invalidated.
OPENUU_MEDIA_API int32_t openuu_wasapi_loopback_read_pcm16(
    OpenUUWasapiLoopback *cap,
    int16_t *out_pcm16,
    int32_t max_frames
);

OPENUU_MEDIA_API void openuu_wasapi_loopback_destroy(OpenUUWasapiLoopback *cap);

OPENUU_MEDIA_API OpenUUWaveOutPlayer *openuu_waveout_create(int32_t sample_rate, int32_t channels);

OPENUU_MEDIA_API int32_t openuu_waveout_submit_pcm16(
    OpenUUWaveOutPlayer *player,
    const int16_t *pcm_samples,
    int32_t sample_count
);

OPENUU_MEDIA_API void openuu_waveout_reset(OpenUUWaveOutPlayer *player);

OPENUU_MEDIA_API void openuu_waveout_destroy(OpenUUWaveOutPlayer *player);

#ifdef __cplusplus
}
#endif

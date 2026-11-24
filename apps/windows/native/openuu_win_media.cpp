#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <mmsystem.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <endpointvolume.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <objbase.h>
#include <wrl/client.h>

#include <initguid.h>
#include <mfapi.h>
#include <mfidl.h>
#include <mftransform.h>
#include <mferror.h>
#include <codecapi.h>
#include <wmcodecdsp.h>

#include "openuu_win_media.h"

#include <algorithm>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <vector>

// MF_LOW_LATENCY {9C27891A-ED7A-40E1-88E8-B22727A024EE}
static const GUID kOpenUUMfLowLatency =
    {0x9c27891a, 0xed7a, 0x40e1, {0x88, 0xe8, 0xb2, 0x27, 0x27, 0xa0, 0x24, 0xee}};

using Microsoft::WRL::ComPtr;

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

namespace {

std::once_flag g_mfInitOnce;
HRESULT g_mfInitHr = E_FAIL;

void ensure_mf_started() {
    // CoInitializeEx is per-thread on Windows: every LongRunning capture/decode worker thread MUST initialize COM!
    CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    std::call_once(g_mfInitOnce, []() {
        g_mfInitHr = MFStartup(MF_VERSION, MFSTARTUP_NOSOCKET);
    });
}

inline uint8_t clamp_u8(int v) {
    return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
}

uint64_t compute_bgra_fast_hash(const uint8_t *bgra, int width, int height, int stride) {
    if (!bgra || width <= 0 || height <= 0) return 0;
    uint64_t hash = 14695981039346656037ULL;
    const int stepY = std::max(1, height / 48);
    const int stepX = std::max(1, width / 64);
    for (int y = 0; y < height; y += stepY) {
        const uint32_t *row = reinterpret_cast<const uint32_t *>(bgra + static_cast<size_t>(y) * stride);
        for (int x = 0; x < width; x += stepX) {
            uint32_t px = row[x] & 0x00FFFFFFu;
            hash ^= static_cast<uint64_t>(px);
            hash *= 1099511628211ULL;
        }
    }
    hash ^= (static_cast<uint64_t>(width) << 32) | static_cast<uint64_t>(height);
    return hash;
}

void query_physical_screen_size(int32_t *out_w, int32_t *out_h) {
    int32_t w = GetSystemMetrics(SM_CXSCREEN);
    int32_t h = GetSystemMetrics(SM_CYSCREEN);
    DEVMODEW dm = {};
    dm.dmSize = sizeof(dm);
    if (EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &dm)) {
        if (dm.dmPelsWidth > 0 && dm.dmPelsHeight > 0) {
            w = static_cast<int32_t>(dm.dmPelsWidth);
            h = static_cast<int32_t>(dm.dmPelsHeight);
        }
    }
    if (out_w) *out_w = std::max(640, w);
    if (out_h) *out_h = std::max(480, h);
}

struct FilterSpan {
    int32_t start;
    int32_t count;
    uint16_t weights[6]; // Normalized so sum(weights[0..count-1]) == 256
};

void build_filter_spans(int32_t src_len, int32_t dst_len, std::vector<FilterSpan> &spans) {
    spans.resize(static_cast<size_t>(dst_len));
    if (dst_len <= 0 || src_len <= 0) return;

    if (dst_len < src_len) {
        // Exact box-area integration for downscaling: every source scanline/column contributes proportional weight,
        // guaranteeing 1px horizontal and vertical font strokes are NEVER skipped!
        for (int32_t d = 0; d < dst_len; ++d) {
            const int64_t s0_fp = (static_cast<int64_t>(d) * src_len * 256) / dst_len;
            const int64_t s1_fp = (static_cast<int64_t>(d + 1) * src_len * 256) / dst_len;
            int32_t i0 = std::clamp(static_cast<int32_t>(s0_fp >> 8), 0, src_len - 1);
            int32_t i1 = std::clamp(static_cast<int32_t>((std::max(s0_fp, s1_fp - 1)) >> 8), i0, src_len - 1);
            int32_t cnt = std::min(6, i1 - i0 + 1);

            int64_t raw[6] = {};
            int64_t rawSum = 0;
            for (int32_t k = 0; k < cnt; ++k) {
                const int64_t p0 = static_cast<int64_t>(i0 + k) * 256;
                const int64_t p1 = p0 + 256;
                const int64_t ov = std::max<int64_t>(1, std::min(s1_fp, p1) - std::max(s0_fp, p0));
                raw[k] = ov;
                rawSum += ov;
            }

            FilterSpan sp = {};
            sp.start = i0;
            sp.count = cnt;
            int32_t normSum = 0;
            for (int32_t k = 0; k < cnt; ++k) {
                uint16_t w = static_cast<uint16_t>((raw[k] * 256 + rawSum / 2) / rawSum);
                sp.weights[k] = w;
                normSum += w;
            }
            sp.weights[0] = static_cast<uint16_t>(static_cast<int32_t>(sp.weights[0]) + (256 - normSum));
            spans[static_cast<size_t>(d)] = sp;
        }
    } else {
        // Center-aligned bilinear interpolation for 1:1 or upscaling
        for (int32_t d = 0; d < dst_len; ++d) {
            int64_t fp = ((static_cast<int64_t>(d) * 2 + 1) * src_len * 128) / dst_len - 128;
            const int64_t maxFp = static_cast<int64_t>(src_len - 1) * 256;
            fp = std::clamp<int64_t>(fp, 0, maxFp);
            int32_t i0 = static_cast<int32_t>(fp >> 8);
            uint16_t frac = static_cast<uint16_t>(fp & 255);

            FilterSpan sp = {};
            sp.start = i0;
            if (frac == 0 || i0 + 1 >= src_len) {
                sp.count = 1;
                sp.weights[0] = 256;
            } else {
                sp.count = 2;
                sp.weights[0] = static_cast<uint16_t>(256 - frac);
                sp.weights[1] = frac;
            }
            spans[static_cast<size_t>(d)] = sp;
        }
    }
}

void resample_bgra_area_bilinear(
    const uint8_t *src_bgra,
    int32_t src_stride,
    int32_t src_w,
    int32_t src_h,
    uint8_t *dst_bgra,
    int32_t dst_stride,
    int32_t dst_w,
    int32_t dst_h
) {
    if (!src_bgra || !dst_bgra || src_w <= 0 || src_h <= 0 || dst_w <= 0 || dst_h <= 0) return;

    if (src_w == dst_w && src_h == dst_h) {
        const size_t rowBytes = static_cast<size_t>(dst_w) * 4;
        for (int32_t y = 0; y < dst_h; ++y) {
            uint8_t *dRow = dst_bgra + static_cast<size_t>(y) * dst_stride;
            std::memcpy(dRow, src_bgra + static_cast<size_t>(y) * src_stride, rowBytes);
            for (int32_t x = 0; x < dst_w; ++x) {
                dRow[x * 4 + 3] = 255;
            }
        }
        return;
    }

    std::vector<FilterSpan> xSpans;
    std::vector<FilterSpan> ySpans;
    build_filter_spans(src_w, dst_w, xSpans);
    build_filter_spans(src_h, dst_h, ySpans);

    // 8-slot rolling horizontal row cache (each source row is horizontally filtered at most once)
    constexpr int kCacheSlots = 8;
    const size_t hRowStride = static_cast<size_t>(dst_w) * 3;
    std::vector<uint8_t> hCacheBuf(static_cast<size_t>(kCacheSlots) * hRowStride);
    int32_t cachedSy[kCacheSlots];
    for (int i = 0; i < kCacheSlots; ++i) cachedSy[i] = -1;

    auto getHorizontalRow = [&](int32_t sy) -> const uint8_t * {
        const int slot = sy & (kCacheSlots - 1);
        uint8_t *slotPtr = hCacheBuf.data() + static_cast<size_t>(slot) * hRowStride;
        if (cachedSy[slot] == sy) {
            return slotPtr;
        }
        cachedSy[slot] = sy;
        const uint8_t *sRow = src_bgra + static_cast<size_t>(sy) * src_stride;
        for (int32_t dx = 0; dx < dst_w; ++dx) {
            const FilterSpan &xs = xSpans[static_cast<size_t>(dx)];
            uint32_t accB = 128, accG = 128, accR = 128;
            const uint8_t *p = sRow + static_cast<size_t>(xs.start) * 4;
            for (int32_t k = 0; k < xs.count; ++k) {
                const uint32_t w = xs.weights[k];
                accB += static_cast<uint32_t>(p[k * 4 + 0]) * w;
                accG += static_cast<uint32_t>(p[k * 4 + 1]) * w;
                accR += static_cast<uint32_t>(p[k * 4 + 2]) * w;
            }
            slotPtr[dx * 3 + 0] = static_cast<uint8_t>(accB >> 8);
            slotPtr[dx * 3 + 1] = static_cast<uint8_t>(accG >> 8);
            slotPtr[dx * 3 + 2] = static_cast<uint8_t>(accR >> 8);
        }
        return slotPtr;
    };

    for (int32_t dy = 0; dy < dst_h; ++dy) {
        const FilterSpan &ys = ySpans[static_cast<size_t>(dy)];
        const uint8_t *rows[6] = {};
        for (int32_t k = 0; k < ys.count; ++k) {
            rows[k] = getHorizontalRow(ys.start + k);
        }

        uint8_t *dRow = dst_bgra + static_cast<size_t>(dy) * dst_stride;
        if (ys.count == 1) {
            const uint8_t *r0 = rows[0];
            for (int32_t dx = 0; dx < dst_w; ++dx) {
                dRow[dx * 4 + 0] = r0[dx * 3 + 0];
                dRow[dx * 4 + 1] = r0[dx * 3 + 1];
                dRow[dx * 4 + 2] = r0[dx * 3 + 2];
                dRow[dx * 4 + 3] = 255;
            }
        } else {
            for (int32_t dx = 0; dx < dst_w; ++dx) {
                uint32_t accB = 128, accG = 128, accR = 128;
                const size_t off = static_cast<size_t>(dx) * 3;
                for (int32_t k = 0; k < ys.count; ++k) {
                    const uint32_t w = ys.weights[k];
                    accB += static_cast<uint32_t>(rows[k][off + 0]) * w;
                    accG += static_cast<uint32_t>(rows[k][off + 1]) * w;
                    accR += static_cast<uint32_t>(rows[k][off + 2]) * w;
                }
                dRow[dx * 4 + 0] = static_cast<uint8_t>(accB >> 8);
                dRow[dx * 4 + 1] = static_cast<uint8_t>(accG >> 8);
                dRow[dx * 4 + 2] = static_cast<uint8_t>(accR >> 8);
                dRow[dx * 4 + 3] = 255;
            }
        }
    }
}

void convert_bgra_to_nv12_bt709(
    const uint8_t *bgra,
    int bgra_stride,
    int src_width,
    int src_height,
    uint8_t *dst_y,
    int y_stride,
    uint8_t *dst_uv,
    int uv_stride,
    int enc_width,
    int enc_height
) {
    const int evenEncW = enc_width & ~1;
    const int evenEncH = enc_height & ~1;
    const int maxSrcX = std::max(0, src_width - 1);
    const int maxSrcY = std::max(0, src_height - 1);

    for (int y = 0; y < evenEncH; y += 2) {
        const int sy0 = std::min(y, maxSrcY);
        const int sy1 = std::min(y + 1, maxSrcY);
        const uint8_t *srcRow0 = bgra + static_cast<size_t>(sy0) * bgra_stride;
        const uint8_t *srcRow1 = bgra + static_cast<size_t>(sy1) * bgra_stride;
        uint8_t *yRow0 = dst_y + static_cast<size_t>(y) * y_stride;
        uint8_t *yRow1 = dst_y + static_cast<size_t>(y + 1) * y_stride;
        uint8_t *uvRow = dst_uv + static_cast<size_t>(y / 2) * uv_stride;

        for (int x = 0; x < evenEncW; x += 2) {
            const int sx0 = std::min(x, maxSrcX);
            const int sx1 = std::min(x + 1, maxSrcX);

            const int b00 = srcRow0[sx0 * 4 + 0];
            const int g00 = srcRow0[sx0 * 4 + 1];
            const int r00 = srcRow0[sx0 * 4 + 2];

            const int b01 = srcRow0[sx1 * 4 + 0];
            const int g01 = srcRow0[sx1 * 4 + 1];
            const int r01 = srcRow0[sx1 * 4 + 2];

            const int b10 = srcRow1[sx0 * 4 + 0];
            const int g10 = srcRow1[sx0 * 4 + 1];
            const int r10 = srcRow1[sx0 * 4 + 2];

            const int b11 = srcRow1[sx1 * 4 + 0];
            const int g11 = srcRow1[sx1 * 4 + 1];
            const int r11 = srcRow1[sx1 * 4 + 2];

            // BT.709 studio-range Y [16..235]
            yRow0[x + 0] = clamp_u8(((47 * r00 + 157 * g00 + 16 * b00 + 128) >> 8) + 16);
            yRow0[x + 1] = clamp_u8(((47 * r01 + 157 * g01 + 16 * b01 + 128) >> 8) + 16);
            yRow1[x + 0] = clamp_u8(((47 * r10 + 157 * g10 + 16 * b10 + 128) >> 8) + 16);
            yRow1[x + 1] = clamp_u8(((47 * r11 + 157 * g11 + 16 * b11 + 128) >> 8) + 16);

            const int rAvg = (r00 + r01 + r10 + r11 + 2) >> 2;
            const int gAvg = (g00 + g01 + g10 + g11 + 2) >> 2;
            const int bAvg = (b00 + b01 + b10 + b11 + 2) >> 2;

            // BT.709 Cb / Cr [16..240]
            uvRow[x + 0] = clamp_u8(((-26 * rAvg - 87 * gAvg + 112 * bAvg + 128) >> 8) + 128);
            uvRow[x + 1] = clamp_u8(((112 * rAvg - 102 * gAvg - 10 * bAvg + 128) >> 8) + 128);
        }
    }
}

void convert_nv12_to_bgra_bt709(
    const uint8_t *src_y,
    int y_stride,
    const uint8_t *src_uv,
    int uv_stride,
    uint8_t *dst_bgra,
    int bgra_stride,
    int width,
    int height,
    bool full_range
) {
    for (int y = 0; y < height; ++y) {
        const uint8_t *yRow = src_y + static_cast<size_t>(y) * y_stride;
        const uint8_t *uvRow = src_uv + static_cast<size_t>(y >> 1) * uv_stride;
        uint8_t *dstRow = dst_bgra + static_cast<size_t>(y) * bgra_stride;

        if (full_range) {
            for (int x = 0; x < width; ++x) {
                const int yVal = yRow[x];
                const int uvIdx = x & ~1;
                const int d = static_cast<int>(uvRow[uvIdx + 0]) - 128;
                const int e = static_cast<int>(uvRow[uvIdx + 1]) - 128;

                const int c = yVal * 256;
                dstRow[x * 4 + 0] = clamp_u8((c + 475 * d + 128) >> 8);
                dstRow[x * 4 + 1] = clamp_u8((c - 48 * d - 120 * e + 128) >> 8);
                dstRow[x * 4 + 2] = clamp_u8((c + 403 * e + 128) >> 8);
                dstRow[x * 4 + 3] = 255;
            }
        } else {
            for (int x = 0; x < width; ++x) {
                const int yVal = std::max(0, static_cast<int>(yRow[x]) - 16);
                const int uvIdx = x & ~1;
                const int d = static_cast<int>(uvRow[uvIdx + 0]) - 128;
                const int e = static_cast<int>(uvRow[uvIdx + 1]) - 128;

                const int c = yVal * 298;
                dstRow[x * 4 + 0] = clamp_u8((c + 541 * d + 128) >> 8);
                dstRow[x * 4 + 1] = clamp_u8((c - 55 * d - 136 * e + 128) >> 8);
                dstRow[x * 4 + 2] = clamp_u8((c + 459 * e + 128) >> 8);
                dstRow[x * 4 + 3] = 255;
            }
        }
    }
}

struct NaluSlice {
    size_t offset;
    size_t len;
};

std::vector<NaluSlice> split_annexb_nalus(const uint8_t *data, size_t len) {
    std::vector<NaluSlice> out;
    if (!data || len < 4) return out;
    size_t i = 0;
    size_t naluStart = SIZE_MAX;
    while (i + 2 < len) {
        if (data[i] == 0 && data[i + 1] == 0) {
            bool is4 = (i + 3 < len) && data[i + 2] == 0 && data[i + 3] == 1;
            bool is3 = !is4 && data[i + 2] == 1;
            if (is4 || is3) {
                if (naluStart != SIZE_MAX && i > naluStart) {
                    out.push_back({naluStart, i - naluStart});
                }
                i += is4 ? 4 : 3;
                naluStart = i;
                continue;
            }
        }
        ++i;
    }
    if (naluStart != SIZE_MAX && naluStart < len) {
        out.push_back({naluStart, len - naluStart});
    }
    return out;
}

void set_variant_bool_or_u32(ICodecAPI *codecApi, const GUID &guid, bool val) {
    if (!codecApi) return;
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_BOOL;
    v.boolVal = val ? VARIANT_TRUE : VARIANT_FALSE;
    if (FAILED(codecApi->SetValue(&guid, &v))) {
        VariantInit(&v);
        v.vt = VT_UI4;
        v.ulVal = val ? 1u : 0u;
        codecApi->SetValue(&guid, &v);
    }
}

void set_variant_u32(ICodecAPI *codecApi, const GUID &guid, uint32_t val) {
    if (!codecApi) return;
    VARIANT v;
    VariantInit(&v);
    v.vt = VT_UI4;
    v.ulVal = val;
    codecApi->SetValue(&guid, &v);
}

} // namespace

struct OpenUUWinEncoder {
    ComPtr<IMFTransform> mft;
    ComPtr<ICodecAPI> codecApi;
    ComPtr<IMFMediaEventGenerator> eventGen;
    bool isAsync = false;
    bool isHardware = false;
    uint8_t codec = 1; // 1 = H.264, 2 = HEVC
    int32_t srcWidth = 0;
    int32_t srcHeight = 0;
    int32_t width = 0;
    int32_t height = 0;
    int32_t fps = 30;
    int32_t bitrate = 4000000;
    DWORD inputStreamId = 0;
    DWORD outputStreamId = 0;
    bool providesOutputSamples = false;
    DWORD outputSampleSize = 0;
    bool forceNextKeyframe = true;

    std::vector<uint8_t> cachedVps;
    std::vector<uint8_t> cachedSps;
    std::vector<uint8_t> cachedPps;
    std::vector<uint8_t> nv12Scratch;
};

struct OpenUUWinDecoder {
    ComPtr<IMFTransform> mft;
    uint8_t codec = 1;
    bool inputConfigured = false;
    bool outputConfigured = false;
    int32_t frameW = 0;
    int32_t frameH = 0;
    int32_t allocW = 0;
    int32_t allocH = 0;
    int32_t defaultStride = 0;
    bool fullRange = false;
    DWORD inputStreamId = 0;
    DWORD outputStreamId = 0;
    bool providesOutputSamples = false;
    DWORD outputSampleSize = 0;

    std::vector<uint8_t> lastNv12;
    int32_t lastYStride = 0;
    int32_t lastUvStride = 0;
    size_t lastUvOffset = 0;
    uint32_t diagHrIn = 0;
    uint32_t diagHrOut = 0;
    int32_t diagCurLen = 0;
};

struct OpenUUDxgiCapturer {
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIOutputDuplication> duplication;
    ComPtr<ID3D11Texture2D> stagingTex;
    int32_t screenW = 0;
    int32_t screenH = 0;
    bool dxgiValid = false;
};

namespace {

bool try_init_encoder_mft(
    OpenUUWinEncoder *enc,
    uint8_t targetCodec,
    bool hardwareOnly
) {
    MFT_REGISTER_TYPE_INFO outInfo = {};
    outInfo.guidMajorType = MFMediaType_Video;
    outInfo.guidSubtype = (targetCodec == 2) ? MFVideoFormat_HEVC : MFVideoFormat_H264;

    UINT32 flags = hardwareOnly
        ? (MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER)
        : (MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER);

    IMFActivate **activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_ENCODER,
        flags,
        nullptr,
        &outInfo,
        &activates,
        &count
    );
    if (FAILED(hr) || count == 0 || !activates) {
        return false;
    }

    bool ok = false;
    for (UINT32 i = 0; i < count && !ok; ++i) {
        ComPtr<IMFTransform> mft;
        if (FAILED(activates[i]->ActivateObject(IID_PPV_ARGS(&mft))) || !mft) {
            continue;
        }

        bool isAsync = false;
        ComPtr<IMFAttributes> attrs;
        if (SUCCEEDED(mft->GetAttributes(&attrs)) && attrs) {
            UINT32 asyncVal = 0;
            if (SUCCEEDED(attrs->GetUINT32(MF_TRANSFORM_ASYNC, &asyncVal)) && asyncVal != 0) {
                isAsync = true;
                attrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
            }
            attrs->SetUINT32(kOpenUUMfLowLatency, TRUE);
        }

        // Async hardware MFTs require an asynchronous event-queue pump; prefer synchronous MFTs or async MFTs
        // only when they support direct IMFMediaEventGenerator non-blocking polling cleanly.
        ComPtr<IMFMediaEventGenerator> evGen;
        if (isAsync) {
            if (FAILED(mft.As(&evGen)) || !evGen) {
                activates[i]->ShutdownObject();
                continue;
            }
        }

        DWORD inCount = 0, outCount = 0;
        DWORD inId = 0, outId = 0;
        if (SUCCEEDED(mft->GetStreamCount(&inCount, &outCount)) && inCount >= 1 && outCount >= 1) {
            if (FAILED(mft->GetStreamIDs(1, &inId, 1, &outId))) {
                inId = 0;
                outId = 0;
            }
        }

        ComPtr<ICodecAPI> codecApi;
        mft->QueryInterface(IID_ICodecAPI, reinterpret_cast<void **>(codecApi.GetAddressOf()));
        if (codecApi) {
            set_variant_bool_or_u32(codecApi.Get(), CODECAPI_AVLowLatencyMode, true);
            set_variant_u32(codecApi.Get(), CODECAPI_AVEncMPVDefaultBPictureCount, 0);
            set_variant_u32(codecApi.Get(), CODECAPI_AVEncCommonQualityVsSpeed, 72);
            set_variant_u32(codecApi.Get(), CODECAPI_AVEncMPVGOPSize, static_cast<uint32_t>(std::max(24, enc->fps) * 60));
        }

        // 1. Configure Output MediaType first
        ComPtr<IMFMediaType> outType;
        if (FAILED(MFCreateMediaType(&outType))) {
            activates[i]->ShutdownObject();
            continue;
        }
        outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        outType->SetGUID(MF_MT_SUBTYPE, outInfo.guidSubtype);
        outType->SetUINT32(MF_MT_AVG_BITRATE, static_cast<UINT32>(enc->bitrate));
        outType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        outType->SetUINT32(MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709);
        outType->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
        outType->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
        MFSetAttributeSize(outType.Get(), MF_MT_FRAME_SIZE, static_cast<UINT32>(enc->width), static_cast<UINT32>(enc->height));
        MFSetAttributeRatio(outType.Get(), MF_MT_FRAME_RATE, static_cast<UINT32>(enc->fps), 1);
        MFSetAttributeRatio(outType.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);

        if (enc->srcWidth > 0 && enc->srcHeight > 0 &&
            (enc->srcWidth != enc->width || enc->srcHeight != enc->height)) {
            MFVideoArea area = {};
            area.Area.cx = enc->srcWidth;
            area.Area.cy = enc->srcHeight;
            outType->SetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<const UINT8 *>(&area), sizeof(area));
        }

        bool outSet = false;
        if (targetCodec == 1) {
            // Prefer High Profile (CABAC + 8x8 transform) for ~30% sharper text/UI glyph edges at the same bitrate,
            // while CODECAPI_AVLowLatencyMode + BPictureCount=0 guarantees zero reorder frames (instant 0-frame DPB latency).
            const UINT32 profiles[3] = {
                eAVEncH264VProfile_High,
                eAVEncH264VProfile_Main,
                eAVEncH264VProfile_Base
            };
            for (int pass = 0; pass < 2 && !outSet; ++pass) {
                if (pass == 1) {
                    outType->DeleteItem(MF_MT_VIDEO_PRIMARIES);
                    outType->DeleteItem(MF_MT_YUV_MATRIX);
                    outType->DeleteItem(MF_MT_VIDEO_NOMINAL_RANGE);
                }
                for (UINT32 prof : profiles) {
                    outType->SetUINT32(MF_MT_MPEG2_PROFILE, prof);
                    if (SUCCEEDED(mft->SetOutputType(outId, outType.Get(), 0))) {
                        outSet = true;
                        break;
                    }
                }
            }
        } else {
            if (SUCCEEDED(mft->SetOutputType(outId, outType.Get(), 0))) {
                outSet = true;
            } else {
                outType->DeleteItem(MF_MT_VIDEO_PRIMARIES);
                outType->DeleteItem(MF_MT_YUV_MATRIX);
                outType->DeleteItem(MF_MT_VIDEO_NOMINAL_RANGE);
                if (SUCCEEDED(mft->SetOutputType(outId, outType.Get(), 0))) {
                    outSet = true;
                }
            }
        }
        if (!outSet) {
            activates[i]->ShutdownObject();
            continue;
        }

        // 2. Select NV12 Input MediaType
        bool inSet = false;
        for (DWORD idx = 0; idx < 32; ++idx) {
            ComPtr<IMFMediaType> avail;
            if (FAILED(mft->GetInputAvailableType(inId, idx, &avail)) || !avail) {
                break;
            }
            GUID sub = GUID_NULL;
            avail->GetGUID(MF_MT_SUBTYPE, &sub);
            if (sub == MFVideoFormat_NV12) {
                MFSetAttributeSize(avail.Get(), MF_MT_FRAME_SIZE, static_cast<UINT32>(enc->width), static_cast<UINT32>(enc->height));
                MFSetAttributeRatio(avail.Get(), MF_MT_FRAME_RATE, static_cast<UINT32>(enc->fps), 1);
                MFSetAttributeRatio(avail.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                avail->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                avail->SetUINT32(MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709);
                avail->SetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235);
                if (SUCCEEDED(mft->SetInputType(inId, avail.Get(), 0))) {
                    inSet = true;
                    break;
                }
                avail->DeleteItem(MF_MT_YUV_MATRIX);
                avail->DeleteItem(MF_MT_VIDEO_NOMINAL_RANGE);
                if (SUCCEEDED(mft->SetInputType(inId, avail.Get(), 0))) {
                    inSet = true;
                    break;
                }
            }
        }
        if (!inSet) {
            ComPtr<IMFMediaType> nv12Type;
            if (SUCCEEDED(MFCreateMediaType(&nv12Type))) {
                nv12Type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
                nv12Type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
                nv12Type->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
                MFSetAttributeSize(nv12Type.Get(), MF_MT_FRAME_SIZE, static_cast<UINT32>(enc->width), static_cast<UINT32>(enc->height));
                MFSetAttributeRatio(nv12Type.Get(), MF_MT_FRAME_RATE, static_cast<UINT32>(enc->fps), 1);
                MFSetAttributeRatio(nv12Type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
                if (SUCCEEDED(mft->SetInputType(inId, nv12Type.Get(), 0))) {
                    inSet = true;
                }
            }
        }
        if (!inSet) {
            activates[i]->ShutdownObject();
            continue;
        }

        if (codecApi) {
            set_variant_bool_or_u32(codecApi.Get(), CODECAPI_AVLowLatencyMode, true);
            set_variant_u32(codecApi.Get(), CODECAPI_AVEncMPVDefaultBPictureCount, 0);
            set_variant_u32(codecApi.Get(), CODECAPI_AVEncCommonQualityVsSpeed, 72);
        }

        MFT_OUTPUT_STREAM_INFO outStreamInfo = {};
        if (SUCCEEDED(mft->GetOutputStreamInfo(outId, &outStreamInfo))) {
            enc->providesOutputSamples =
                (outStreamInfo.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
            enc->outputSampleSize = outStreamInfo.cbSize > 0
                ? outStreamInfo.cbSize
                : static_cast<DWORD>(enc->width * enc->height * 2);
        } else {
            enc->providesOutputSamples = false;
            enc->outputSampleSize = static_cast<DWORD>(enc->width * enc->height * 2);
        }

        mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
        mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);

        // Extract initial SPS/PPS sequence header if exposed on output media type
        ComPtr<IMFMediaType> curOut;
        if (SUCCEEDED(mft->GetOutputCurrentType(outId, &curOut)) && curOut) {
            UINT8 *seqBlob = nullptr;
            UINT32 seqLen = 0;
            if (SUCCEEDED(curOut->GetAllocatedBlob(MF_MT_MPEG_SEQUENCE_HEADER, &seqBlob, &seqLen)) && seqBlob && seqLen > 4) {
                auto nalus = split_annexb_nalus(seqBlob, seqLen);
                for (const auto &n : nalus) {
                    if (n.len == 0) continue;
                    uint8_t b0 = seqBlob[n.offset];
                    if (targetCodec == 2) {
                        uint8_t t = (b0 >> 1) & 0x3F;
                        if (t == 32) enc->cachedVps.assign(seqBlob + n.offset, seqBlob + n.offset + n.len);
                        else if (t == 33) enc->cachedSps.assign(seqBlob + n.offset, seqBlob + n.offset + n.len);
                        else if (t == 34) enc->cachedPps.assign(seqBlob + n.offset, seqBlob + n.offset + n.len);
                    } else {
                        uint8_t t = b0 & 0x1F;
                        if (t == 7) enc->cachedSps.assign(seqBlob + n.offset, seqBlob + n.offset + n.len);
                        else if (t == 8) enc->cachedPps.assign(seqBlob + n.offset, seqBlob + n.offset + n.len);
                    }
                }
                CoTaskMemFree(seqBlob);
            }
        }

        enc->mft = mft;
        enc->codecApi = codecApi;
        enc->eventGen = evGen;
        enc->isAsync = isAsync;
        enc->isHardware = hardwareOnly;
        enc->codec = targetCodec;
        enc->inputStreamId = inId;
        enc->outputStreamId = outId;
        ok = true;
    }

    for (UINT32 i = 0; i < count; ++i) {
        activates[i]->Release();
    }
    CoTaskMemFree(activates);
    return ok;
}

bool configure_decoder_output_type(OpenUUWinDecoder *dec) {
    if (!dec || !dec->mft) return false;

    for (DWORD i = 0; i < 32; ++i) {
        ComPtr<IMFMediaType> avail;
        HRESULT hr = dec->mft->GetOutputAvailableType(dec->outputStreamId, i, &avail);
        if (FAILED(hr) || !avail) break;

        GUID sub = GUID_NULL;
        avail->GetGUID(MF_MT_SUBTYPE, &sub);
        if (sub == MFVideoFormat_NV12) {
            if (SUCCEEDED(dec->mft->SetOutputType(dec->outputStreamId, avail.Get(), 0))) {
                UINT32 w = 0, h = 0;
                MFGetAttributeSize(avail.Get(), MF_MT_FRAME_SIZE, &w, &h);
                dec->allocW = static_cast<int32_t>(w);
                dec->allocH = static_cast<int32_t>(h);
                dec->frameW = dec->allocW;
                dec->frameH = dec->allocH;

                // Respect MF_MT_MINIMUM_DISPLAY_APERTURE / MF_MT_GEOMETRIC_APERTURE (e.g. 1920x1080 inside 1920x1088)
                MFVideoArea area = {};
                UINT32 cbArea = 0;
                if (SUCCEEDED(avail->GetBlob(MF_MT_MINIMUM_DISPLAY_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof(area), &cbArea)) ||
                    SUCCEEDED(avail->GetBlob(MF_MT_GEOMETRIC_APERTURE, reinterpret_cast<UINT8 *>(&area), sizeof(area), &cbArea))) {
                    if (area.Area.cx > 0 && area.Area.cy > 0 &&
                        area.Area.cx <= dec->allocW && area.Area.cy <= dec->allocH) {
                        dec->frameW = area.Area.cx;
                        dec->frameH = area.Area.cy;
                    }
                }

                UINT32 strideU32 = 0;
                if (SUCCEEDED(avail->GetUINT32(MF_MT_DEFAULT_STRIDE, &strideU32))) {
                    INT32 signedStride = static_cast<INT32>(strideU32);
                    dec->defaultStride = signedStride > 0 ? signedStride : -signedStride;
                } else {
                    LONG calcStride = 0;
                    if (SUCCEEDED(MFGetStrideForBitmapInfoHeader(MFVideoFormat_NV12.Data1, w, &calcStride))) {
                        dec->defaultStride = calcStride >= 0 ? calcStride : -calcStride;
                    } else {
                        dec->defaultStride = dec->allocW;
                    }
                }

                UINT32 nominalRange = MFNominalRange_16_235;
                if (SUCCEEDED(avail->GetUINT32(MF_MT_VIDEO_NOMINAL_RANGE, &nominalRange))) {
                    dec->fullRange = (nominalRange == MFNominalRange_0_255);
                }

                MFT_OUTPUT_STREAM_INFO info = {};
                if (SUCCEEDED(dec->mft->GetOutputStreamInfo(dec->outputStreamId, &info))) {
                    dec->providesOutputSamples =
                        (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
                    dec->outputSampleSize = info.cbSize > 0
                        ? info.cbSize
                        : static_cast<DWORD>(dec->defaultStride * dec->allocH * 3 / 2);
                } else {
                    dec->providesOutputSamples = false;
                    dec->outputSampleSize = static_cast<DWORD>(dec->defaultStride * dec->allocH * 3 / 2);
                }

                dec->outputConfigured = (dec->frameW > 0 && dec->frameH > 0);
                return dec->outputConfigured;
            }
        }
    }
    return false;
}

} // namespace

extern "C" {

OPENUU_MEDIA_API int32_t openuu_media_startup(void) {
    ensure_mf_started();
    return SUCCEEDED(g_mfInitHr) ? 0 : -1;
}

OPENUU_MEDIA_API OpenUUWinEncoder *openuu_encoder_create(
    int32_t width,
    int32_t height,
    int32_t fps,
    int32_t bitrate_bps,
    uint8_t preferred_codec,
    uint8_t *out_actual_codec,
    uint8_t *out_is_hw
) {
    ensure_mf_started();
    if (FAILED(g_mfInitHr)) return nullptr;

    // Preserve exact even dimensions (e.g. 1920x1080) without vertical/horizontal stretching!
    const int32_t evenW = std::max(64, width & ~1);
    const int32_t evenH = std::max(64, height & ~1);
    fps = std::clamp(fps, 15, 60);
    bitrate_bps = std::max(500000, bitrate_bps);

    auto *enc = new OpenUUWinEncoder();
    enc->srcWidth = evenW;
    enc->srcHeight = evenH;
    enc->width = evenW;
    enc->height = evenH;
    enc->fps = fps;
    enc->bitrate = bitrate_bps;

    auto tryAllCodecs = [&]() -> bool {
        if (preferred_codec == 2) {
            if (try_init_encoder_mft(enc, 2, false) || try_init_encoder_mft(enc, 2, true)) {
                return true;
            }
        }
        return try_init_encoder_mft(enc, 1, false) || try_init_encoder_mft(enc, 1, true);
    };

    bool initialized = tryAllCodecs();
    if (!initialized && ((evenW & 15) != 0 || (evenH & 15) != 0)) {
        // Fallback for legacy MFTs requiring 16x16 macroblock-aligned buffers: pad edge pixels without stretching!
        enc->width = (evenW + 15) & ~15;
        enc->height = (evenH + 15) & ~15;
        initialized = tryAllCodecs();
    }
    if (!initialized) {
        delete enc;
        return nullptr;
    }

    enc->nv12Scratch.resize(static_cast<size_t>(enc->width) * enc->height * 3 / 2, 0);
    if (out_actual_codec) *out_actual_codec = enc->codec;
    if (out_is_hw) *out_is_hw = enc->isHardware ? 1 : 0;
    return enc;
}

OPENUU_MEDIA_API void openuu_encoder_destroy(OpenUUWinEncoder *enc) {
    if (!enc) return;
    if (enc->mft) {
        enc->mft->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, enc->inputStreamId);
        enc->mft->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
    }
    delete enc;
}

OPENUU_MEDIA_API void openuu_encoder_force_keyframe(OpenUUWinEncoder *enc) {
    if (enc) {
        enc->forceNextKeyframe = true;
    }
}

OPENUU_MEDIA_API int32_t openuu_encoder_set_bitrate(OpenUUWinEncoder *enc, int32_t bitrate_bps, int32_t fps) {
    if (!enc || !enc->mft) return -1;
    enc->bitrate = std::max(500000, bitrate_bps);
    enc->fps = std::clamp(fps, 15, 60);
    if (enc->codecApi) {
        set_variant_u32(enc->codecApi.Get(), CODECAPI_AVEncCommonMeanBitRate, static_cast<uint32_t>(enc->bitrate));
    }
    return 0;
}

OPENUU_MEDIA_API int32_t openuu_encoder_encode_bgra(
    OpenUUWinEncoder *enc,
    const uint8_t *bgra_data,
    int32_t bgra_stride,
    uint64_t timestamp_us,
    uint8_t *out_buf,
    int32_t out_buf_capacity,
    uint8_t *out_is_keyframe
) {
    if (!enc || !enc->mft || !bgra_data || !out_buf || out_buf_capacity < 1024) {
        return -1;
    }
    if (out_is_keyframe) *out_is_keyframe = 0;

    const int w = enc->width;
    const int h = enc->height;
    const size_t ySize = static_cast<size_t>(w) * h;
    const size_t totalNv12 = ySize + (ySize / 2);

    ComPtr<IMFMediaBuffer> inBuf;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(totalNv12), &inBuf)) || !inBuf) {
        return -2;
    }

    BYTE *nv12Ptr = nullptr;
    if (FAILED(inBuf->Lock(&nv12Ptr, nullptr, nullptr)) || !nv12Ptr) {
        return -3;
    }
    convert_bgra_to_nv12_bt709(
        bgra_data,
        bgra_stride,
        enc->srcWidth > 0 ? enc->srcWidth : w,
        enc->srcHeight > 0 ? enc->srcHeight : h,
        nv12Ptr,
        w,
        nv12Ptr + ySize,
        w,
        w,
        h
    );
    inBuf->Unlock();
    inBuf->SetCurrentLength(static_cast<DWORD>(totalNv12));

    ComPtr<IMFSample> inSample;
    if (FAILED(MFCreateSample(&inSample)) || !inSample) {
        return -4;
    }
    inSample->AddBuffer(inBuf.Get());
    inSample->SetSampleTime(static_cast<LONGLONG>(timestamp_us) * 10); // 100-ns units
    inSample->SetSampleDuration(10000000LL / std::max(1, enc->fps));

    if (enc->forceNextKeyframe) {
        enc->forceNextKeyframe = false;
        if (enc->codecApi) {
            set_variant_u32(enc->codecApi.Get(), CODECAPI_AVEncVideoForceKeyFrame, 1);
        }
    }

    if (enc->isAsync && enc->eventGen) {
        // Drain pending events until NeedInput or HaveOutput
        for (int spin = 0; spin < 20; ++spin) {
            ComPtr<IMFMediaEvent> ev;
            HRESULT evHr = enc->eventGen->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev);
            if (FAILED(evHr) || !ev) break;
            MediaEventType met = MEUnknown;
            ev->GetType(&met);
            if (met == METransformNeedInput) break;
        }
    }

    HRESULT hrIn = enc->mft->ProcessInput(enc->inputStreamId, inSample.Get(), 0);
    if (FAILED(hrIn) && hrIn != MF_E_NOTACCEPTING) {
        return -5;
    }

    std::vector<uint8_t> rawAnnexB;
    bool sampleCleanPoint = false;

    for (int iter = 0; iter < 8; ++iter) {
        if (enc->isAsync && enc->eventGen) {
            bool hasOutput = false;
            for (int waitIdx = 0; waitIdx < 15; ++waitIdx) {
                ComPtr<IMFMediaEvent> ev;
                if (SUCCEEDED(enc->eventGen->GetEvent(MF_EVENT_FLAG_NO_WAIT, &ev)) && ev) {
                    MediaEventType met = MEUnknown;
                    ev->GetType(&met);
                    if (met == METransformHaveOutput) {
                        hasOutput = true;
                        break;
                    }
                }
                if (iter == 0) Sleep(1);
                else break;
            }
            if (!hasOutput) break;
        }

        MFT_OUTPUT_DATA_BUFFER outData = {};
        outData.dwStreamID = enc->outputStreamId;
        ComPtr<IMFSample> allocatedSample;
        if (!enc->providesOutputSamples) {
            if (FAILED(MFCreateSample(&allocatedSample))) break;
            ComPtr<IMFMediaBuffer> outMem;
            if (FAILED(MFCreateMemoryBuffer(enc->outputSampleSize, &outMem))) break;
            allocatedSample->AddBuffer(outMem.Get());
            outData.pSample = allocatedSample.Get();
        }

        DWORD status = 0;
        HRESULT hrOut = enc->mft->ProcessOutput(0, 1, &outData, &status);
        if (outData.pEvents) {
            outData.pEvents->Release();
            outData.pEvents = nullptr;
        }

        if (hrOut == MF_E_TRANSFORM_STREAM_CHANGE) {
            ComPtr<IMFMediaType> newOutType;
            if (SUCCEEDED(enc->mft->GetOutputAvailableType(enc->outputStreamId, 0, &newOutType)) && newOutType) {
                enc->mft->SetOutputType(enc->outputStreamId, newOutType.Get(), 0);
            }
            continue;
        }
        if (hrOut == MF_E_TRANSFORM_NEED_MORE_INPUT || FAILED(hrOut)) {
            if (enc->providesOutputSamples && outData.pSample) {
                outData.pSample->Release();
            }
            break;
        }

        IMFSample *outSample = outData.pSample;
        if (outSample) {
            UINT32 clean = 0;
            if (SUCCEEDED(outSample->GetUINT32(MFSampleExtension_CleanPoint, &clean)) && clean != 0) {
                sampleCleanPoint = true;
            }
            ComPtr<IMFMediaBuffer> contig;
            if (SUCCEEDED(outSample->ConvertToContiguousBuffer(&contig)) && contig) {
                BYTE *ptr = nullptr;
                DWORD curLen = 0;
                if (SUCCEEDED(contig->Lock(&ptr, nullptr, &curLen)) && ptr && curLen > 0) {
                    rawAnnexB.insert(rawAnnexB.end(), ptr, ptr + curLen);
                    contig->Unlock();
                }
            }
            if (enc->providesOutputSamples) {
                outSample->Release();
            }
        }
    }

    if (hrIn == MF_E_NOTACCEPTING) {
        // Retry input now that output was drained
        enc->mft->ProcessInput(enc->inputStreamId, inSample.Get(), 0);
    }

    if (rawAnnexB.empty()) {
        return 0;
    }

    auto nalus = split_annexb_nalus(rawAnnexB.data(), rawAnnexB.size());
    bool hasVps = false, hasSps = false, hasPps = false, isIdr = sampleCleanPoint;

    for (const auto &n : nalus) {
        if (n.len == 0) continue;
        uint8_t b0 = rawAnnexB[n.offset];
        if (enc->codec == 2) {
            uint8_t t = (b0 >> 1) & 0x3F;
            if (t == 32) {
                hasVps = true;
                enc->cachedVps.assign(rawAnnexB.begin() + n.offset, rawAnnexB.begin() + n.offset + n.len);
            } else if (t == 33) {
                hasSps = true;
                enc->cachedSps.assign(rawAnnexB.begin() + n.offset, rawAnnexB.begin() + n.offset + n.len);
            } else if (t == 34) {
                hasPps = true;
                enc->cachedPps.assign(rawAnnexB.begin() + n.offset, rawAnnexB.begin() + n.offset + n.len);
            } else if (t >= 16 && t <= 21) {
                isIdr = true;
            }
        } else {
            uint8_t t = b0 & 0x1F;
            if (t == 7) {
                hasSps = true;
                enc->cachedSps.assign(rawAnnexB.begin() + n.offset, rawAnnexB.begin() + n.offset + n.len);
            } else if (t == 8) {
                hasPps = true;
                enc->cachedPps.assign(rawAnnexB.begin() + n.offset, rawAnnexB.begin() + n.offset + n.len);
            } else if (t == 5) {
                isIdr = true;
            }
        }
    }

    static const uint8_t kStartCode[4] = {0x00, 0x00, 0x00, 0x01};
    int32_t writePos = 0;

    auto appendBytes = [&](const uint8_t *src, size_t len) -> bool {
        if (writePos + static_cast<int32_t>(len) > out_buf_capacity) return false;
        std::memcpy(out_buf + writePos, src, len);
        writePos += static_cast<int32_t>(len);
        return true;
    };

    // Guarantee VPS/SPS/PPS on every IDR keyframe so any client can decode immediately
    if (isIdr) {
        if (enc->codec == 2 && !hasVps && !enc->cachedVps.empty()) {
            if (!appendBytes(kStartCode, 4) || !appendBytes(enc->cachedVps.data(), enc->cachedVps.size())) return -6;
        }
        if (!hasSps && !enc->cachedSps.empty()) {
            if (!appendBytes(kStartCode, 4) || !appendBytes(enc->cachedSps.data(), enc->cachedSps.size())) return -6;
        }
        if (!hasPps && !enc->cachedPps.empty()) {
            if (!appendBytes(kStartCode, 4) || !appendBytes(enc->cachedPps.data(), enc->cachedPps.size())) return -6;
        }
    }

    if (!appendBytes(rawAnnexB.data(), rawAnnexB.size())) {
        return -6;
    }

    if (out_is_keyframe) *out_is_keyframe = isIdr ? 1 : 0;
    return writePos;
}

OPENUU_MEDIA_API OpenUUWinDecoder *openuu_decoder_create(uint8_t codec) {
    ensure_mf_started();
    if (FAILED(g_mfInitHr)) return nullptr;

    MFT_REGISTER_TYPE_INFO inInfo = {};
    inInfo.guidMajorType = MFMediaType_Video;
    inInfo.guidSubtype = (codec == 2) ? MFVideoFormat_HEVC : MFVideoFormat_H264;

    IMFActivate **activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_VIDEO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER,
        &inInfo,
        nullptr,
        &activates,
        &count
    );
    if (FAILED(hr) || count == 0 || !activates) {
        return nullptr;
    }

    ComPtr<IMFTransform> mft;
    for (UINT32 i = 0; i < count; ++i) {
        ComPtr<IMFTransform> candidate;
        if (SUCCEEDED(activates[i]->ActivateObject(IID_PPV_ARGS(&candidate))) && candidate) {
            ComPtr<IMFAttributes> cAttrs;
            UINT32 isAsync = 0;
            if (SUCCEEDED(candidate->GetAttributes(&cAttrs)) && cAttrs) {
                cAttrs->GetUINT32(MF_TRANSFORM_ASYNC, &isAsync);
            }
            // Prefer synchronous MFTs first; only fall back to async MFT if no sync MFT is available
            if (isAsync == 0) {
                mft = candidate;
                break;
            } else if (!mft) {
                if (cAttrs) cAttrs->SetUINT32(MF_TRANSFORM_ASYNC_UNLOCK, TRUE);
                mft = candidate;
            } else {
                activates[i]->ShutdownObject();
            }
        }
    }
    for (UINT32 i = 0; i < count; ++i) {
        activates[i]->Release();
    }
    CoTaskMemFree(activates);

    if (!mft) return nullptr;

    // Enable zero-delay single-worker low-latency decode mode BEFORE setting media types!
    ComPtr<IMFAttributes> attrs;
    if (SUCCEEDED(mft->GetAttributes(&attrs)) && attrs) {
        attrs->SetUINT32(kOpenUUMfLowLatency, TRUE);
        attrs->SetUINT32(CODECAPI_AVDecNumWorkerThreads, 1);
        attrs->SetUINT32(CODECAPI_AVDecDisableVideoPostProcessing, TRUE);
    }
    ComPtr<ICodecAPI> codecApi;
    if (SUCCEEDED(mft->QueryInterface(IID_ICodecAPI, reinterpret_cast<void **>(codecApi.GetAddressOf()))) && codecApi) {
        set_variant_bool_or_u32(codecApi.Get(), CODECAPI_AVLowLatencyMode, true);
        set_variant_u32(codecApi.Get(), CODECAPI_AVDecNumWorkerThreads, 1);
        set_variant_bool_or_u32(codecApi.Get(), CODECAPI_AVDecDisableVideoPostProcessing, true);
    }

    auto *dec = new OpenUUWinDecoder();
    dec->mft = mft;
    dec->codec = codec;

    DWORD inCount = 0, outCount = 0;
    if (SUCCEEDED(mft->GetStreamCount(&inCount, &outCount)) && inCount >= 1 && outCount >= 1) {
        if (FAILED(mft->GetStreamIDs(1, &dec->inputStreamId, 1, &dec->outputStreamId))) {
            dec->inputStreamId = 0;
            dec->outputStreamId = 0;
        }
    }

    ComPtr<IMFMediaType> inType;
    if (SUCCEEDED(MFCreateMediaType(&inType)) && inType) {
        inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
        inType->SetGUID(MF_MT_SUBTYPE, inInfo.guidSubtype);
        inType->SetUINT32(MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
        MFSetAttributeSize(inType.Get(), MF_MT_FRAME_SIZE, 1920, 1080);
        if (SUCCEEDED(mft->SetInputType(dec->inputStreamId, inType.Get(), 0))) {
            dec->inputConfigured = true;
            configure_decoder_output_type(dec);
            mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
            mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
        }
    }

    if (!dec->inputConfigured) {
        delete dec;
        return nullptr;
    }
    return dec;
}

OPENUU_MEDIA_API void openuu_decoder_destroy(OpenUUWinDecoder *dec) {
    if (!dec) return;
    if (dec->mft) {
        dec->mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
    delete dec;
}

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
) {
    if (!dec || !dec->mft || !annexb_data || annexb_len <= 0) {
        return -1;
    }

    // Append trailing Access Unit Delimiter (AUD) so Media Foundation H.264/HEVC MFT flushes the access unit immediately
    // without waiting for the next packet's start code on static/idle windows.
    static const uint8_t kH264Aud[6] = {0x00, 0x00, 0x00, 0x01, 0x09, 0xF0};
    static const uint8_t kHevcAud[7] = {0x00, 0x00, 0x00, 0x01, 0x46, 0x01, 0x50};
    const uint8_t *audPtr = (dec->codec == 2) ? kHevcAud : kH264Aud;
    const size_t audLen = (dec->codec == 2) ? sizeof(kHevcAud) : sizeof(kH264Aud);
    const DWORD totalInLen = static_cast<DWORD>(annexb_len) + static_cast<DWORD>(audLen);

    ComPtr<IMFMediaBuffer> inBuf;
    if (FAILED(MFCreateMemoryBuffer(totalInLen, &inBuf)) || !inBuf) {
        return -2;
    }
    BYTE *dst = nullptr;
    if (FAILED(inBuf->Lock(&dst, nullptr, nullptr)) || !dst) {
        return -3;
    }
    std::memcpy(dst, annexb_data, static_cast<size_t>(annexb_len));
    std::memcpy(dst + annexb_len, audPtr, audLen);
    inBuf->Unlock();
    inBuf->SetCurrentLength(totalInLen);

    ComPtr<IMFSample> inSample;
    if (FAILED(MFCreateSample(&inSample)) || !inSample) {
        return -4;
    }
    inSample->AddBuffer(inBuf.Get());
    inSample->SetSampleTime(static_cast<LONGLONG>(timestamp_us) * 10);
    inSample->SetSampleDuration(166667);

    auto drainOutputs = [&]() -> bool {
        bool gotFrame = false;
        for (int iter = 0; iter < 16; ++iter) {
            MFT_OUTPUT_DATA_BUFFER outData = {};
            outData.dwStreamID = dec->outputStreamId;
            ComPtr<IMFSample> allocSample;
            if (!dec->providesOutputSamples) {
                if (FAILED(MFCreateSample(&allocSample))) break;
                ComPtr<IMFMediaBuffer> outMem;
                DWORD allocBytes = dec->outputSampleSize > 0 ? dec->outputSampleSize : (1920 * 1088 * 3 / 2);
                if (FAILED(MFCreateMemoryBuffer(allocBytes, &outMem))) break;
                allocSample->AddBuffer(outMem.Get());
                outData.pSample = allocSample.Get();
            }

            DWORD status = 0;
            HRESULT hrOut = dec->mft->ProcessOutput(0, 1, &outData, &status);
            dec->diagHrOut = static_cast<uint32_t>(hrOut);
            if (outData.pEvents) {
                outData.pEvents->Release();
                outData.pEvents = nullptr;
            }

            if (hrOut == MF_E_TRANSFORM_STREAM_CHANGE) {
                if (configure_decoder_output_type(dec)) {
                    continue;
                }
                break;
            }
            if (hrOut == MF_E_TRANSFORM_NEED_MORE_INPUT || FAILED(hrOut)) {
                if (dec->providesOutputSamples && outData.pSample) {
                    outData.pSample->Release();
                }
                break;
            }

            IMFSample *outSample = outData.pSample;
            if (outSample) {
                ComPtr<IMFMediaBuffer> buf;
                if (SUCCEEDED(outSample->ConvertToContiguousBuffer(&buf)) && buf) {
                    ComPtr<IMF2DBuffer> buf2d;
                    if (SUCCEEDED(buf.As(&buf2d)) && buf2d) {
                        BYTE *scanline0 = nullptr;
                        LONG pitch = 0;
                        if (SUCCEEDED(buf2d->Lock2D(&scanline0, &pitch)) && scanline0 && pitch > 0) {
                            const size_t yBytes = static_cast<size_t>(pitch) * dec->allocH;
                            const size_t uvBytes = static_cast<size_t>(pitch) * (dec->allocH / 2);
                            dec->lastNv12.resize(yBytes + uvBytes);
                            std::memcpy(dec->lastNv12.data(), scanline0, yBytes + uvBytes);
                            dec->lastYStride = pitch;
                            dec->lastUvStride = pitch;
                            dec->lastUvOffset = yBytes;
                            gotFrame = true;
                            buf2d->Unlock2D();
                        }
                    } else {
                        BYTE *rawPtr = nullptr;
                        DWORD curLen = 0;
                        if (SUCCEEDED(buf->Lock(&rawPtr, nullptr, &curLen)) && rawPtr && curLen > 0) {
                            dec->diagCurLen = static_cast<int32_t>(curLen);
                            int stride = dec->defaultStride > 0 ? dec->defaultStride : dec->allocW;
                            size_t expectedPadded = static_cast<size_t>(stride) * dec->allocH * 3 / 2;
                            size_t expectedTight = static_cast<size_t>(dec->allocW) * dec->allocH * 3 / 2;
                            if (expectedPadded > 0 && curLen >= expectedPadded) {
                                size_t yBytes = static_cast<size_t>(stride) * dec->allocH;
                                dec->lastNv12.assign(rawPtr, rawPtr + curLen);
                                dec->lastYStride = stride;
                                dec->lastUvStride = stride;
                                dec->lastUvOffset = yBytes;
                                gotFrame = true;
                            } else if (expectedTight > 0 && curLen >= expectedTight) {
                                int effStride = (dec->allocH > 0 && (static_cast<size_t>(curLen) * 2) % (static_cast<size_t>(dec->allocH) * 3) == 0)
                                    ? static_cast<int>((static_cast<size_t>(curLen) * 2) / (static_cast<size_t>(dec->allocH) * 3))
                                    : dec->allocW;
                                if (effStride < dec->allocW) effStride = dec->allocW;
                                size_t yBytes = static_cast<size_t>(effStride) * dec->allocH;
                                dec->lastNv12.assign(rawPtr, rawPtr + curLen);
                                if (dec->lastNv12.size() < yBytes + (yBytes / 2)) {
                                    dec->lastNv12.resize(yBytes + (yBytes / 2), 0);
                                }
                                dec->lastYStride = effStride;
                                dec->lastUvStride = effStride;
                                dec->lastUvOffset = yBytes;
                                gotFrame = true;
                            }
                            buf->Unlock();
                        }
                    }
                }
                if (dec->providesOutputSamples) {
                    outSample->Release();
                }
            }
        }
        return gotFrame;
    };

    HRESULT hrIn = dec->mft->ProcessInput(dec->inputStreamId, inSample.Get(), 0);
    dec->diagHrIn = static_cast<uint32_t>(hrIn);
    bool decoded = drainOutputs();
    if (hrIn == MF_E_NOTACCEPTING) {
        if (SUCCEEDED(dec->mft->ProcessInput(dec->inputStreamId, inSample.Get(), 0))) {
            decoded = drainOutputs() || decoded;
        }
    } else if (FAILED(hrIn)) {
        return -5;
    }

    if (!decoded || dec->frameW <= 0 || dec->frameH <= 0 || dec->lastNv12.empty()) {
        return 0;
    }

    if (out_width) *out_width = dec->frameW;
    if (out_height) *out_height = dec->frameH;

    int32_t neededStride = out_bgra_stride > 0 ? out_bgra_stride : (dec->frameW * 4);
    int32_t neededBytes = neededStride * dec->frameH;
    if (!out_bgra || out_capacity < neededBytes || neededStride < dec->frameW * 4) {
        return 2; // Caller should resize buffer to (*out_width, *out_height) and call openuu_decoder_copy_last_bgra
    }

    convert_nv12_to_bgra_bt709(
        dec->lastNv12.data(),
        dec->lastYStride,
        dec->lastNv12.data() + dec->lastUvOffset,
        dec->lastUvStride,
        out_bgra,
        neededStride,
        dec->frameW,
        dec->frameH,
        dec->fullRange
    );
    return 1;
}

OPENUU_MEDIA_API int32_t openuu_decoder_copy_last_bgra(
    OpenUUWinDecoder *dec,
    uint8_t *out_bgra,
    int32_t out_bgra_stride,
    int32_t out_capacity
) {
    if (!dec || dec->lastNv12.empty() || dec->frameW <= 0 || dec->frameH <= 0 || !out_bgra) {
        return -1;
    }
    int32_t stride = out_bgra_stride > 0 ? out_bgra_stride : (dec->frameW * 4);
    if (stride < dec->frameW * 4 || out_capacity < stride * dec->frameH) {
        return -2;
    }
    convert_nv12_to_bgra_bt709(
        dec->lastNv12.data(),
        dec->lastYStride,
        dec->lastNv12.data() + dec->lastUvOffset,
        dec->lastUvStride,
        out_bgra,
        stride,
        dec->frameW,
        dec->frameH,
        dec->fullRange
    );
    return 1;
}

OPENUU_MEDIA_API int32_t openuu_capture_hwnd_bgra(
    void *hwnd_ptr,
    int32_t dst_width,
    int32_t dst_height,
    uint8_t *out_bgra,
    int32_t out_stride,
    uint64_t *out_frame_hash
) {
    HWND hwnd = reinterpret_cast<HWND>(hwnd_ptr);
    if (!hwnd || !IsWindow(hwnd) || IsIconic(hwnd) || !out_bgra || dst_width < 2 || dst_height < 2) {
        return 0;
    }

    RECT winRect = {};
    if (!GetWindowRect(hwnd, &winRect)) return 0;
    int winW = winRect.right - winRect.left;
    int winH = winRect.bottom - winRect.top;
    if (winW < 16 || winH < 16) return 0;

    // Exclude invisible Windows 10/11 DWM shadow borders using DWMWA_EXTENDED_FRAME_BOUNDS
    RECT visRect = winRect;
    if (FAILED(DwmGetWindowAttribute(hwnd, DWMWA_EXTENDED_FRAME_BOUNDS, &visRect, sizeof(visRect)))) {
        visRect = winRect;
    }
    int cropX = std::max(0, static_cast<int>(visRect.left - winRect.left));
    int cropY = std::max(0, static_cast<int>(visRect.top - winRect.top));
    int cropW = std::min(winW - cropX, static_cast<int>(visRect.right - visRect.left));
    int cropH = std::min(winH - cropY, static_cast<int>(visRect.bottom - visRect.top));
    if (cropW < 16 || cropH < 16) {
        cropX = 0;
        cropY = 0;
        cropW = winW;
        cropH = winH;
    }

    HDC screenDC = GetDC(nullptr);
    if (!screenDC) return -1;

    HDC srcDC = CreateCompatibleDC(screenDC);
    HBITMAP srcBmp = CreateCompatibleBitmap(screenDC, winW, winH);
    HGDIOBJ oldSrc = SelectObject(srcDC, srcBmp);

    // Guard PrintWindow with a 35ms responsiveness probe: PrintWindow sends a synchronous message to hwnd's thread,
    // which would block indefinitely if the target process is hung or sleeping without pumping messages.
    DWORD_PTR probeResult = 0;
    BOOL threadResponsive = SendMessageTimeoutW(
        hwnd,
        WM_NULL,
        0,
        0,
        SMTO_ABORTIFHUNG | SMTO_BLOCK,
        35,
        &probeResult
    );

    BOOL printed = FALSE;
    if (threadResponsive) {
        printed = PrintWindow(hwnd, srcDC, PW_RENDERFULLCONTENT);
    }

    int srcCropX = cropX;
    int srcCropY = cropY;
    int srcCropW = cropW;
    int srcCropH = cropH;

    if (printed) {
        // Handle DWM DPI-virtualized windows on HiDPI monitors (e.g. 96-DPI legacy Win32/WinForms window on 144/192-DPI display):
        // PrintWindow renders DPI-unaware windows at their logical 96-DPI dimensions inside srcBmp rather than physical pixels.
        using GetDpiForWindowFn = UINT(WINAPI *)(HWND);
        using GetDpiForMonitorFn = HRESULT(WINAPI *)(HMONITOR, int, UINT *, UINT *);
        static auto pGetDpiForWindow = reinterpret_cast<GetDpiForWindowFn>(
            GetProcAddress(GetModuleHandleW(L"user32.dll"), "GetDpiForWindow")
        );
        static HMODULE hShcore = LoadLibraryW(L"Shcore.dll");
        static auto pGetDpiForMonitor = hShcore
            ? reinterpret_cast<GetDpiForMonitorFn>(GetProcAddress(hShcore, "GetDpiForMonitor"))
            : nullptr;

        if (pGetDpiForWindow && pGetDpiForMonitor) {
            UINT winDpi = pGetDpiForWindow(hwnd);
            HMONITOR hMon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            UINT monDpiX = 96, monDpiY = 96;
            if (hMon && SUCCEEDED(pGetDpiForMonitor(hMon, 0 /* MDT_EFFECTIVE_DPI */, &monDpiX, &monDpiY))) {
                if (winDpi >= 72 && monDpiX > winDpi + 4) {
                    const double ratio = static_cast<double>(winDpi) / static_cast<double>(monDpiX);
                    srcCropX = std::max(0, static_cast<int>(cropX * ratio + 0.5));
                    srcCropY = std::max(0, static_cast<int>(cropY * ratio + 0.5));
                    srcCropW = std::max(16, static_cast<int>(cropW * ratio + 0.5));
                    srcCropH = std::max(16, static_cast<int>(cropH * ratio + 0.5));
                }
            }
        }
    } else {
        // Non-blocking DWM desktop screen-space fallback for hung/console windows
        BitBlt(srcDC, cropX, cropY, cropW, cropH, screenDC, visRect.left, visRect.top, SRCCOPY | CAPTUREBLT);
    }

    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = srcCropW;
    bmi.bmiHeader.biHeight = -srcCropH; // Top-down BGRA at native source crop resolution
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void *dibBits = nullptr;
    HDC dstDC = CreateCompatibleDC(screenDC);
    HBITMAP dstBmp = CreateDIBSection(screenDC, &bmi, DIB_RGB_COLORS, &dibBits, nullptr, 0);
    int32_t rc = -2;

    if (dstBmp && dibBits) {
        HGDIOBJ oldDst = SelectObject(dstDC, dstBmp);
        // Copy 1:1 with BitBlt (never StretchBlt HALFTONE, which softens 1px ClearType font strokes even at 1:1!)
        BitBlt(dstDC, 0, 0, srcCropW, srcCropH, srcDC, srcCropX, srcCropY, SRCCOPY);
        GdiFlush();

        const int targetStride = out_stride >= dst_width * 4 ? out_stride : (dst_width * 4);
        resample_bgra_area_bilinear(
            static_cast<const uint8_t *>(dibBits),
            srcCropW * 4,
            srcCropW,
            srcCropH,
            out_bgra,
            targetStride,
            dst_width,
            dst_height
        );
        if (out_frame_hash) {
            *out_frame_hash = compute_bgra_fast_hash(out_bgra, dst_width, dst_height, targetStride);
        }
        rc = 1;
        SelectObject(dstDC, oldDst);
    }

    if (dstBmp) DeleteObject(dstBmp);
    if (dstDC) DeleteDC(dstDC);
    SelectObject(srcDC, oldSrc);
    if (srcBmp) DeleteObject(srcBmp);
    if (srcDC) DeleteDC(srcDC);
    ReleaseDC(nullptr, screenDC);
    return rc;
}

OPENUU_MEDIA_API OpenUUDxgiCapturer *openuu_dxgi_capturer_create(int32_t *out_screen_w, int32_t *out_screen_h) {
    auto *cap = new OpenUUDxgiCapturer();
    query_physical_screen_size(&cap->screenW, &cap->screenH);

    D3D_FEATURE_LEVEL featureLevels[] = {D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0};
    D3D_FEATURE_LEVEL actualLevel = D3D_FEATURE_LEVEL_11_0;
    if (SUCCEEDED(D3D11CreateDevice(
            nullptr,
            D3D_DRIVER_TYPE_HARDWARE,
            nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            featureLevels,
            2,
            D3D11_SDK_VERSION,
            &cap->device,
            &actualLevel,
            &cap->context))) {
        ComPtr<IDXGIDevice> dxgiDevice;
        ComPtr<IDXGIAdapter> adapter;
        ComPtr<IDXGIOutput> output;
        ComPtr<IDXGIOutput1> output1;
        if (SUCCEEDED(cap->device.As(&dxgiDevice)) &&
            SUCCEEDED(dxgiDevice->GetAdapter(&adapter)) &&
            SUCCEEDED(adapter->EnumOutputs(0, &output)) &&
            SUCCEEDED(output.As(&output1))) {
            DXGI_OUTPUT_DESC desc = {};
            if (SUCCEEDED(output->GetDesc(&desc))) {
                int w = desc.DesktopCoordinates.right - desc.DesktopCoordinates.left;
                int h = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;
                if (w > 0 && h > 0) {
                    cap->screenW = w;
                    cap->screenH = h;
                }
            }
            if (SUCCEEDED(output1->DuplicateOutput(cap->device.Get(), &cap->duplication)) && cap->duplication) {
                D3D11_TEXTURE2D_DESC texDesc = {};
                texDesc.Width = static_cast<UINT>(cap->screenW);
                texDesc.Height = static_cast<UINT>(cap->screenH);
                texDesc.MipLevels = 1;
                texDesc.ArraySize = 1;
                texDesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
                texDesc.SampleDesc.Count = 1;
                texDesc.Usage = D3D11_USAGE_STAGING;
                texDesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
                if (SUCCEEDED(cap->device->CreateTexture2D(&texDesc, nullptr, &cap->stagingTex))) {
                    cap->dxgiValid = true;
                }
            }
        }
    }

    if (out_screen_w) *out_screen_w = cap->screenW;
    if (out_screen_h) *out_screen_h = cap->screenH;
    return cap;
}

OPENUU_MEDIA_API void openuu_dxgi_capturer_destroy(OpenUUDxgiCapturer *cap) {
    delete cap;
}

OPENUU_MEDIA_API int32_t openuu_dxgi_capturer_grab_bgra(
    OpenUUDxgiCapturer *cap,
    int32_t dst_width,
    int32_t dst_height,
    uint8_t *out_bgra,
    int32_t out_stride,
    uint64_t *out_frame_hash
) {
    if (!cap || !out_bgra || dst_width < 2 || dst_height < 2) return -1;
    const int targetStride = out_stride >= dst_width * 4 ? out_stride : (dst_width * 4);

    if (cap->dxgiValid && cap->duplication && cap->stagingTex) {
        ComPtr<IDXGIResource> desktopRes;
        DXGI_OUTDUPL_FRAME_INFO frameInfo = {};
        HRESULT hr = cap->duplication->AcquireNextFrame(16, &frameInfo, &desktopRes);
        if (hr == DXGI_ERROR_WAIT_TIMEOUT) {
            return 0; // Desktop unchanged
        }
        if (SUCCEEDED(hr) && desktopRes) {
            // Note: On initial AcquireNextFrame, LastPresentTime == 0 indicates a cursor-only update with an empty
            // black desktop texture; release and fall through to GDI BitBlt so Frame #0 is immediately crisp & colorful.
            if (frameInfo.LastPresentTime.QuadPart == 0) {
                cap->duplication->ReleaseFrame();
            } else {
                ComPtr<ID3D11Texture2D> desktopTex;
                bool copied = false;
                bool formatMismatch = false;
                if (SUCCEEDED(desktopRes.As(&desktopTex)) && desktopTex) {
                    D3D11_TEXTURE2D_DESC srcDesc = {};
                    desktopTex->GetDesc(&srcDesc);
                    if (srcDesc.Format != DXGI_FORMAT_B8G8R8A8_UNORM ||
                        srcDesc.Width != static_cast<UINT>(cap->screenW) ||
                        srcDesc.Height != static_cast<UINT>(cap->screenH)) {
                        // Display is in 10-bit / HDR / FP16 WCG format; switch cleanly to sRGB tone-mapped GDI capture
                        formatMismatch = true;
                    } else {
                        cap->context->CopyResource(cap->stagingTex.Get(), desktopTex.Get());
                        D3D11_MAPPED_SUBRESOURCE mapped = {};
                        if (SUCCEEDED(cap->context->Map(cap->stagingTex.Get(), 0, D3D11_MAP_READ, 0, &mapped)) && mapped.pData) {
                            const uint8_t *srcBase = static_cast<const uint8_t *>(mapped.pData);
                            resample_bgra_area_bilinear(
                                srcBase,
                                static_cast<int32_t>(mapped.RowPitch),
                                cap->screenW,
                                cap->screenH,
                                out_bgra,
                                targetStride,
                                dst_width,
                                dst_height
                            );
                            cap->context->Unmap(cap->stagingTex.Get(), 0);
                            copied = true;
                        }
                    }
                }
                cap->duplication->ReleaseFrame();
                if (formatMismatch) {
                    cap->dxgiValid = false;
                    cap->duplication.Reset();
                } else if (copied) {
                    if (out_frame_hash) {
                        *out_frame_hash = compute_bgra_fast_hash(out_bgra, dst_width, dst_height, targetStride);
                    }
                    return 1;
                }
            }
        } else if (hr == DXGI_ERROR_ACCESS_LOST) {
            cap->dxgiValid = false;
            cap->duplication.Reset();
        }
    }

    // Reliable GDI fallback: capture 1:1 into top-down DIBSection, then area-average resample only when scaled
    HDC screenDC = GetDC(nullptr);
    if (!screenDC) return -2;
    int32_t scrW = 0, scrH = 0;
    query_physical_screen_size(&scrW, &scrH);

    BITMAPINFO bmi = {};
    bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = scrW;
    bmi.bmiHeader.biHeight = -scrH;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB;

    void *dibBits = nullptr;
    HDC memDC = CreateCompatibleDC(screenDC);
    HBITMAP dib = CreateDIBSection(screenDC, &bmi, DIB_RGB_COLORS, &dibBits, nullptr, 0);
    int32_t rc = -3;
    if (dib && dibBits) {
        HGDIOBJ old = SelectObject(memDC, dib);
        BitBlt(memDC, 0, 0, scrW, scrH, screenDC, 0, 0, SRCCOPY | CAPTUREBLT);
        GdiFlush();

        resample_bgra_area_bilinear(
            static_cast<const uint8_t *>(dibBits),
            scrW * 4,
            scrW,
            scrH,
            out_bgra,
            targetStride,
            dst_width,
            dst_height
        );
        if (out_frame_hash) {
            *out_frame_hash = compute_bgra_fast_hash(out_bgra, dst_width, dst_height, targetStride);
        }
        rc = 1;
        SelectObject(memDC, old);
    }
    if (dib) DeleteObject(dib);
    if (memDC) DeleteDC(memDC);
    ReleaseDC(nullptr, screenDC);
    return rc;
}

// ============================================================================
// Remote Audio Implementation (AAC-LC MFT + WASAPI Loopback + WaveOut)
// ============================================================================

namespace {

static const GUID kClsidMMDeviceEnumerator =
    {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID kIidIMMDeviceEnumerator =
    {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID kIidIAudioClient =
    {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID kIidIAudioCaptureClient =
    {0xc8adbd64, 0xe71e, 0x48a0, {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}};
static const GUID kIidIAudioEndpointVolume =
    {0x5cdf2c82, 0x841e, 0x4546, {0x97, 0x22, 0x0c, 0xf7, 0x40, 0x78, 0x22, 0x9a}};

#ifndef AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
#define AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM 0x80000000
#endif
#ifndef AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
#define AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY 0x08000000
#endif

static uint8_t aac_freq_index(int32_t sr) {
    switch (sr) {
        case 96000: return 0;
        case 88200: return 1;
        case 64000: return 2;
        case 48000: return 3;
        case 44100: return 4;
        case 32000: return 5;
        case 24000: return 6;
        case 22050: return 7;
        case 16000: return 8;
        case 12000: return 9;
        case 11025: return 10;
        case 8000:  return 11;
        default:    return 3; // 48000 Hz
    }
}

static void build_aac_lc_asc(int32_t sample_rate, int32_t channels, uint8_t out_asc[2]) {
    // ISO/IEC 14496-3 AudioSpecificConfig: audioObjectType=2 (AAC-LC, 5 bits), samplingFrequencyIndex (4 bits), channelConfiguration (4 bits)
    const uint16_t aot = 2;
    const uint16_t fi = aac_freq_index(sample_rate);
    const uint16_t ch = static_cast<uint16_t>(std::clamp(channels, 1, 2));
    const uint16_t bits = static_cast<uint16_t>((aot << 11) | (fi << 7) | (ch << 3));
    out_asc[0] = static_cast<uint8_t>((bits >> 8) & 0xFF);
    out_asc[1] = static_cast<uint8_t>(bits & 0xFF);
}

} // namespace

struct OpenUUWinAacEncoder {
    ComPtr<IMFTransform> mft;
    int32_t sampleRate = 48000;
    int32_t channels = 2;
    DWORD inputStreamId = 0;
    DWORD outputStreamId = 0;
    bool providesOutputSamples = false;
    DWORD outputSampleSize = 4096;
};

struct OpenUUWinAacDecoder {
    ComPtr<IMFTransform> mft;
    int32_t sampleRate = 48000;
    int32_t channels = 2;
    bool outputIsFloat = false;
    DWORD inputStreamId = 0;
    DWORD outputStreamId = 0;
    bool providesOutputSamples = false;
    DWORD outputSampleSize = 16384;
};

struct OpenUUWasapiLoopback {
    ComPtr<IMMDevice> device;
    ComPtr<IAudioClient> audioClient;
    ComPtr<IAudioCaptureClient> captureClient;
    ComPtr<IAudioEndpointVolume> endpointVolume;
    bool didMuteHost = false;
    bool started = false;
};

struct OpenUUWaveOutPlayer {
    static constexpr int kRingSlots = 12;
    static constexpr int kMaxInFlight = 10;
    static constexpr int kSlotBytes = 16384;

    HWAVEOUT hWaveOut = nullptr;
    WAVEHDR headers[kRingSlots] = {};
    std::vector<uint8_t> buffers[kRingSlots];
    int nextSlot = 0;
    std::mutex mtx;
};

OPENUU_MEDIA_API OpenUUWinAacEncoder *openuu_aac_encoder_create(
    int32_t sample_rate,
    int32_t channels,
    int32_t bitrate_bps
) {
    ensure_mf_started();
    if (FAILED(g_mfInitHr)) return nullptr;

    sample_rate = (sample_rate == 44100 || sample_rate == 48000) ? sample_rate : 48000;
    channels = std::clamp(channels, 1, 2);
    // Windows MF AAC Encoder MFT supports 12000 (96kbps), 16000 (128kbps), 20000 (160kbps), 24000 (192kbps) bytes/sec
    UINT32 avgBytesPerSec = 16000;
    if (bitrate_bps <= 104000) avgBytesPerSec = 12000;
    else if (bitrate_bps >= 152000) avgBytesPerSec = 20000;

    MFT_REGISTER_TYPE_INFO outInfo = {};
    outInfo.guidMajorType = MFMediaType_Audio;
    outInfo.guidSubtype = MFAudioFormat_AAC;

    IMFActivate **activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_AUDIO_ENCODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        nullptr,
        &outInfo,
        &activates,
        &count
    );
    if (FAILED(hr) || count == 0 || !activates) {
        return nullptr;
    }

    ComPtr<IMFTransform> mft;
    for (UINT32 i = 0; i < count; ++i) {
        if (SUCCEEDED(activates[i]->ActivateObject(IID_PPV_ARGS(&mft))) && mft) {
            break;
        }
    }
    for (UINT32 i = 0; i < count; ++i) activates[i]->Release();
    CoTaskMemFree(activates);
    if (!mft) return nullptr;

    auto *enc = new OpenUUWinAacEncoder();
    enc->mft = mft;
    enc->sampleRate = sample_rate;
    enc->channels = channels;

    DWORD inCount = 0, outCount = 0;
    if (SUCCEEDED(mft->GetStreamCount(&inCount, &outCount)) && inCount >= 1 && outCount >= 1) {
        if (FAILED(mft->GetStreamIDs(1, &enc->inputStreamId, 1, &enc->outputStreamId))) {
            enc->inputStreamId = 0;
            enc->outputStreamId = 0;
        }
    }

    ComPtr<IMFMediaType> inType;
    MFCreateMediaType(&inType);
    inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    inType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_PCM);
    inType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    inType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(sample_rate));
    inType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(channels));
    inType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, static_cast<UINT32>(channels * 2));
    inType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, static_cast<UINT32>(sample_rate * channels * 2));

    ComPtr<IMFMediaType> outType;
    MFCreateMediaType(&outType);
    outType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    outType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    outType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    outType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(sample_rate));
    outType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(channels));
    outType->SetUINT32(MF_MT_AUDIO_AVG_BYTES_PER_SECOND, avgBytesPerSec);
    outType->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0); // Raw AAC-LC access units (no ADTS)

    // MF AAC Encoder accepts either Input-then-Output or Output-then-Input depending on Windows build
    bool configured = false;
    if (SUCCEEDED(mft->SetInputType(enc->inputStreamId, inType.Get(), 0)) &&
        SUCCEEDED(mft->SetOutputType(enc->outputStreamId, outType.Get(), 0))) {
        configured = true;
    } else if (SUCCEEDED(mft->SetOutputType(enc->outputStreamId, outType.Get(), 0)) &&
               SUCCEEDED(mft->SetInputType(enc->inputStreamId, inType.Get(), 0))) {
        configured = true;
    }

    if (!configured) {
        delete enc;
        return nullptr;
    }

    MFT_OUTPUT_STREAM_INFO outStreamInfo = {};
    if (SUCCEEDED(mft->GetOutputStreamInfo(enc->outputStreamId, &outStreamInfo))) {
        enc->providesOutputSamples =
            (outStreamInfo.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
        enc->outputSampleSize = outStreamInfo.cbSize > 0 ? outStreamInfo.cbSize : 4096;
    }

    mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return enc;
}

OPENUU_MEDIA_API void openuu_aac_encoder_destroy(OpenUUWinAacEncoder *enc) {
    if (!enc) return;
    if (enc->mft) {
        enc->mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
    delete enc;
}

OPENUU_MEDIA_API int32_t openuu_aac_encoder_encode_pcm16(
    OpenUUWinAacEncoder *enc,
    const int16_t *pcm_samples,
    int32_t frame_count,
    uint64_t timestamp_us,
    uint8_t *out_aac,
    int32_t out_capacity
) {
    if (!enc || !enc->mft || !pcm_samples || frame_count <= 0 || !out_aac || out_capacity < 64) {
        return -1;
    }

    const DWORD byteLen = static_cast<DWORD>(frame_count * enc->channels * sizeof(int16_t));
    ComPtr<IMFMediaBuffer> inBuf;
    if (FAILED(MFCreateMemoryBuffer(byteLen, &inBuf)) || !inBuf) return -2;

    BYTE *dst = nullptr;
    if (FAILED(inBuf->Lock(&dst, nullptr, nullptr)) || !dst) return -3;
    std::memcpy(dst, pcm_samples, byteLen);
    inBuf->Unlock();
    inBuf->SetCurrentLength(byteLen);

    ComPtr<IMFSample> inSample;
    if (FAILED(MFCreateSample(&inSample)) || !inSample) return -4;
    inSample->AddBuffer(inBuf.Get());
    inSample->SetSampleTime(static_cast<LONGLONG>(timestamp_us) * 10);
    inSample->SetSampleDuration(static_cast<LONGLONG>(frame_count) * 10000000LL / std::max(1, enc->sampleRate));

    HRESULT hrIn = enc->mft->ProcessInput(enc->inputStreamId, inSample.Get(), 0);
    if (FAILED(hrIn) && hrIn != MF_E_NOTACCEPTING) {
        return -5;
    }

    MFT_OUTPUT_DATA_BUFFER outData = {};
    outData.dwStreamID = enc->outputStreamId;
    ComPtr<IMFSample> allocSample;
    if (!enc->providesOutputSamples) {
        if (FAILED(MFCreateSample(&allocSample))) return -6;
        ComPtr<IMFMediaBuffer> outMem;
        if (FAILED(MFCreateMemoryBuffer(std::max<DWORD>(enc->outputSampleSize, 4096), &outMem))) return -6;
        allocSample->AddBuffer(outMem.Get());
        outData.pSample = allocSample.Get();
    }

    DWORD status = 0;
    HRESULT hrOut = enc->mft->ProcessOutput(0, 1, &outData, &status);
    if (outData.pEvents) {
        outData.pEvents->Release();
        outData.pEvents = nullptr;
    }

    if (hrIn == MF_E_NOTACCEPTING) {
        enc->mft->ProcessInput(enc->inputStreamId, inSample.Get(), 0);
    }

    if (hrOut == MF_E_TRANSFORM_NEED_MORE_INPUT || FAILED(hrOut)) {
        if (enc->providesOutputSamples && outData.pSample) outData.pSample->Release();
        return 0;
    }

    int32_t written = 0;
    if (outData.pSample) {
        ComPtr<IMFMediaBuffer> contig;
        if (SUCCEEDED(outData.pSample->ConvertToContiguousBuffer(&contig)) && contig) {
            BYTE *ptr = nullptr;
            DWORD curLen = 0;
            if (SUCCEEDED(contig->Lock(&ptr, nullptr, &curLen)) && ptr && curLen > 0) {
                // Strip ADTS header if present so payload is always pure raw AAC-LC access unit
                DWORD offset = 0;
                if (curLen > 7 && ptr[0] == 0xFF && (ptr[1] & 0xF0) == 0xF0) {
                    offset = (ptr[1] & 0x01) == 0 ? 9 : 7;
                }
                if (curLen > offset) {
                    int32_t payloadLen = static_cast<int32_t>(curLen - offset);
                    if (payloadLen <= out_capacity) {
                        std::memcpy(out_aac, ptr + offset, static_cast<size_t>(payloadLen));
                        written = payloadLen;
                    }
                }
                contig->Unlock();
            }
        }
        if (enc->providesOutputSamples) {
            outData.pSample->Release();
        }
    }
    return written;
}

static bool configure_aac_decoder_output(OpenUUWinAacDecoder *dec) {
    if (!dec || !dec->mft) return false;
    // Prefer 16-bit PCM directly; fall back to 32-bit IEEE Float and convert in decode
    for (int pass = 0; pass < 2; ++pass) {
        const GUID wantSub = (pass == 0) ? MFAudioFormat_PCM : MFAudioFormat_Float;
        for (DWORD idx = 0; idx < 32; ++idx) {
            ComPtr<IMFMediaType> avail;
            if (FAILED(dec->mft->GetOutputAvailableType(dec->outputStreamId, idx, &avail)) || !avail) break;
            GUID sub = GUID_NULL;
            avail->GetGUID(MF_MT_SUBTYPE, &sub);
            UINT32 ch = 0, sr = 0;
            avail->GetUINT32(MF_MT_AUDIO_NUM_CHANNELS, &ch);
            avail->GetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, &sr);
            if (sub == wantSub &&
                (ch == 0 || ch == static_cast<UINT32>(dec->channels)) &&
                (sr == 0 || sr == static_cast<UINT32>(dec->sampleRate))) {
                if (SUCCEEDED(dec->mft->SetOutputType(dec->outputStreamId, avail.Get(), 0))) {
                    dec->outputIsFloat = (pass == 1);
                    MFT_OUTPUT_STREAM_INFO info = {};
                    if (SUCCEEDED(dec->mft->GetOutputStreamInfo(dec->outputStreamId, &info))) {
                        dec->providesOutputSamples =
                            (info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
                        dec->outputSampleSize = info.cbSize > 0 ? info.cbSize : 16384;
                    }
                    return true;
                }
            }
        }
    }
    return false;
}

OPENUU_MEDIA_API OpenUUWinAacDecoder *openuu_aac_decoder_create(
    int32_t sample_rate,
    int32_t channels
) {
    ensure_mf_started();
    if (FAILED(g_mfInitHr)) return nullptr;

    sample_rate = sample_rate > 0 ? sample_rate : 48000;
    channels = std::clamp(channels, 1, 2);

    MFT_REGISTER_TYPE_INFO inInfo = {};
    inInfo.guidMajorType = MFMediaType_Audio;
    inInfo.guidSubtype = MFAudioFormat_AAC;

    IMFActivate **activates = nullptr;
    UINT32 count = 0;
    HRESULT hr = MFTEnumEx(
        MFT_CATEGORY_AUDIO_DECODER,
        MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER,
        &inInfo,
        nullptr,
        &activates,
        &count
    );
    if (FAILED(hr) || count == 0 || !activates) {
        return nullptr;
    }

    ComPtr<IMFTransform> mft;
    for (UINT32 i = 0; i < count; ++i) {
        if (SUCCEEDED(activates[i]->ActivateObject(IID_PPV_ARGS(&mft))) && mft) {
            break;
        }
    }
    for (UINT32 i = 0; i < count; ++i) activates[i]->Release();
    CoTaskMemFree(activates);
    if (!mft) return nullptr;

    auto *dec = new OpenUUWinAacDecoder();
    dec->mft = mft;
    dec->sampleRate = sample_rate;
    dec->channels = channels;

    DWORD inCount = 0, outCount = 0;
    if (SUCCEEDED(mft->GetStreamCount(&inCount, &outCount)) && inCount >= 1 && outCount >= 1) {
        if (FAILED(mft->GetStreamIDs(1, &dec->inputStreamId, 1, &dec->outputStreamId))) {
            dec->inputStreamId = 0;
            dec->outputStreamId = 0;
        }
    }

    // Microsoft AAC Decoder MFT requires 12-byte HEAACWAVEINFO header + 2-byte AudioSpecificConfig in MF_MT_USER_DATA
    uint8_t userData[14] = {};
    userData[0] = 0;    // wPayloadType = 0 (raw AAC)
    userData[1] = 0;
    userData[2] = 0xFE; // wAudioProfileLevelIndication = unspecified
    userData[3] = 0;
    build_aac_lc_asc(sample_rate, channels, &userData[12]);

    ComPtr<IMFMediaType> inType;
    MFCreateMediaType(&inType);
    inType->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Audio);
    inType->SetGUID(MF_MT_SUBTYPE, MFAudioFormat_AAC);
    inType->SetUINT32(MF_MT_AUDIO_SAMPLES_PER_SECOND, static_cast<UINT32>(sample_rate));
    inType->SetUINT32(MF_MT_AUDIO_NUM_CHANNELS, static_cast<UINT32>(channels));
    inType->SetUINT32(MF_MT_AAC_PAYLOAD_TYPE, 0);
    inType->SetUINT32(MF_MT_AUDIO_BITS_PER_SAMPLE, 16);
    inType->SetUINT32(MF_MT_AUDIO_BLOCK_ALIGNMENT, 1);
    inType->SetBlob(MF_MT_USER_DATA, userData, sizeof(userData));

    if (FAILED(mft->SetInputType(dec->inputStreamId, inType.Get(), 0)) || !configure_aac_decoder_output(dec)) {
        delete dec;
        return nullptr;
    }

    mft->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    mft->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return dec;
}

OPENUU_MEDIA_API void openuu_aac_decoder_destroy(OpenUUWinAacDecoder *dec) {
    if (!dec) return;
    if (dec->mft) {
        dec->mft->ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
    }
    delete dec;
}

OPENUU_MEDIA_API int32_t openuu_aac_decoder_decode_pcm16(
    OpenUUWinAacDecoder *dec,
    const uint8_t *aac_data,
    int32_t aac_len,
    uint64_t timestamp_us,
    int16_t *out_pcm16,
    int32_t max_samples
) {
    if (!dec || !dec->mft || !aac_data || aac_len <= 0 || !out_pcm16 || max_samples <= 0) {
        return -1;
    }

    ComPtr<IMFMediaBuffer> inBuf;
    if (FAILED(MFCreateMemoryBuffer(static_cast<DWORD>(aac_len), &inBuf)) || !inBuf) return -2;

    BYTE *dst = nullptr;
    if (FAILED(inBuf->Lock(&dst, nullptr, nullptr)) || !dst) return -3;
    std::memcpy(dst, aac_data, static_cast<size_t>(aac_len));
    inBuf->Unlock();
    inBuf->SetCurrentLength(static_cast<DWORD>(aac_len));

    ComPtr<IMFSample> inSample;
    if (FAILED(MFCreateSample(&inSample)) || !inSample) return -4;
    inSample->AddBuffer(inBuf.Get());
    inSample->SetSampleTime(static_cast<LONGLONG>(timestamp_us) * 10);

    HRESULT hrIn = dec->mft->ProcessInput(dec->inputStreamId, inSample.Get(), 0);
    if (FAILED(hrIn) && hrIn != MF_E_NOTACCEPTING) {
        return -5;
    }

    int32_t totalSamples = 0;
    for (int iter = 0; iter < 8; ++iter) {
        MFT_OUTPUT_DATA_BUFFER outData = {};
        outData.dwStreamID = dec->outputStreamId;
        ComPtr<IMFSample> allocSample;
        if (!dec->providesOutputSamples) {
            if (FAILED(MFCreateSample(&allocSample))) break;
            ComPtr<IMFMediaBuffer> outMem;
            if (FAILED(MFCreateMemoryBuffer(std::max<DWORD>(dec->outputSampleSize, 16384), &outMem))) break;
            allocSample->AddBuffer(outMem.Get());
            outData.pSample = allocSample.Get();
        }

        DWORD status = 0;
        HRESULT hrOut = dec->mft->ProcessOutput(0, 1, &outData, &status);
        if (outData.pEvents) {
            outData.pEvents->Release();
            outData.pEvents = nullptr;
        }

        if (hrOut == MF_E_TRANSFORM_STREAM_CHANGE) {
            if (configure_aac_decoder_output(dec)) continue;
            break;
        }
        if (hrOut == MF_E_TRANSFORM_NEED_MORE_INPUT || FAILED(hrOut)) {
            if (dec->providesOutputSamples && outData.pSample) outData.pSample->Release();
            break;
        }

        if (outData.pSample) {
            ComPtr<IMFMediaBuffer> contig;
            if (SUCCEEDED(outData.pSample->ConvertToContiguousBuffer(&contig)) && contig) {
                BYTE *ptr = nullptr;
                DWORD curLen = 0;
                if (SUCCEEDED(contig->Lock(&ptr, nullptr, &curLen)) && ptr && curLen > 0) {
                    if (dec->outputIsFloat) {
                        int32_t count = static_cast<int32_t>(curLen / sizeof(float));
                        const float *fPtr = reinterpret_cast<const float *>(ptr);
                        int32_t toCopy = std::min(count, max_samples - totalSamples);
                        for (int32_t i = 0; i < toCopy; ++i) {
                            float s = std::clamp(fPtr[i], -1.0f, 1.0f);
                            out_pcm16[totalSamples + i] = static_cast<int16_t>(s * 32767.0f);
                        }
                        totalSamples += toCopy;
                    } else {
                        int32_t count = static_cast<int32_t>(curLen / sizeof(int16_t));
                        int32_t toCopy = std::min(count, max_samples - totalSamples);
                        if (toCopy > 0) {
                            std::memcpy(out_pcm16 + totalSamples, ptr, static_cast<size_t>(toCopy) * sizeof(int16_t));
                            totalSamples += toCopy;
                        }
                    }
                    contig->Unlock();
                }
            }
            if (dec->providesOutputSamples) outData.pSample->Release();
        }
    }

    if (hrIn == MF_E_NOTACCEPTING) {
        dec->mft->ProcessInput(dec->inputStreamId, inSample.Get(), 0);
    }
    return totalSamples;
}

OPENUU_MEDIA_API OpenUUWasapiLoopback *openuu_wasapi_loopback_create(uint8_t mute_host_speakers) {
    ensure_mf_started();

    ComPtr<IMMDeviceEnumerator> enumerator;
    HRESULT hr = CoCreateInstance(
        kClsidMMDeviceEnumerator,
        nullptr,
        CLSCTX_ALL,
        kIidIMMDeviceEnumerator,
        reinterpret_cast<void **>(enumerator.GetAddressOf())
    );
    if (FAILED(hr) || !enumerator) return nullptr;

    ComPtr<IMMDevice> device;
    if (FAILED(enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device)) || !device) {
        return nullptr;
    }

    ComPtr<IAudioClient> audioClient;
    if (FAILED(device->Activate(kIidIAudioClient, CLSCTX_ALL, nullptr, reinterpret_cast<void **>(audioClient.GetAddressOf()))) || !audioClient) {
        return nullptr;
    }

    WAVEFORMATEX wfx = {};
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = 2;
    wfx.nSamplesPerSec = 48000;
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = 4;
    wfx.nAvgBytesPerSec = 48000 * 4;

    // 40ms low-latency loopback buffer with kernel resampler to canonical 48kHz stereo S16LE
    const REFERENCE_TIME hnsBufferDuration = 40 * 10000;
    hr = audioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
        hnsBufferDuration,
        0,
        &wfx,
        nullptr
    );
    if (FAILED(hr)) {
        return nullptr;
    }

    ComPtr<IAudioCaptureClient> captureClient;
    if (FAILED(audioClient->GetService(kIidIAudioCaptureClient, reinterpret_cast<void **>(captureClient.GetAddressOf()))) || !captureClient) {
        return nullptr;
    }

    if (FAILED(audioClient->Start())) {
        return nullptr;
    }

    auto *cap = new OpenUUWasapiLoopback();
    cap->device = device;
    cap->audioClient = audioClient;
    cap->captureClient = captureClient;
    cap->started = true;

    device->Activate(
        kIidIAudioEndpointVolume,
        CLSCTX_ALL,
        nullptr,
        reinterpret_cast<void **>(cap->endpointVolume.GetAddressOf())
    );

    if (mute_host_speakers != 0) {
        openuu_wasapi_loopback_set_mute_host(cap, 1);
    }
    return cap;
}

OPENUU_MEDIA_API void openuu_wasapi_loopback_set_mute_host(
    OpenUUWasapiLoopback *cap,
    uint8_t mute_host_speakers
) {
    if (!cap || !cap->endpointVolume) return;
    if (mute_host_speakers != 0) {
        if (!cap->didMuteHost) {
            BOOL alreadyMuted = FALSE;
            if (SUCCEEDED(cap->endpointVolume->GetMute(&alreadyMuted)) && !alreadyMuted) {
                if (SUCCEEDED(cap->endpointVolume->SetMute(TRUE, nullptr))) {
                    cap->didMuteHost = true;
                }
            }
        }
    } else {
        if (cap->didMuteHost) {
            cap->endpointVolume->SetMute(FALSE, nullptr);
            cap->didMuteHost = false;
        }
    }
}

OPENUU_MEDIA_API int32_t openuu_wasapi_loopback_read_pcm16(
    OpenUUWasapiLoopback *cap,
    int16_t *out_pcm16,
    int32_t max_frames
) {
    if (!cap || !cap->captureClient || !out_pcm16 || max_frames <= 0) return -1;

    int32_t framesWritten = 0;
    while (framesWritten < max_frames) {
        UINT32 packetLength = 0;
        HRESULT hr = cap->captureClient->GetNextPacketSize(&packetLength);
        if (FAILED(hr)) return -2;
        if (packetLength == 0) break;

        BYTE *data = nullptr;
        UINT32 numFrames = 0;
        DWORD flags = 0;
        hr = cap->captureClient->GetBuffer(&data, &numFrames, &flags, nullptr, nullptr);
        if (FAILED(hr)) return -3;

        int32_t toCopy = std::min<int32_t>(static_cast<int32_t>(numFrames), max_frames - framesWritten);
        if (toCopy > 0) {
            if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0 || !data) {
                std::memset(out_pcm16 + framesWritten * 2, 0, static_cast<size_t>(toCopy) * 4);
            } else {
                std::memcpy(out_pcm16 + framesWritten * 2, data, static_cast<size_t>(toCopy) * 4);
            }
            framesWritten += toCopy;
        }

        cap->captureClient->ReleaseBuffer(numFrames);
        if (toCopy < static_cast<int32_t>(numFrames)) break;
    }
    return framesWritten;
}

OPENUU_MEDIA_API void openuu_wasapi_loopback_destroy(OpenUUWasapiLoopback *cap) {
    if (!cap) return;
    openuu_wasapi_loopback_set_mute_host(cap, 0);
    if (cap->audioClient && cap->started) {
        cap->audioClient->Stop();
    }
    delete cap;
}

OPENUU_MEDIA_API OpenUUWaveOutPlayer *openuu_waveout_create(int32_t sample_rate, int32_t channels) {
    sample_rate = sample_rate > 0 ? sample_rate : 48000;
    channels = std::clamp(channels, 1, 2);

    WAVEFORMATEX wfx = {};
    wfx.wFormatTag = WAVE_FORMAT_PCM;
    wfx.nChannels = static_cast<WORD>(channels);
    wfx.nSamplesPerSec = static_cast<DWORD>(sample_rate);
    wfx.wBitsPerSample = 16;
    wfx.nBlockAlign = static_cast<WORD>(channels * 2);
    wfx.nAvgBytesPerSec = static_cast<DWORD>(sample_rate * wfx.nBlockAlign);

    HWAVEOUT hOut = nullptr;
    MMRESULT mm = waveOutOpen(&hOut, WAVE_MAPPER, &wfx, 0, 0, CALLBACK_NULL);
    if (mm != MMSYSERR_NOERROR || !hOut) {
        return nullptr;
    }

    auto *player = new OpenUUWaveOutPlayer();
    player->hWaveOut = hOut;
    for (int i = 0; i < OpenUUWaveOutPlayer::kRingSlots; ++i) {
        player->buffers[i].resize(OpenUUWaveOutPlayer::kSlotBytes, 0);
        player->headers[i].lpData = reinterpret_cast<LPSTR>(player->buffers[i].data());
        player->headers[i].dwBufferLength = OpenUUWaveOutPlayer::kSlotBytes;
        player->headers[i].dwFlags = WHDR_DONE;
        waveOutPrepareHeader(hOut, &player->headers[i], sizeof(WAVEHDR));
        player->headers[i].dwFlags |= WHDR_DONE;
    }
    return player;
}

OPENUU_MEDIA_API int32_t openuu_waveout_submit_pcm16(
    OpenUUWaveOutPlayer *player,
    const int16_t *pcm_samples,
    int32_t sample_count
) {
    if (!player || !player->hWaveOut || !pcm_samples || sample_count <= 0) return -1;
    std::lock_guard<std::mutex> lock(player->mtx);

    int inFlight = 0;
    for (int i = 0; i < OpenUUWaveOutPlayer::kRingSlots; ++i) {
        if ((player->headers[i].dwFlags & WHDR_DONE) == 0) {
            ++inFlight;
        }
    }

    // Jitter ceiling (~210ms): reset queued audio if network burst accumulated > 10 packets
    if (inFlight >= OpenUUWaveOutPlayer::kMaxInFlight) {
        waveOutReset(player->hWaveOut);
        for (int i = 0; i < OpenUUWaveOutPlayer::kRingSlots; ++i) {
            player->headers[i].dwFlags |= WHDR_DONE;
        }
    }

    int slot = -1;
    for (int step = 0; step < OpenUUWaveOutPlayer::kRingSlots; ++step) {
        int cand = (player->nextSlot + step) % OpenUUWaveOutPlayer::kRingSlots;
        if ((player->headers[cand].dwFlags & WHDR_DONE) != 0) {
            slot = cand;
            player->nextSlot = (cand + 1) % OpenUUWaveOutPlayer::kRingSlots;
            break;
        }
    }
    if (slot < 0) return 0;

    DWORD byteLen = static_cast<DWORD>(std::min<size_t>(
        static_cast<size_t>(sample_count) * sizeof(int16_t),
        OpenUUWaveOutPlayer::kSlotBytes
    ));
    std::memcpy(player->buffers[slot].data(), pcm_samples, byteLen);
    player->headers[slot].dwBufferLength = byteLen;
    player->headers[slot].dwFlags &= ~WHDR_DONE;

    MMRESULT mm = waveOutWrite(player->hWaveOut, &player->headers[slot], sizeof(WAVEHDR));
    if (mm != MMSYSERR_NOERROR) {
        player->headers[slot].dwFlags |= WHDR_DONE;
        return -2;
    }
    return 1;
}

OPENUU_MEDIA_API void openuu_waveout_reset(OpenUUWaveOutPlayer *player) {
    if (!player || !player->hWaveOut) return;
    std::lock_guard<std::mutex> lock(player->mtx);
    waveOutReset(player->hWaveOut);
}

OPENUU_MEDIA_API void openuu_waveout_destroy(OpenUUWaveOutPlayer *player) {
    if (!player) return;
    if (player->hWaveOut) {
        waveOutReset(player->hWaveOut);
        for (int i = 0; i < OpenUUWaveOutPlayer::kRingSlots; ++i) {
            waveOutUnprepareHeader(player->hWaveOut, &player->headers[i], sizeof(WAVEHDR));
        }
        waveOutClose(player->hWaveOut);
        player->hWaveOut = nullptr;
    }
    delete player;
}

} // extern "C"

#include <android/log.h>
#include <jni.h>
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>

#include "openuu_core.h"

#define LOG_TAG "OpenUUJNI"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

namespace {

JavaVM *g_vm = nullptr;
jclass g_string_cls = nullptr;
jmethodID g_string_init_bytes_charset = nullptr;
jstring g_utf8_charset = nullptr;

struct RuntimeEntry {
    uint64_t id = 0;
    OpenUURuntime *rt = nullptr;
    jobject listener_global = nullptr;
    jmethodID mid_on_control = nullptr;
    jmethodID mid_on_video = nullptr;
    jmethodID mid_on_audio = nullptr;
    jmethodID mid_on_status = nullptr;
    jmethodID mid_on_probe_result = nullptr;
};

std::mutex g_registry_mu;
std::unordered_map<uint64_t, std::shared_ptr<RuntimeEntry>> g_registry;
std::atomic<uint64_t> g_next_id{1};

JNIEnv *get_jni_env() {
    if (!g_vm) return nullptr;
    JNIEnv *env = nullptr;
    jint status = g_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    if (status == JNI_OK && env != nullptr) {
        return env;
    }
    if (status == JNI_EDETACHED) {
        JavaVMAttachArgs args{};
        args.version = JNI_VERSION_1_6;
        args.name = "OpenUUCoreCb";
        args.group = nullptr;
        if (g_vm->AttachCurrentThreadAsDaemon(&env, &args) == JNI_OK) {
            return env;
        }
    }
    return nullptr;
}

/// Converts standard UTF-8 C-string (including 4-byte emojis) safely into a Java String without
/// triggering ART CheckJNI Modified-UTF-8 aborts.
jstring utf8_to_jstring(JNIEnv *env, const char *str) {
    if (!env) return nullptr;
    if (!str) str = "";
    const size_t len = std::strlen(str);
    if (len == 0) {
        return env->NewStringUTF("");
    }
    if (g_string_cls && g_string_init_bytes_charset && g_utf8_charset) {
        jbyteArray bytes = env->NewByteArray(static_cast<jsize>(len));
        if (!bytes) return nullptr;
        env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(len), reinterpret_cast<const jbyte *>(str));
        jobject result = env->NewObject(g_string_cls, g_string_init_bytes_charset, bytes, g_utf8_charset);
        env->DeleteLocalRef(bytes);
        if (env->ExceptionCheck()) {
            env->ExceptionDescribe();
            env->ExceptionClear();
            return env->NewStringUTF("");
        }
        return static_cast<jstring>(result);
    }
    return env->NewStringUTF(str);
}

std::string jstring_to_utf8(JNIEnv *env, jstring jstr) {
    if (!env || !jstr) return {};
    const char *chars = env->GetStringUTFChars(jstr, nullptr);
    if (!chars) return {};
    std::string out(chars);
    env->ReleaseStringUTFChars(jstr, chars);
    return out;
}

std::shared_ptr<RuntimeEntry> lookup_entry(uint64_t id) {
    std::lock_guard<std::mutex> lock(g_registry_mu);
    auto it = g_registry.find(id);
    if (it == g_registry.end()) return nullptr;
    return it->second;
}

void clear_if_exception(JNIEnv *env) {
    if (env && env->ExceptionCheck()) {
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
}

void cb_on_control(void *user_ctx, const char *event_json) {
    const uint64_t id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(user_ctx));
    auto entry = lookup_entry(id);
    if (!entry || !entry->listener_global || !entry->mid_on_control) return;

    JNIEnv *env = get_jni_env();
    if (!env) return;

    jobject listener_local = env->NewLocalRef(entry->listener_global);
    if (!listener_local) return;

    jstring jjson = utf8_to_jstring(env, event_json);
    if (jjson) {
        env->CallVoidMethod(listener_local, entry->mid_on_control, jjson);
        clear_if_exception(env);
        env->DeleteLocalRef(jjson);
    }
    env->DeleteLocalRef(listener_local);
}

void cb_on_video(
    void *user_ctx,
    uint8_t codec,
    uint8_t flags,
    uint32_t window_id,
    uint64_t timestamp_us,
    uint16_t width,
    uint16_t height,
    const uint8_t *data,
    size_t data_len
) {
    if (!data || data_len == 0) return;
    const uint64_t id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(user_ctx));
    auto entry = lookup_entry(id);
    if (!entry || !entry->listener_global || !entry->mid_on_video) return;

    JNIEnv *env = get_jni_env();
    if (!env) return;

    jobject listener_local = env->NewLocalRef(entry->listener_global);
    if (!listener_local) return;

    jbyteArray jbytes = env->NewByteArray(static_cast<jsize>(data_len));
    if (jbytes) {
        env->SetByteArrayRegion(
            jbytes,
            0,
            static_cast<jsize>(data_len),
            reinterpret_cast<const jbyte *>(data)
        );
        env->CallVoidMethod(
            listener_local,
            entry->mid_on_video,
            static_cast<jint>(codec),
            static_cast<jint>(flags),
            static_cast<jint>(window_id),
            static_cast<jlong>(timestamp_us),
            static_cast<jint>(width),
            static_cast<jint>(height),
            jbytes
        );
        clear_if_exception(env);
        env->DeleteLocalRef(jbytes);
    }
    env->DeleteLocalRef(listener_local);
}

void cb_on_audio(
    void *user_ctx,
    uint8_t codec,
    uint8_t flags,
    uint8_t channels,
    uint32_t sample_rate,
    uint64_t timestamp_us,
    const uint8_t *data,
    size_t data_len
) {
    if (!data || data_len == 0) return;
    const uint64_t id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(user_ctx));
    auto entry = lookup_entry(id);
    if (!entry || !entry->listener_global || !entry->mid_on_audio) return;

    JNIEnv *env = get_jni_env();
    if (!env) return;

    jobject listener_local = env->NewLocalRef(entry->listener_global);
    if (!listener_local) return;

    jbyteArray jbytes = env->NewByteArray(static_cast<jsize>(data_len));
    if (jbytes) {
        env->SetByteArrayRegion(
            jbytes,
            0,
            static_cast<jsize>(data_len),
            reinterpret_cast<const jbyte *>(data)
        );
        env->CallVoidMethod(
            listener_local,
            entry->mid_on_audio,
            static_cast<jint>(codec),
            static_cast<jint>(flags),
            static_cast<jint>(channels),
            static_cast<jint>(sample_rate),
            static_cast<jlong>(timestamp_us),
            jbytes
        );
        clear_if_exception(env);
        env->DeleteLocalRef(jbytes);
    }
    env->DeleteLocalRef(listener_local);
}

void cb_on_status(void *user_ctx, const char *status) {
    const uint64_t id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(user_ctx));
    auto entry = lookup_entry(id);
    if (!entry || !entry->listener_global || !entry->mid_on_status) return;

    JNIEnv *env = get_jni_env();
    if (!env) return;

    jobject listener_local = env->NewLocalRef(entry->listener_global);
    if (!listener_local) return;

    jstring jmsg = utf8_to_jstring(env, status);
    if (jmsg) {
        env->CallVoidMethod(listener_local, entry->mid_on_status, jmsg);
        clear_if_exception(env);
        env->DeleteLocalRef(jmsg);
    }
    env->DeleteLocalRef(listener_local);
}

void cb_on_probe_result(void *user_ctx, const char *results_json) {
    const uint64_t id = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(user_ctx));
    auto entry = lookup_entry(id);
    if (!entry || !entry->listener_global || !entry->mid_on_probe_result) return;

    JNIEnv *env = get_jni_env();
    if (!env) return;

    jobject listener_local = env->NewLocalRef(entry->listener_global);
    if (!listener_local) return;

    jstring jjson = utf8_to_jstring(env, results_json);
    if (jjson) {
        env->CallVoidMethod(listener_local, entry->mid_on_probe_result, jjson);
        clear_if_exception(env);
        env->DeleteLocalRef(jjson);
    }
    env->DeleteLocalRef(listener_local);
}

} // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void * /*reserved*/) {
    g_vm = vm;
    JNIEnv *env = nullptr;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK || !env) {
        return JNI_ERR;
    }

    jclass str_local = env->FindClass("java/lang/String");
    if (str_local) {
        g_string_cls = static_cast<jclass>(env->NewGlobalRef(str_local));
        g_string_init_bytes_charset = env->GetMethodID(str_local, "<init>", "([BLjava/lang/String;)V");
        env->DeleteLocalRef(str_local);
    }
    jstring utf8_local = env->NewStringUTF("UTF-8");
    if (utf8_local) {
        g_utf8_charset = static_cast<jstring>(env->NewGlobalRef(utf8_local));
        env->DeleteLocalRef(utf8_local);
    }

    LOGI("OpenUUJNI loaded successfully");
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeInitAndroidContext(
    JNIEnv *env,
    jclass /*clazz*/,
    jobject context
) {
    if (!env || !context) return -1;
    jint rc = openuu_init_android_tls(env, context);
    LOGI("openuu_init_android_tls returned %d", rc);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSetAppDirs(
    JNIEnv *env,
    jclass /*clazz*/,
    jstring config_dir,
    jstring cache_dir
) {
    std::string cfg = jstring_to_utf8(env, config_dir);
    std::string cache = jstring_to_utf8(env, cache_dir);
    return openuu_set_app_dirs(
        config_dir ? cfg.c_str() : nullptr,
        cache_dir ? cache.c_str() : nullptr
    );
}

extern "C" JNIEXPORT jlong JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeCreateRuntime(
    JNIEnv *env,
    jclass /*clazz*/,
    jstring device_name,
    jobject listener
) {
    std::string name = jstring_to_utf8(env, device_name);
    OpenUURuntime *rt = openuu_runtime_create(name.empty() ? "OpenUU-Android" : name.c_str());
    if (!rt) {
        LOGE("openuu_runtime_create returned null");
        return 0;
    }

    auto entry = std::make_shared<RuntimeEntry>();
    entry->id = g_next_id.fetch_add(1);
    entry->rt = rt;
    if (listener) {
        entry->listener_global = env->NewGlobalRef(listener);
        jclass cls = env->GetObjectClass(listener);
        if (cls) {
            entry->mid_on_control = env->GetMethodID(cls, "onControl", "(Ljava/lang/String;)V");
            entry->mid_on_video = env->GetMethodID(cls, "onVideo", "(IIIJII[B)V");
            entry->mid_on_audio = env->GetMethodID(cls, "onAudio", "(IIIIJ[B)V");
            entry->mid_on_status = env->GetMethodID(cls, "onStatus", "(Ljava/lang/String;)V");
            entry->mid_on_probe_result = env->GetMethodID(cls, "onProbeResult", "(Ljava/lang/String;)V");
            env->DeleteLocalRef(cls);
        }
        clear_if_exception(env);
    }

    {
        std::lock_guard<std::mutex> lock(g_registry_mu);
        g_registry[entry->id] = entry;
    }

    void *ctx = reinterpret_cast<void *>(static_cast<uintptr_t>(entry->id));
    openuu_set_audio_callback(rt, cb_on_audio, ctx);

    return static_cast<jlong>(entry->id);
}

extern "C" JNIEXPORT void JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeDestroyRuntime(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle
) {
    const uint64_t id = static_cast<uint64_t>(handle);
    std::shared_ptr<RuntimeEntry> entry;
    {
        std::lock_guard<std::mutex> lock(g_registry_mu);
        auto it = g_registry.find(id);
        if (it != g_registry.end()) {
            entry = it->second;
            g_registry.erase(it);
        }
    }
    if (!entry) return;
    if (entry->rt) {
        openuu_set_audio_callback(entry->rt, nullptr, nullptr);
        openuu_disconnect(entry->rt);
        openuu_runtime_destroy(entry->rt);
        entry->rt = nullptr;
    }
    if (entry->listener_global && env) {
        env->DeleteGlobalRef(entry->listener_global);
        entry->listener_global = nullptr;
    }
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeStartDiscovery(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_start_discovery(entry->rt);
}

extern "C" JNIEXPORT jstring JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeListPeersJson(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return utf8_to_jstring(env, "[]");
    char *raw = openuu_list_peers_json(entry->rt);
    if (!raw) return utf8_to_jstring(env, "[]");
    jstring out = utf8_to_jstring(env, raw);
    openuu_free_string(raw);
    return out;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeConnectSmart(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring target,
    jint default_port,
    jstring pin
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string target_s = jstring_to_utf8(env, target);
    std::string pin_s = jstring_to_utf8(env, pin);
    void *ctx = reinterpret_cast<void *>(static_cast<uintptr_t>(entry->id));
    return openuu_connect_smart(
        entry->rt,
        target_s.c_str(),
        static_cast<uint16_t>(default_port),
        pin_s.c_str(),
        cb_on_control,
        cb_on_video,
        cb_on_status,
        ctx
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeConnectClient(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring host_ip,
    jint port,
    jstring pin
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string host_s = jstring_to_utf8(env, host_ip);
    std::string pin_s = jstring_to_utf8(env, pin);
    void *ctx = reinterpret_cast<void *>(static_cast<uintptr_t>(entry->id));
    return openuu_connect_client(
        entry->rt,
        host_s.c_str(),
        static_cast<uint16_t>(port),
        pin_s.c_str(),
        cb_on_control,
        cb_on_video,
        cb_on_status,
        ctx
    );
}

extern "C" JNIEXPORT void JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeDisconnect(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return;
    openuu_disconnect(entry->rt);
}

extern "C" JNIEXPORT jstring JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeGetIdentityJson(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return utf8_to_jstring(env, "{}");
    char *raw = openuu_get_identity_json(entry->rt);
    if (!raw) return utf8_to_jstring(env, "{}");
    jstring out = utf8_to_jstring(env, raw);
    openuu_free_string(raw);
    return out;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSetWanConfigJson(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring wan_json
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string json_s = jstring_to_utf8(env, wan_json);
    return openuu_set_wan_config_json(entry->rt, json_s.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeRemoveTrustedPeer(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring device_id
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string id_s = jstring_to_utf8(env, device_id);
    return openuu_remove_trusted_peer(entry->rt, id_s.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeProbeDevicesOnline(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring queries_json
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string q_s = jstring_to_utf8(env, queries_json);
    void *ctx = reinterpret_cast<void *>(static_cast<uintptr_t>(entry->id));
    return openuu_probe_devices_online(entry->rt, q_s.c_str(), cb_on_probe_result, ctx);
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeRequestAppList(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_request_app_list(entry->rt);
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeStartRemoteSession(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring bundle_id,
    jint window_id
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string bid = jstring_to_utf8(env, bundle_id);
    return openuu_start_remote_session(entry->rt, bid.c_str(), static_cast<uint32_t>(window_id));
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeStopRemoteSession(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_stop_remote_session(entry->rt, static_cast<uint32_t>(window_id));
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendMouseEvent(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jfloat x,
    jfloat y,
    jint event_type,
    jint button,
    jint click_count,
    jint modifiers
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_send_mouse_event(
        entry->rt,
        static_cast<uint32_t>(window_id),
        x,
        y,
        static_cast<uint8_t>(event_type),
        static_cast<uint32_t>(button),
        static_cast<uint32_t>(click_count),
        static_cast<uint32_t>(modifiers)
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendScrollEvent(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jfloat x,
    jfloat y,
    jfloat delta_x,
    jfloat delta_y,
    jboolean is_continuous,
    jint modifiers
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_send_scroll_event(
        entry->rt,
        static_cast<uint32_t>(window_id),
        x,
        y,
        delta_x,
        delta_y,
        is_continuous == JNI_TRUE,
        static_cast<uint32_t>(modifiers)
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendKeyEvent(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jint key_code,
    jboolean is_down,
    jboolean is_repeat,
    jint modifiers
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_send_key_event(
        entry->rt,
        static_cast<uint32_t>(window_id),
        static_cast<uint32_t>(key_code),
        is_down == JNI_TRUE,
        is_repeat == JNI_TRUE,
        static_cast<uint32_t>(modifiers)
    );
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendTextCommit(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jstring utf8_text
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string text = jstring_to_utf8(env, utf8_text);
    return openuu_send_text_commit(entry->rt, static_cast<uint32_t>(window_id), text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeRequestKeyframe(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_request_keyframe(entry->rt, static_cast<uint32_t>(window_id));
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendAudioControl(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jboolean enabled,
    jboolean mute_host
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_send_audio_control(entry->rt, enabled == JNI_TRUE, mute_host == JNI_TRUE);
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendResizeWindow(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jfloat width,
    jfloat height
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    return openuu_send_resize_window(entry->rt, static_cast<uint32_t>(window_id), width, height);
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendClipboardText(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring content_hash,
    jstring utf8_text
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string hash = jstring_to_utf8(env, content_hash);
    std::string text = jstring_to_utf8(env, utf8_text);
    return openuu_send_clipboard_text(entry->rt, hash.c_str(), text.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendClipboardImage(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring content_hash,
    jstring mime_type,
    jbyteArray image_data
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt || !image_data) return -1;
    std::string hash = jstring_to_utf8(env, content_hash);
    std::string mime = jstring_to_utf8(env, mime_type);
    jsize len = env->GetArrayLength(image_data);
    if (len <= 0) return -2;
    jbyte *bytes = env->GetByteArrayElements(image_data, nullptr);
    if (!bytes) return -3;
    jint rc = openuu_send_clipboard_image(
        entry->rt,
        hash.c_str(),
        mime.c_str(),
        reinterpret_cast<const uint8_t *>(bytes),
        static_cast<size_t>(len)
    );
    env->ReleaseByteArrayElements(image_data, bytes, JNI_ABORT);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendFileBlob(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jint window_id,
    jfloat x,
    jfloat y,
    jstring blob_id,
    jstring filename,
    jstring local_path
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string bid = jstring_to_utf8(env, blob_id);
    std::string fname = jstring_to_utf8(env, filename);
    std::string path = jstring_to_utf8(env, local_path);
    jint rc = openuu_send_file_blob(
        entry->rt,
        static_cast<uint32_t>(window_id),
        x,
        y,
        bid.c_str(),
        fname.c_str(),
        path.c_str()
    );
    return rc;
}

extern "C" JNIEXPORT jstring JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeGenerateAccessCode(
    JNIEnv *env,
    jclass /*clazz*/,
    jboolean strong_alphanumeric
) {
    char *raw = openuu_generate_access_code(strong_alphanumeric == JNI_TRUE);
    if (!raw) {
        return utf8_to_jstring(env, "");
    }
    jstring out = utf8_to_jstring(env, raw);
    openuu_free_string(raw);
    return out;
}

extern "C" JNIEXPORT jstring JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeStartHost(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jint bind_port,
    jstring preferred_pin
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) {
        return utf8_to_jstring(env, "");
    }

    char pin_buf[64];
    std::memset(pin_buf, 0, sizeof(pin_buf));
    std::string pref = jstring_to_utf8(env, preferred_pin);
    if (!pref.empty() && pref.size() < sizeof(pin_buf)) {
        std::memcpy(pin_buf, pref.data(), pref.size());
        pin_buf[pref.size()] = '\0';
    }

    void *ctx = reinterpret_cast<void *>(static_cast<uintptr_t>(entry->id));
    uint16_t bound_port = openuu_start_host(
        entry->rt,
        static_cast<uint16_t>(bind_port),
        pin_buf,
        sizeof(pin_buf),
        cb_on_control,
        cb_on_video,
        cb_on_status,
        ctx
    );
    if (bound_port == 0) {
        return utf8_to_jstring(env, "");
    }
    std::string result = std::to_string(bound_port) + ":" + std::string(pin_buf);
    return utf8_to_jstring(env, result.c_str());
}

extern "C" JNIEXPORT void JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeStopHost(
    JNIEnv * /*env*/,
    jclass /*clazz*/,
    jlong handle
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return;
    openuu_stop_host(entry->rt);
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendAppListJson(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring apps_json
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string json = jstring_to_utf8(env, apps_json);
    return openuu_send_app_list_json(entry->rt, json.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendWindowTopologyJson(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring windows_json
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string json = jstring_to_utf8(env, windows_json);
    return openuu_send_window_topology_json(entry->rt, json.c_str());
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendVideoFrame(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jint codec,
    jint flags,
    jint window_id,
    jlong timestamp_us,
    jint width,
    jint height,
    jbyteArray data,
    jint data_len
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt || !data || data_len <= 0) return -1;
    jsize arr_len = env->GetArrayLength(data);
    jsize valid_len = data_len <= arr_len ? data_len : arr_len;
    if (valid_len <= 0) return -2;

    jbyte *bytes = env->GetByteArrayElements(data, nullptr);
    if (!bytes) return -3;
    jint rc = openuu_send_video_frame(
        entry->rt,
        static_cast<uint8_t>(codec),
        static_cast<uint8_t>(flags),
        static_cast<uint32_t>(window_id),
        static_cast<uint64_t>(timestamp_us),
        static_cast<uint16_t>(width),
        static_cast<uint16_t>(height),
        reinterpret_cast<const uint8_t *>(bytes),
        static_cast<size_t>(valid_len)
    );
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendAudioFrame(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jint codec,
    jint flags,
    jint channels,
    jint sample_rate,
    jlong timestamp_us,
    jbyteArray data,
    jint data_len
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt || !data || data_len <= 0) return -1;
    jsize arr_len = env->GetArrayLength(data);
    jsize valid_len = data_len <= arr_len ? data_len : arr_len;
    if (valid_len <= 0) return -2;

    jbyte *bytes = env->GetByteArrayElements(data, nullptr);
    if (!bytes) return -3;
    jint rc = openuu_send_audio_frame(
        entry->rt,
        static_cast<uint8_t>(codec),
        static_cast<uint8_t>(flags),
        static_cast<uint8_t>(channels),
        static_cast<uint32_t>(sample_rate),
        static_cast<uint64_t>(timestamp_us),
        reinterpret_cast<const uint8_t *>(bytes),
        static_cast<size_t>(valid_len)
    );
    env->ReleaseByteArrayElements(data, bytes, JNI_ABORT);
    return rc;
}

extern "C" JNIEXPORT jint JNICALL
Java_ren_onekb_openuu_OpenUUNativeBridge_nativeSendNotification(
    JNIEnv *env,
    jclass /*clazz*/,
    jlong handle,
    jstring app_bundle_id,
    jstring title,
    jstring subtitle,
    jstring body,
    jlong timestamp_ms
) {
    auto entry = lookup_entry(static_cast<uint64_t>(handle));
    if (!entry || !entry->rt) return -1;
    std::string bid = jstring_to_utf8(env, app_bundle_id);
    std::string t = jstring_to_utf8(env, title);
    std::string sub = jstring_to_utf8(env, subtitle);
    std::string b = jstring_to_utf8(env, body);
    return openuu_send_notification(
        entry->rt,
        bid.c_str(),
        t.c_str(),
        sub.c_str(),
        b.c_str(),
        static_cast<uint64_t>(timestamp_ms)
    );
}

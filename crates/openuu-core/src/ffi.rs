use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::net::SocketAddr;
use std::os::raw::{c_char, c_void};
use std::path::PathBuf;
use std::slice;
use std::str::FromStr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use bytes::Bytes;
use iroh::{EndpointAddr, PublicKey, TransportAddr};
use serde::{Deserialize, Serialize};
use tokio::runtime::Runtime;
use tokio::sync::Notify;

use crate::discovery::DiscoveryService;
use crate::identity::{
    generate_pairing_pin, generate_strong_access_code, normalize_device_code, now_epoch_ms,
    DeviceIdentity, TrustedPeer, WanConfig,
};
use crate::protocol::{pb, VideoCodec, VideoFrame};
use crate::transport::{
    accept_client_session_guarded, accept_iroh_session, bind_host_endpoint, connect_to_host_pinned,
    connect_via_iroh, resolve_host_socket_addr, IncomingChannels, PeerSession,
};
use crate::wan::{
    bind_iroh_endpoint, bind_iroh_endpoint_with_role, compute_pin_proof_hex,
    coord_register_heartbeat, coord_resolve_batch, coord_resolve_code, coord_resolve_endpoint,
    parse_custom_relay_urls, BatchProbeQueryItem, OpenUUTicket, PinRateLimiter, RATE_LIMIT_ERR,
    TICKET_PREFIX, UNIFIED_AUTH_OR_CODE_ERR,
};

pub type OpenUUControlCallback = extern "C" fn(*mut c_void, *const c_char);
pub type OpenUUVideoCallback = extern "C" fn(
    *mut c_void,
    u8,
    u8,
    u32,
    u64,
    u16,
    u16,
    *const u8,
    usize,
);
pub type OpenUUStatusCallback = extern "C" fn(*mut c_void, *const c_char);

#[derive(Clone, Copy)]
struct SendPtr(usize);

impl SendPtr {
    fn new(ptr: *mut c_void) -> Self {
        Self(ptr as usize)
    }
    fn as_ptr(self) -> *mut c_void {
        self.0 as *mut c_void
    }
}

static SHARED_TOKIO_RT: OnceLock<Runtime> = OnceLock::new();
static SHARED_IDENTITIES: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<DeviceIdentity>>>>> =
    OnceLock::new();
static SHARED_DISCOVERIES: OnceLock<Mutex<HashMap<PathBuf, Arc<Mutex<Option<DiscoveryService>>>>>> =
    OnceLock::new();

fn shared_tokio_runtime() -> Option<&'static Runtime> {
    if let Some(rt) = SHARED_TOKIO_RT.get() {
        return Some(rt);
    }
    let created = Runtime::new().ok()?;
    let _ = SHARED_TOKIO_RT.set(created);
    SHARED_TOKIO_RT.get()
}

fn shared_identity_and_discovery(
    config_dir: Option<&std::path::Path>,
    device_name: Option<String>,
) -> Option<(
    Arc<Mutex<DeviceIdentity>>,
    Arc<Mutex<Option<DiscoveryService>>>,
)> {
    let loaded = DeviceIdentity::load_or_create(config_dir, device_name).ok()?;
    let key_path = loaded.config_path.clone();

    let id_map = SHARED_IDENTITIES.get_or_init(|| Mutex::new(HashMap::new()));
    let id_arc = {
        let mut guard = id_map.lock().ok()?;
        guard
            .entry(key_path.clone())
            .or_insert_with(|| Arc::new(Mutex::new(loaded)))
            .clone()
    };

    let disc_map = SHARED_DISCOVERIES.get_or_init(|| Mutex::new(HashMap::new()));
    let disc_arc = {
        let mut guard = disc_map.lock().ok()?;
        guard
            .entry(key_path)
            .or_insert_with(|| Arc::new(Mutex::new(None)))
            .clone()
    };

    Some((id_arc, disc_arc))
}

pub struct OpenUURuntime {
    tokio_rt: &'static Runtime,
    identity: Arc<Mutex<DeviceIdentity>>,
    discovery: Arc<Mutex<Option<DiscoveryService>>>,
    host_endpoint: Mutex<Option<quinn::Endpoint>>,
    iroh_host_endpoint: Arc<Mutex<Option<iroh::Endpoint>>>,
    iroh_client_endpoint: Arc<Mutex<Option<iroh::Endpoint>>>,
    active_session: Arc<Mutex<Option<Arc<PeerSession>>>>,
    host_ticket: Arc<Mutex<String>>,
    coord_status: Arc<Mutex<String>>,
    host_running: Arc<AtomicBool>,
    host_stop_notify: Arc<Notify>,
    pin_limiter: PinRateLimiter,
    seq: AtomicU64,
}

impl OpenUURuntime {
    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    fn snapshot_identity(&self) -> DeviceIdentity {
        self.identity.lock().unwrap().clone()
    }
}

#[derive(Serialize)]
struct IdentitySnapshotJson {
    device_id: String,
    device_name: String,
    device_code: String,
    formatted_code: String,
    endpoint_id: String,
    host_ticket: String,
    coord_status: String,
    wan_config: WanConfig,
    trusted_peers: Vec<TrustedPeer>,
}

#[derive(Serialize, Deserialize)]
struct WindowSummaryJson {
    window_id: u32,
    #[serde(default)]
    parent_window_id: u32,
    #[serde(default)]
    kind: i32,
    #[serde(default)]
    rel_x: f32,
    #[serde(default)]
    rel_y: f32,
    #[serde(default)]
    width: f32,
    #[serde(default)]
    height: f32,
    #[serde(default)]
    title: String,
    #[serde(default)]
    icon_png_b64: String,
}

#[derive(Serialize, Deserialize)]
struct AppSummaryJson {
    bundle_id: String,
    name: String,
    pid: u32,
    window_count: u32,
    #[serde(default)]
    icon_png_b64: String,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum ControlEventJson {
    ListAppsReq,
    ListAppsResp {
        apps: Vec<AppSummaryJson>,
    },
    StartSession {
        bundle_id: String,
        window_id: u32,
    },
    StopSession {
        window_id: u32,
    },
    Mouse {
        window_id: u32,
        x: f32,
        y: f32,
        event_type: i32,
        button: u32,
        click_count: u32,
        modifiers: u32,
    },
    Scroll {
        window_id: u32,
        x: f32,
        y: f32,
        delta_x: f32,
        delta_y: f32,
        is_continuous: bool,
        modifiers: u32,
    },
    Key {
        window_id: u32,
        key_code: u32,
        is_down: bool,
        is_repeat: bool,
        modifiers: u32,
    },
    TextCommit {
        window_id: u32,
        text: String,
    },
    RequestKeyframe {
        window_id: u32,
    },
    ResizeWindow {
        window_id: u32,
        width: f32,
        height: f32,
    },
    Notification {
        app_bundle_id: String,
        title: String,
        subtitle: String,
        body: String,
        timestamp_ms: u64,
    },
    BadgeUpdate {
        app_bundle_id: String,
        badge_text: String,
    },
    Cursor {
        kind: String,
        hotspot_x: f32,
        hotspot_y: f32,
    },
    WindowTopology {
        windows: Vec<WindowSummaryJson>,
    },
    ClipboardSync {
        content_hash: String,
        clip_kind: i32,
        text: String,
        mime_type: String,
        image_b64: String,
    },
    FileDrop {
        window_id: u32,
        x: f32,
        y: f32,
        blob_id: String,
        local_path: String,
    },
    LinkQuality {
        link_mode: String,
        rtt_ms: u32,
        remote_addr: String,
    },
    Other {
        debug: String,
    },
}

fn envelope_to_json(env: &pb::ControlEnvelope) -> String {
    let evt = match &env.payload {
        Some(pb::control_envelope::Payload::ListAppsReq(_)) => ControlEventJson::ListAppsReq,
        Some(pb::control_envelope::Payload::ListAppsResp(resp)) => {
            ControlEventJson::ListAppsResp {
                apps: resp
                    .apps
                    .iter()
                    .map(|a| AppSummaryJson {
                        bundle_id: a.bundle_id.clone(),
                        name: a.name.clone(),
                        pid: a.pid,
                        window_count: a.window_count,
                        icon_png_b64: a.icon_png_b64.clone(),
                    })
                    .collect(),
            }
        }
        Some(pb::control_envelope::Payload::StartSession(req)) => ControlEventJson::StartSession {
            bundle_id: req.bundle_id.clone(),
            window_id: req.window_id,
        },
        Some(pb::control_envelope::Payload::StopSession(req)) => ControlEventJson::StopSession {
            window_id: req.window_id,
        },
        Some(pb::control_envelope::Payload::MouseEvent(m)) => ControlEventJson::Mouse {
            window_id: m.window_id,
            x: m.x,
            y: m.y,
            event_type: m.r#type,
            button: m.button,
            click_count: m.click_count,
            modifiers: m.modifiers,
        },
        Some(pb::control_envelope::Payload::ScrollEvent(s)) => ControlEventJson::Scroll {
            window_id: s.window_id,
            x: s.x,
            y: s.y,
            delta_x: s.delta_x,
            delta_y: s.delta_y,
            is_continuous: s.is_continuous,
            modifiers: s.modifiers,
        },
        Some(pb::control_envelope::Payload::KeyEvent(k)) => ControlEventJson::Key {
            window_id: k.window_id,
            key_code: k.key_code,
            is_down: k.is_down,
            is_repeat: k.is_repeat,
            modifiers: k.modifiers,
        },
        Some(pb::control_envelope::Payload::TextCommit(t)) => ControlEventJson::TextCommit {
            window_id: t.window_id,
            text: t.text.clone(),
        },
        Some(pb::control_envelope::Payload::RequestKeyframe(r)) => {
            ControlEventJson::RequestKeyframe {
                window_id: r.window_id,
            }
        }
        Some(pb::control_envelope::Payload::Notification(n)) => ControlEventJson::Notification {
            app_bundle_id: n.app_bundle_id.clone(),
            title: n.title.clone(),
            subtitle: n.subtitle.clone(),
            body: n.body.clone(),
            timestamp_ms: n.timestamp_ms,
        },
        Some(pb::control_envelope::Payload::BadgeUpdate(b)) => ControlEventJson::BadgeUpdate {
            app_bundle_id: b.app_bundle_id.clone(),
            badge_text: b.badge_text.clone(),
        },
        Some(pb::control_envelope::Payload::CursorUpdate(c)) => ControlEventJson::Cursor {
            kind: c.kind.clone(),
            hotspot_x: c.hotspot_x,
            hotspot_y: c.hotspot_y,
        },
        Some(pb::control_envelope::Payload::WindowTopology(wt)) => {
            ControlEventJson::WindowTopology {
                windows: wt
                    .windows
                    .iter()
                    .map(|w| WindowSummaryJson {
                        window_id: w.window_id,
                        parent_window_id: w.parent_window_id,
                        kind: w.kind,
                        rel_x: w.rel_x,
                        rel_y: w.rel_y,
                        width: w.width,
                        height: w.height,
                        title: w.title.clone(),
                        icon_png_b64: w.icon_png_b64.clone(),
                    })
                    .collect(),
            }
        }
        Some(pb::control_envelope::Payload::ResizeWindow(rw)) => ControlEventJson::ResizeWindow {
            window_id: rw.window_id,
            width: rw.width,
            height: rw.height,
        },
        Some(pb::control_envelope::Payload::ClipboardSync(cb)) => ControlEventJson::ClipboardSync {
            content_hash: cb.content_hash.clone(),
            clip_kind: cb.kind,
            text: cb.text.clone(),
            mime_type: cb.mime_type.clone(),
            image_b64: if cb.image_data.is_empty() {
                String::new()
            } else {
                BASE64_STD.encode(&cb.image_data)
            },
        },
        Some(pb::control_envelope::Payload::FileDrop(fd)) => ControlEventJson::FileDrop {
            window_id: fd.window_id,
            x: fd.x,
            y: fd.y,
            blob_id: fd.blob_id.clone(),
            local_path: fd.filename.clone(),
        },
        other => ControlEventJson::Other {
            debug: format!("{other:?}"),
        },
    };
    serde_json::to_string(&evt).unwrap_or_else(|_| "{}".to_string())
}

fn emit_status(cb: Option<OpenUUStatusCallback>, ctx: SendPtr, msg: &str) {
    if let Some(cb) = cb {
        if let Ok(cstr) = CString::new(msg) {
            cb(ctx.as_ptr(), cstr.as_ptr());
        }
    }
}

fn emit_control_json(cb: Option<OpenUUControlCallback>, ctx: SendPtr, evt: &ControlEventJson) {
    if let Some(cb) = cb {
        if let Ok(json) = serde_json::to_string(evt) {
            if let Ok(cstr) = CString::new(json) {
                cb(ctx.as_ptr(), cstr.as_ptr());
            }
        }
    }
}

/// Spawns control/video callback forwarders AND a periodic link-quality observer (notifying Swift immediately
/// when an Iroh Relay session upgrades to Direct UDP/IPv6 hole-punching or RTT shifts!).
fn attach_session_callbacks(
    session: Arc<PeerSession>,
    mut channels: IncomingChannels,
    active_session: Arc<Mutex<Option<Arc<PeerSession>>>>,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    ctx: SendPtr,
    disconnect_msg: &'static str,
) {
    if let Ok(mut guard) = active_session.lock() {
        if let Some(prev) = guard.replace(Arc::clone(&session)) {
            prev.close();
        }
    }

    // Emit initial link quality immediately
    let initial_link = session.link_telemetry();
    emit_control_json(
        on_control,
        ctx,
        &ControlEventJson::LinkQuality {
            link_mode: initial_link.mode.as_str().to_string(),
            rtt_ms: initial_link.rtt_ms,
            remote_addr: initial_link.remote_addr.clone(),
        },
    );

    let session_alive = Arc::new(AtomicBool::new(true));
    let alive_ctrl = Arc::clone(&session_alive);
    tokio::spawn(async move {
        while let Some(env) = channels.control_rx.recv().await {
            if let Some(cb) = on_control {
                let json = envelope_to_json(&env);
                if let Ok(cstr) = CString::new(json) {
                    cb(ctx.as_ptr(), cstr.as_ptr());
                }
            }
        }
        alive_ctrl.store(false, Ordering::Relaxed);
        emit_status(on_status, ctx, disconnect_msg);
    });

    tokio::spawn(async move {
        while let Some(frame) = channels.video_rx.recv().await {
            if let Some(cb) = on_video {
                cb(
                    ctx.as_ptr(),
                    frame.codec as u8,
                    frame.flags,
                    frame.window_id,
                    frame.timestamp_us,
                    frame.width,
                    frame.height,
                    frame.payload.as_ptr(),
                    frame.payload.len(),
                );
            }
        }
    });

    // Link path & RTT monitor (detects seamless Relay -> Direct P2P upgrade!)
    tokio::spawn(async move {
        let mut last_mode = initial_link.mode;
        let mut last_rtt = initial_link.rtt_ms;
        loop {
            tokio::time::sleep(Duration::from_secs(2)).await;
            if !session_alive.load(Ordering::Relaxed) {
                break;
            }
            let cur = session.link_telemetry();
            let rtt_diff = cur.rtt_ms.abs_diff(last_rtt);
            if cur.mode != last_mode || rtt_diff >= 8 {
                last_mode = cur.mode;
                last_rtt = cur.rtt_ms;
                emit_control_json(
                    on_control,
                    ctx,
                    &ControlEventJson::LinkQuality {
                        link_mode: cur.mode.as_str().to_string(),
                        rtt_ms: cur.rtt_ms,
                        remote_addr: cur.remote_addr,
                    },
                );
            }
        }
    });
}

#[no_mangle]
pub unsafe extern "C" fn openuu_init_android_tls(
    jni_env: *mut c_void,
    app_context: *mut c_void,
) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        #[cfg(target_os = "android")]
        {
            if jni_env.is_null() || app_context.is_null() {
                return -1;
            }
            let mut unowned_env = jni::EnvUnowned::from_raw(jni_env as *mut jni::sys::JNIEnv);
            let ok = unowned_env
                .with_env(|env| -> Result<bool, jni::errors::Error> {
                    let context =
                        jni::objects::JObject::from_raw(env, app_context as jni::sys::jobject);
                    rustls_platform_verifier::android::init_with_env(env, context)?;
                    Ok(true)
                })
                .resolve::<jni::errors::LogErrorAndDefault>();
            if ok {
                0
            } else {
                -2
            }
        }
        #[cfg(not(target_os = "android"))]
        {
            let _ = (jni_env, app_context);
            0
        }
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub unsafe extern "C" fn openuu_set_app_dirs(
    config_dir: *const c_char,
    cache_dir: *const c_char,
) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let cfg = if config_dir.is_null() {
            None
        } else {
            match CStr::from_ptr(config_dir).to_str() {
                Ok(s) if !s.trim().is_empty() => Some(PathBuf::from(s.trim())),
                Ok(_) => None,
                Err(_) => return -1,
            }
        };
        let cache = if cache_dir.is_null() {
            None
        } else {
            match CStr::from_ptr(cache_dir).to_str() {
                Ok(s) if !s.trim().is_empty() => Some(PathBuf::from(s.trim())),
                Ok(_) => None,
                Err(_) => return -2,
            }
        };
        crate::identity::set_global_app_dirs(cfg, cache);
        0
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub unsafe extern "C" fn openuu_runtime_create(device_name: *const c_char) -> *mut OpenUURuntime {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let name = if device_name.is_null() {
            None
        } else {
            CStr::from_ptr(device_name)
                .to_str()
                .ok()
                .filter(|s| !s.is_empty())
                .map(String::from)
        };
        let Some(tokio_rt) = shared_tokio_runtime() else {
            return std::ptr::null_mut();
        };
        let Some((identity, discovery)) = shared_identity_and_discovery(None, name) else {
            return std::ptr::null_mut();
        };
        let rt = Box::new(OpenUURuntime {
            tokio_rt,
            identity,
            discovery,
            host_endpoint: Mutex::new(None),
            iroh_host_endpoint: Arc::new(Mutex::new(None)),
            iroh_client_endpoint: Arc::new(Mutex::new(None)),
            active_session: Arc::new(Mutex::new(None)),
            host_ticket: Arc::new(Mutex::new(String::new())),
            coord_status: Arc::new(Mutex::new("未启动".to_string())),
            host_running: Arc::new(AtomicBool::new(false)),
            host_stop_notify: Arc::new(Notify::new()),
            pin_limiter: PinRateLimiter::default(),
            seq: AtomicU64::new(10),
        });
        Box::into_raw(rt)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn openuu_runtime_create_with_dir(
    device_name: *const c_char,
    config_dir: *const c_char,
) -> *mut OpenUURuntime {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let name = if device_name.is_null() {
            None
        } else {
            CStr::from_ptr(device_name)
                .to_str()
                .ok()
                .filter(|s| !s.is_empty())
                .map(String::from)
        };
        let dir_path = if config_dir.is_null() {
            None
        } else {
            CStr::from_ptr(config_dir)
                .to_str()
                .ok()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(PathBuf::from)
        };
        let Some(tokio_rt) = shared_tokio_runtime() else {
            return std::ptr::null_mut();
        };
        let Some((identity, discovery)) =
            shared_identity_and_discovery(dir_path.as_deref(), name)
        else {
            return std::ptr::null_mut();
        };
        let rt = Box::new(OpenUURuntime {
            tokio_rt,
            identity,
            discovery,
            host_endpoint: Mutex::new(None),
            iroh_host_endpoint: Arc::new(Mutex::new(None)),
            iroh_client_endpoint: Arc::new(Mutex::new(None)),
            active_session: Arc::new(Mutex::new(None)),
            host_ticket: Arc::new(Mutex::new(String::new())),
            coord_status: Arc::new(Mutex::new("未启动".to_string())),
            host_running: Arc::new(AtomicBool::new(false)),
            host_stop_notify: Arc::new(Notify::new()),
            pin_limiter: PinRateLimiter::default(),
            seq: AtomicU64::new(10),
        });
        Box::into_raw(rt)
    }))
    .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn openuu_runtime_destroy(rt: *mut OpenUURuntime) {
    if !rt.is_null() {
        drop(Box::from_raw(rt));
    }
}

#[no_mangle]
pub unsafe extern "C" fn openuu_get_identity_json(rt: *mut OpenUURuntime) -> *mut c_char {
    if rt.is_null() {
        return std::ptr::null_mut();
    }
    let rt = &*rt;
    let id = rt.snapshot_identity();
    let host_ticket = rt
        .host_ticket
        .lock()
        .ok()
        .map(|g| g.clone())
        .unwrap_or_default();
    let coord_status = rt
        .coord_status
        .lock()
        .ok()
        .map(|g| g.clone())
        .unwrap_or_default();
    let mut trusted: Vec<TrustedPeer> = id.trusted_peers.values().cloned().collect();
    trusted.sort_by(|a, b| b.last_connected_ms.cmp(&a.last_connected_ms));

    let snap = IdentitySnapshotJson {
        device_id: id.device_id.clone(),
        device_name: id.device_name.clone(),
        device_code: id.device_code.clone(),
        formatted_code: id.formatted_device_code(),
        endpoint_id: id.endpoint_id_str(),
        host_ticket,
        coord_status,
        wan_config: id.wan_config,
        trusted_peers: trusted,
    };
    let json = serde_json::to_string(&snap).unwrap_or_else(|_| "{}".to_string());
    CString::new(json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn openuu_set_wan_config_json(
    rt: *mut OpenUURuntime,
    wan_json: *const c_char,
) -> i32 {
    if rt.is_null() || wan_json.is_null() {
        return -1;
    }
    let rt = &*rt;
    let Ok(json_str) = CStr::from_ptr(wan_json).to_str() else {
        return -2;
    };
    let Ok(mut cfg) = serde_json::from_str::<WanConfig>(json_str) else {
        return -3;
    };
    if cfg.relay_url.trim() == crate::identity::DEFAULT_RELAY_URL
        && cfg.relay_auth_token.trim().is_empty()
    {
        cfg.relay_auth_token = crate::identity::default_relay_auth_token();
    }
    if let Ok(mut guard) = rt.identity.lock() {
        if guard.set_wan_config(cfg).is_err() {
            return -4;
        }
    }
    // Reset cached client iroh endpoint so next connect picks up updated HK relay / TLS config
    if let Ok(mut ep_guard) = rt.iroh_client_endpoint.lock() {
        if let Some(ep) = ep_guard.take() {
            rt.tokio_rt.spawn(async move {
                ep.close().await;
            });
        }
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn openuu_remove_trusted_peer(
    rt: *mut OpenUURuntime,
    device_id: *const c_char,
) -> i32 {
    if rt.is_null() || device_id.is_null() {
        return -1;
    }
    let rt = &*rt;
    let Ok(id_str) = CStr::from_ptr(device_id).to_str() else {
        return -2;
    };
    let Ok(mut guard) = rt.identity.lock() else {
        return -3;
    };
    match guard.remove_trusted_peer(id_str) {
        Ok(true) => 0,
        Ok(false) => 1,
        Err(_) => -4,
    }
}

#[derive(Deserialize)]
struct DeviceProbeQuery {
    id: String,
    target: String,
    #[serde(default)]
    pin: String,
    #[serde(default)]
    endpoint_id: String,
}

#[derive(Serialize)]
struct DeviceProbeResult {
    id: String,
    online: bool,
    via: String, // "lan", "wan", or "offline"
    remote_name: String,
}

#[no_mangle]
pub unsafe extern "C" fn openuu_probe_devices_online(
    rt: *mut OpenUURuntime,
    queries_json: *const c_char,
    on_result: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        openuu_probe_devices_online_inner(rt, queries_json, on_result, user_ctx)
    }))
    .unwrap_or(-99)
}

unsafe fn openuu_probe_devices_online_inner(
    rt: *mut OpenUURuntime,
    queries_json: *const c_char,
    on_result: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    if rt.is_null() || queries_json.is_null() {
        return -1;
    }
    let rt_ref = &*rt;
    let Ok(json_str) = CStr::from_ptr(queries_json).to_str() else {
        return -2;
    };
    let Ok(queries) = serde_json::from_str::<Vec<DeviceProbeQuery>>(json_str) else {
        return -3;
    };
    let cur_id = rt_ref.snapshot_identity();
    let lan_peers = rt_ref
        .discovery
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|d| d.list_peers()))
        .unwrap_or_default();
    let ctx = SendPtr::new(user_ctx);

    rt_ref.tokio_rt.spawn(async move {
        let coord_url = cur_id.wan_config.coord_url.trim().to_string();
        let allow_insecure = cur_id.wan_config.allow_insecure_tls;

        let mut results = Vec::with_capacity(queries.len());
        let mut wan_pending: Vec<BatchProbeQueryItem> = Vec::new();

        for q in queries {
            let raw = q.target.trim().to_string();
            let norm_code = if raw.starts_with(TICKET_PREFIX) {
                OpenUUTicket::decode(&raw)
                    .map(|t| normalize_device_code(&t.device_code))
                    .unwrap_or_default()
            } else {
                normalize_device_code(&raw)
            };

            // 1. Check LAN mDNS cache first (zero cloud request cost)
            if let Some(lp) = lan_peers.iter().find(|p| {
                p.device_id == raw
                    || (!norm_code.is_empty() && p.device_code == norm_code)
                    || p.addresses.iter().any(|ip| raw.starts_with(&ip.to_string()))
            }) {
                results.push(DeviceProbeResult {
                    id: q.id,
                    online: true,
                    via: "lan".to_string(),
                    remote_name: lp.device_name.clone(),
                });
                continue;
            }

            // Look up trusted 256-bit `endpoint_id` if already paired, or compute salted PIN proof
            let ep_id = if !q.endpoint_id.trim().is_empty() {
                q.endpoint_id.trim().to_string()
            } else {
                cur_id
                    .find_trusted_by_code_or_id(if norm_code.len() == 9 {
                        &norm_code
                    } else {
                        &raw
                    })
                    .map(|tp| tp.endpoint_id.clone())
                    .unwrap_or_default()
            };
            let pin_proof = if ep_id.is_empty() && norm_code.len() == 9 && !q.pin.trim().is_empty() {
                compute_pin_proof_hex(&norm_code, &q.pin)
            } else {
                String::new()
            };

            if !coord_url.is_empty() && (!ep_id.is_empty() || !pin_proof.is_empty()) {
                wan_pending.push(BatchProbeQueryItem {
                    id: q.id,
                    endpoint_id: ep_id,
                    device_code: norm_code,
                    pin_proof_hex: pin_proof,
                });
            } else {
                results.push(DeviceProbeResult {
                    id: q.id,
                    online: false,
                    via: "offline".to_string(),
                    remote_name: String::new(),
                });
            }
        }

        // 2. Batch-resolve all authorized WAN entries in ONE single anti-enumeration HTTP call (`/v1/resolve-batch`)
        if !wan_pending.is_empty() {
            let batch_map = tokio::time::timeout(
                Duration::from_millis(3500),
                coord_resolve_batch(&coord_url, allow_insecure, &wan_pending),
            )
            .await
            .ok()
            .and_then(|r| r.ok())
            .unwrap_or_default();

            for item in wan_pending {
                if let Some(resp) = batch_map.get(&item.id) {
                    if resp.found && resp.online {
                        results.push(DeviceProbeResult {
                            id: item.id,
                            online: true,
                            via: "wan".to_string(),
                            remote_name: resp.device_name.clone(),
                        });
                        continue;
                    }
                }
                results.push(DeviceProbeResult {
                    id: item.id,
                    online: false,
                    via: "offline".to_string(),
                    remote_name: String::new(),
                });
            }
        }

        if let Ok(out_json) = serde_json::to_string(&results) {
            emit_status(on_result, ctx, &out_json);
        }
    });

    0
}

#[no_mangle]
pub unsafe extern "C" fn openuu_generate_access_code(strong_alphanumeric: bool) -> *mut c_char {
    let code = if strong_alphanumeric {
        generate_strong_access_code()
    } else {
        generate_pairing_pin()
    };
    CString::new(code)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn openuu_start_host(
    rt: *mut OpenUURuntime,
    bind_port: u16,
    out_pin_buf: *mut c_char,
    out_pin_buf_len: usize,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> u16 {
    if rt.is_null() {
        return 0;
    }
    let rt = &*rt;
    let existing_pin = if !out_pin_buf.is_null() && out_pin_buf_len > 1 && *out_pin_buf != 0 {
        CStr::from_ptr(out_pin_buf)
            .to_str()
            .ok()
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(String::from)
    } else {
        None
    };
    let pin = existing_pin.unwrap_or_else(generate_pairing_pin);
    if !out_pin_buf.is_null() && out_pin_buf_len > pin.len() {
        let bytes = pin.as_bytes();
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_pin_buf as *mut u8, bytes.len());
        *out_pin_buf.add(bytes.len()) = 0;
    }

    let id_snap = rt.snapshot_identity();
    let bind_addr: SocketAddr = format!("0.0.0.0:{bind_port}").parse().unwrap();
    let endpoint = match rt
        .tokio_rt
        .block_on(async { bind_host_endpoint(&id_snap, bind_addr) })
    {
        Ok(ep) => ep,
        Err(e) => {
            emit_status(
                on_status,
                SendPtr::new(user_ctx),
                &format!("host bind error: {e}"),
            );
            return 0;
        }
    };
    let local_port = endpoint.local_addr().map(|a| a.port()).unwrap_or(0);
    if let Ok(mut ep_guard) = rt.host_endpoint.lock() {
        *ep_guard = Some(endpoint.clone());
    }
    rt.host_running.store(true, Ordering::SeqCst);

    // Advertise over LAN mDNS including 9-digit device code + EndpointId for same-LAN auto-acceleration
    if let Ok(mut disc_guard) = rt.discovery.lock() {
        if disc_guard.is_none() {
            if let Ok(d) = DiscoveryService::new() {
                *disc_guard = Some(d);
            }
        }
        if let Some(d) = disc_guard.as_ref() {
            let _ = d.advertise_ext(
                &id_snap.device_id,
                &id_snap.device_name,
                std::env::consts::OS,
                local_port,
                &id_snap.device_code,
                &id_snap.endpoint_id_str(),
            );
        }
    }

    let ctx = SendPtr::new(user_ctx);
    emit_status(
        on_status,
        ctx,
        &format!(
            "host listening on port {local_port} | 设备码: {} (PIN: {pin})",
            id_snap.formatted_device_code()
        ),
    );

    // 1. Spawn LAN / Dual-Stack IPv6 Quinn accept loop
    let identity_arc_lan = Arc::clone(&rt.identity);
    let active_session_lan = Arc::clone(&rt.active_session);
    let limiter_lan = rt.pin_limiter.clone();
    let pin_lan = pin.clone();
    rt.tokio_rt.spawn(async move {
        loop {
            let cur_id = identity_arc_lan.lock().unwrap().clone();
            match accept_client_session_guarded(&endpoint, &cur_id, Some(&pin_lan), &limiter_lan)
                .await
            {
                Ok((session, channels, hello, verified_pk)) => {
                    if let Some(pk) = verified_pk {
                        if let Ok(mut guard) = identity_arc_lan.lock() {
                            let _ = guard.trust_peer(TrustedPeer {
                                device_id: hello.device_id.clone(),
                                device_name: hello.device_name.clone(),
                                cert_fingerprint: String::new(),
                                endpoint_id: pk,
                                device_code: String::new(),
                                last_relay_url: String::new(),
                                last_ticket: String::new(),
                                last_connected_ms: now_epoch_ms(),
                            });
                        }
                    }
                    emit_status(
                        on_status,
                        ctx,
                        &format!("client connected: {} (LAN/IP)", hello.device_name),
                    );
                    attach_session_callbacks(
                        session,
                        channels,
                        Arc::clone(&active_session_lan),
                        on_control,
                        on_video,
                        on_status,
                        ctx,
                        "client disconnected",
                    );
                }
                Err(e) => {
                    let msg = format!("{e}");
                    if msg.contains("closed") {
                        break;
                    }
                    emit_status(on_status, ctx, &format!("accept error: {e}"));
                }
            }
        }
    });

    // 2. Spawn WAN Iroh P2P/Relay Endpoint + HK Coordinator Heartbeat loop (only when bind_port > 0, i.e. real app/CLI host)
    if bind_port > 0 {
        let identity_arc_wan = Arc::clone(&rt.identity);
        let iroh_slot = Arc::clone(&rt.iroh_host_endpoint);
        let ticket_slot = Arc::clone(&rt.host_ticket);
        let coord_status_slot = Arc::clone(&rt.coord_status);
        let active_session_wan = Arc::clone(&rt.active_session);
        let host_running = Arc::clone(&rt.host_running);
        let stop_notify = Arc::clone(&rt.host_stop_notify);
        let limiter_wan = rt.pin_limiter.clone();
        let pin_wan = pin;

        rt.tokio_rt.spawn(async move {
            let init_id = identity_arc_wan.lock().unwrap().clone();
            if let Ok(mut st) = coord_status_slot.lock() {
                *st = "正在连接跨网打洞/中继网络...".to_string();
            }
            let iroh_ep = match bind_iroh_endpoint_with_role(&init_id, false, true).await {
                Ok(ep) => ep,
                Err(e) => {
                    if let Ok(mut st) = coord_status_slot.lock() {
                        *st = format!("跨网组件启动失败: {e}");
                    }
                    return;
                }
            };
            if !host_running.load(Ordering::SeqCst) {
                iroh_ep.close().await;
                return;
            }
            if let Ok(mut slot) = iroh_slot.lock() {
                *slot = Some(iroh_ep.clone());
            }

            // Publish initial ticket immediately (with LAN/IPv6 direct addrs), then refresh once Home Relay is online!
            if let Ok(t) = OpenUUTicket::from_endpoint(&iroh_ep, &init_id, local_port).encode() {
                if let Ok(mut slot) = ticket_slot.lock() {
                    *slot = t;
                }
            }

            // Background ticket refresher & HK Coordinator heartbeat task
            let ep_hb = iroh_ep.clone();
            let id_hb = Arc::clone(&identity_arc_wan);
            let ticket_hb = Arc::clone(&ticket_slot);
            let status_hb = Arc::clone(&coord_status_slot);
            let running_hb = Arc::clone(&host_running);
            let notify_hb = Arc::clone(&stop_notify);
            let pin_hb = pin_wan.clone();
            tokio::spawn(async move {
                // Wait up to 6s for home relay handshake so initial ticket captures the real active RelayUrl
                let _ = tokio::time::timeout(Duration::from_secs(6), ep_hb.online()).await;
                let mut last_registered_ticket = String::new();
                let mut last_registered_coord = String::new();
                let mut last_registered_at: Option<Instant> = None;

                loop {
                    if !running_hb.load(Ordering::SeqCst) {
                        break;
                    }
                    let cur_id = id_hb.lock().unwrap().clone();
                    let ticket_obj = OpenUUTicket::from_endpoint(&ep_hb, &cur_id, local_port);
                    let encoded_ticket = ticket_obj.encode().unwrap_or_default();
                    if let Ok(mut slot) = ticket_hb.lock() {
                        *slot = encoded_ticket.clone();
                    }

                    let has_relay = !ticket_obj.relay_urls.is_empty();
                    let coord_url = cur_id.wan_config.coord_url.trim().to_string();

                    // Quota-saving heartbeat: only call `/v1/register` when ticket/coord changed
                    // OR every 5 minutes (300s, server TTL = 12m), saving ~90% daily CF Worker requests!
                    let should_push = encoded_ticket != last_registered_ticket
                        || coord_url != last_registered_coord
                        || last_registered_at
                            .map(|t| t.elapsed() >= Duration::from_secs(300))
                            .unwrap_or(true);

                    if !coord_url.is_empty() && should_push {
                        match coord_register_heartbeat(
                            &coord_url,
                            cur_id.wan_config.allow_insecure_tls,
                            &cur_id,
                            &encoded_ticket,
                            Some(&pin_hb),
                        )
                        .await
                        {
                            Ok(resp) if resp.ok => {
                                last_registered_ticket = encoded_ticket.clone();
                                last_registered_coord = coord_url.clone();
                                last_registered_at = Some(Instant::now());
                                if !resp.assigned_code.is_empty()
                                    && resp.assigned_code != cur_id.device_code
                                {
                                    if let Ok(mut guard) = id_hb.lock() {
                                        let _ = guard.set_device_code(resp.assigned_code);
                                    }
                                    // Re-push immediately on next iteration so `pin_proof_hex` binds to new `assigned_code`
                                    last_registered_ticket.clear();
                                    continue;
                                }
                                if let Ok(mut st) = status_hb.lock() {
                                    *st = if has_relay {
                                        "跨网就绪（寻址服务 + 中继在线）".to_string()
                                    } else {
                                        "寻址服务已注册（直连 IPv6/UDP 就绪）".to_string()
                                    };
                                }
                            }
                            Ok(resp) => {
                                if let Ok(mut st) = status_hb.lock() {
                                    *st = format!("寻址注册拒绝: {}", resp.message);
                                }
                            }
                            Err(e) => {
                                if let Ok(mut st) = status_hb.lock() {
                                    *st = if has_relay {
                                        format!("中继在线（寻址服务暂不可达，可用连接串直连: {e}）")
                                    } else {
                                        format!("寻址服务连接失败: {e}")
                                    };
                                }
                            }
                        }
                    } else if coord_url.is_empty() {
                        if let Ok(mut st) = status_hb.lock() {
                            *st = if has_relay {
                                "跨网中继已就绪（未配寻址服，可复制连接串跨网直连）".to_string()
                            } else {
                                "局域网 / IPv6 直连就绪".to_string()
                            };
                        }
                    }

                    // Local zero-HTTP check every 15s so local IP/Wi-Fi changes trigger immediate re-register
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_secs(15)) => {}
                        _ = notify_hb.notified() => break,
                    }
                }
            });

            // Accept incoming WAN Iroh P2P / Relay connections
            loop {
                if !host_running.load(Ordering::SeqCst) {
                    break;
                }
                let cur_id = identity_arc_wan.lock().unwrap().clone();
                match accept_iroh_session(&iroh_ep, &cur_id, Some(&pin_wan), &limiter_wan).await {
                    Ok((session, channels, hello, verified_pk)) => {
                        if let Some(pk) = verified_pk {
                            if let Ok(mut guard) = identity_arc_wan.lock() {
                                let _ = guard.trust_peer(TrustedPeer {
                                    device_id: hello.device_id.clone(),
                                    device_name: hello.device_name.clone(),
                                    cert_fingerprint: String::new(),
                                    endpoint_id: pk,
                                    device_code: String::new(),
                                    last_relay_url: String::new(),
                                    last_ticket: String::new(),
                                    last_connected_ms: now_epoch_ms(),
                                });
                            }
                        }
                        let link = session.link_telemetry();
                        emit_status(
                            on_status,
                            ctx,
                            &format!(
                                "client connected: {} ({}, {}ms)",
                                hello.device_name,
                                link.mode.as_str(),
                                link.rtt_ms
                            ),
                        );
                        attach_session_callbacks(
                            session,
                            channels,
                            Arc::clone(&active_session_wan),
                            on_control,
                            on_video,
                            on_status,
                            ctx,
                            "client disconnected",
                        );
                    }
                    Err(e) => {
                        let msg = format!("{e}");
                        if msg.contains("closed") {
                            break;
                        }
                        emit_status(on_status, ctx, &format!("wan accept error: {e}"));
                    }
                }
            }
        });
    }

    local_port
}

#[no_mangle]
pub unsafe extern "C" fn openuu_start_discovery(rt: *mut OpenUURuntime) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        if rt.is_null() {
            return -1;
        }
        let rt = &*rt;
        let self_id = rt.snapshot_identity().device_id;
        let Ok(mut guard) = rt.discovery.lock() else {
            return -1;
        };
        if guard.is_none() {
            match DiscoveryService::new() {
                Ok(d) => *guard = Some(d),
                Err(_) => return -2,
            }
        }
        if let Some(d) = guard.as_ref() {
            if d.start_browsing(Some(self_id)).is_ok() {
                return 0;
            }
        }
        -3
    }))
    .unwrap_or(-99)
}

#[no_mangle]
pub unsafe extern "C" fn openuu_list_peers_json(rt: *mut OpenUURuntime) -> *mut c_char {
    if rt.is_null() {
        return std::ptr::null_mut();
    }
    let rt = &*rt;
    let peers = rt
        .discovery
        .lock()
        .ok()
        .and_then(|g| g.as_ref().map(|d| d.list_peers()))
        .unwrap_or_default();
    let json = serde_json::to_string(&peers).unwrap_or_else(|_| "[]".to_string());
    CString::new(json)
        .map(|s| s.into_raw())
        .unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn openuu_connect_client(
    rt: *mut OpenUURuntime,
    host_ip: *const c_char,
    port: u16,
    pin: *const c_char,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        openuu_connect_client_inner(
            rt, host_ip, port, pin, on_control, on_video, on_status, user_ctx,
        )
    }))
    .unwrap_or(-99)
}

unsafe fn openuu_connect_client_inner(
    rt: *mut OpenUURuntime,
    host_ip: *const c_char,
    port: u16,
    pin: *const c_char,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    if rt.is_null() || host_ip.is_null() || pin.is_null() {
        return -1;
    }
    let Ok(host_str) = CStr::from_ptr(host_ip).to_str() else {
        return -2;
    };
    let trimmed = host_str.trim();
    if trimmed.is_empty() {
        return -3;
    }
    // Delegate directly to smart connect if user pasted a 9-digit device code or `openuu://` ticket into Host box!
    if trimmed.starts_with(TICKET_PREFIX) || normalize_device_code(trimmed).len() == 9 {
        return openuu_connect_smart(
            rt,
            host_ip,
            port,
            pin,
            on_control,
            on_video,
            on_status,
            user_ctx,
        );
    }

    let rt_ref = &*rt;
    let Ok(pin_str) = CStr::from_ptr(pin).to_str() else {
        return -4;
    };
    let host_owned = trimmed.to_string();
    let pin_owned = pin_str.trim().to_string();
    let identity_arc = Arc::clone(&rt_ref.identity);
    let active_session = Arc::clone(&rt_ref.active_session);
    let ctx = SendPtr::new(user_ctx);

    rt_ref.tokio_rt.spawn(async move {
        emit_status(on_status, ctx, &format!("connecting to {host_owned}:{port}..."));
        let addr = match resolve_host_socket_addr(&host_owned, port).await {
            Ok(a) => a,
            Err(e) => {
                emit_status(on_status, ctx, &format!("connect failed: {e}"));
                return;
            }
        };
        let cur_id = identity_arc.lock().unwrap().clone();
        match connect_to_host_pinned(&cur_id, addr, &pin_owned, None).await {
            Ok((session, channels, ack, cert_fp, verified_pk)) => {
                if let Ok(mut guard) = identity_arc.lock() {
                    let _ = guard.trust_peer(TrustedPeer {
                        device_id: ack.device_id.clone(),
                        device_name: ack.device_name.clone(),
                        cert_fingerprint: cert_fp.unwrap_or_default(),
                        endpoint_id: verified_pk.unwrap_or_default(),
                        device_code: String::new(),
                        last_relay_url: String::new(),
                        last_ticket: format!("{host_owned}:{port}"),
                        last_connected_ms: now_epoch_ms(),
                    });
                }
                emit_status(
                    on_status,
                    ctx,
                    &format!("connected to host: {}", ack.device_name),
                );
                attach_session_callbacks(
                    session,
                    channels,
                    active_session,
                    on_control,
                    on_video,
                    on_status,
                    ctx,
                    "disconnected from host",
                );
            }
            Err(e) => {
                let msg = match e {
                    crate::error::OpenUUError::PairingRejected(ref m) => m.clone(),
                    _ => format!("{e}"),
                };
                emit_status(on_status, ctx, &format!("connect failed: {msg}"));
            }
        }
    });

    0
}

#[no_mangle]
pub unsafe extern "C" fn openuu_connect_smart(
    rt: *mut OpenUURuntime,
    target: *const c_char,
    default_port: u16,
    pin: *const c_char,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        openuu_connect_smart_inner(
            rt,
            target,
            default_port,
            pin,
            on_control,
            on_video,
            on_status,
            user_ctx,
        )
    }))
    .unwrap_or(-99)
}

unsafe fn openuu_connect_smart_inner(
    rt: *mut OpenUURuntime,
    target: *const c_char,
    default_port: u16,
    pin: *const c_char,
    on_control: Option<OpenUUControlCallback>,
    on_video: Option<OpenUUVideoCallback>,
    on_status: Option<OpenUUStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    if rt.is_null() || target.is_null() || pin.is_null() {
        return -1;
    }
    let rt_ref = &*rt;
    let Ok(target_str) = CStr::from_ptr(target).to_str() else {
        return -2;
    };
    let Ok(pin_str) = CStr::from_ptr(pin).to_str() else {
        return -3;
    };
    let raw_target = target_str.trim().to_string();
    if raw_target.is_empty() {
        return -4;
    }
    let pin_owned = pin_str.trim().to_string();
    let fallback_port = if default_port == 0 { 39481 } else { default_port };

    let identity_arc = Arc::clone(&rt_ref.identity);
    let discovery_arc = Arc::clone(&rt_ref.discovery);
    let iroh_client_slot = Arc::clone(&rt_ref.iroh_client_endpoint);
    let active_session = Arc::clone(&rt_ref.active_session);
    let ctx = SendPtr::new(user_ctx);

    rt_ref.tokio_rt.spawn(async move {
        let cur_id = identity_arc.lock().unwrap().clone();
        let norm_code = normalize_device_code(&raw_target);

        // ====================================================================
        // LAYER 1: Same-LAN mDNS Fast Path (< 2ms, zero Internet dependency)
        // ====================================================================
        let predecoded_ticket = if raw_target.starts_with(TICKET_PREFIX) {
            OpenUUTicket::decode(&raw_target).ok()
        } else {
            None
        };
        let lan_peer = discovery_arc.lock().ok().and_then(|g| {
            let d = g.as_ref()?;
            d.find_peer_by_code_or_id(&raw_target).or_else(|| {
                let t = predecoded_ticket.as_ref()?;
                if !t.device_code.is_empty() {
                    if let Some(p) = d.find_peer_by_code_or_id(&t.device_code) {
                        return Some(p);
                    }
                }
                if !t.endpoint_id.is_empty() {
                    if let Some(p) = d.find_peer_by_code_or_id(&t.endpoint_id) {
                        return Some(p);
                    }
                }
                if !t.device_id.is_empty() {
                    return d.find_peer_by_code_or_id(&t.device_id);
                }
                None
            })
        });
        if let Some(peer) = lan_peer {
            if let Some(&lan_ip) = peer
                .addresses
                .iter()
                .find(|ip| ip.is_ipv4())
                .or_else(|| peer.addresses.first())
            {
                let lan_addr = SocketAddr::new(lan_ip, peer.port);
                emit_status(
                    on_status,
                    ctx,
                    &format!("发现同局域网设备 {}，正在走局域网高速直连...", peer.device_name),
                );
                let expected_fp = cur_id
                    .trusted_peers
                    .get(&peer.device_id)
                    .map(|tp| tp.cert_fingerprint.clone())
                    .filter(|s| !s.is_empty());
                if let Ok(Ok((session, channels, ack, cert_fp, verified_pk))) = tokio::time::timeout(
                    Duration::from_millis(1800),
                    connect_to_host_pinned(&cur_id, lan_addr, &pin_owned, expected_fp),
                )
                .await
                {
                    if let Ok(mut guard) = identity_arc.lock() {
                        let _ = guard.trust_peer(TrustedPeer {
                            device_id: ack.device_id.clone(),
                            device_name: ack.device_name.clone(),
                            cert_fingerprint: cert_fp.unwrap_or_default(),
                            endpoint_id: verified_pk.unwrap_or(peer.endpoint_id),
                            device_code: peer.device_code,
                            last_relay_url: String::new(),
                            last_ticket: String::new(),
                            last_connected_ms: now_epoch_ms(),
                        });
                    }
                    emit_status(
                        on_status,
                        ctx,
                        &format!("connected to host: {} (局域网直连)", ack.device_name),
                    );
                    attach_session_callbacks(
                        session,
                        channels,
                        active_session,
                        on_control,
                        on_video,
                        on_status,
                        ctx,
                        "disconnected from host",
                    );
                    return;
                }
            }
        }

        // ====================================================================
        // Resolve Ticket / EndpointAddr across Layers 2..5:
        // - Explicit `openuu://` Ticket
        // - 9-Digit Code via Self-hosted HK `openuu-coord`
        // - Cached `TrustedPeer` + Custom HK Relay + Public `n0` Pkarr Fallback
        // - Direct `host:port` / IPv6 / DDNS fallback
        // ====================================================================
        let extra_relays = parse_custom_relay_urls(&cur_id.wan_config.relay_url);
        let mut resolved_ticket: Option<OpenUUTicket> = None;
        let mut target_ep_addr: Option<EndpointAddr> = None;
        let mut saved_code = norm_code.clone();

        if raw_target.starts_with(TICKET_PREFIX) {
            match OpenUUTicket::decode(&raw_target) {
                Ok(t) => {
                    saved_code = t.device_code.clone();
                    match t.to_endpoint_addr(&extra_relays) {
                        Ok(addr) => {
                            target_ep_addr = Some(addr);
                            resolved_ticket = Some(t);
                        }
                        Err(e) => {
                            emit_status(on_status, ctx, &format!("connect failed: {e}"));
                            return;
                        }
                    }
                }
                Err(e) => {
                    emit_status(on_status, ctx, &format!("connect failed: {e}"));
                    return;
                }
            }
        } else if norm_code.len() == 9 {
            let mut rate_limited = false;
            let trusted_entry = cur_id.find_trusted_by_code_or_id(&norm_code).cloned();

            if !cur_id.wan_config.coord_url.trim().is_empty() {
                emit_status(
                    on_status,
                    ctx,
                    &format!("正在验证并连接设备 {norm_code}..."),
                );
                let mut resolve_res = if !pin_owned.trim().is_empty() {
                    coord_resolve_code(
                        &cur_id.wan_config.coord_url,
                        cur_id.wan_config.allow_insecure_tls,
                        &norm_code,
                        &pin_owned,
                    )
                    .await
                } else {
                    Err(crate::error::OpenUUError::PairingRejected(
                        UNIFIED_AUTH_OR_CODE_ERR.into(),
                    ))
                };

                // If PIN was empty OR remote Host rotated its temporary PIN since last week,
                // an already-paired `TrustedPeer` seamlessly resolves via its 256-bit `endpoint_id`!
                if resolve_res.is_err() {
                    let is_rl = matches!(
                        resolve_res,
                        Err(crate::error::OpenUUError::PairingRejected(ref m)) if m == RATE_LIMIT_ERR
                    );
                    if !is_rl {
                        if let Some(ref tp) = trusted_entry {
                            if !tp.endpoint_id.is_empty() {
                                if let Ok(ep_resp) = coord_resolve_endpoint(
                                    &cur_id.wan_config.coord_url,
                                    cur_id.wan_config.allow_insecure_tls,
                                    &tp.endpoint_id,
                                )
                                .await
                                {
                                    resolve_res = Ok(ep_resp);
                                }
                            }
                        }
                    }
                }

                match resolve_res {
                    Ok(resp) if resp.found && !resp.ticket.is_empty() => {
                        if let Ok(t) = OpenUUTicket::decode(&resp.ticket) {
                            if let Ok(addr) = t.to_endpoint_addr(&extra_relays) {
                                target_ep_addr = Some(addr);
                                resolved_ticket = Some(t);
                            }
                        }
                    }
                    Err(crate::error::OpenUUError::PairingRejected(ref m))
                        if m == RATE_LIMIT_ERR =>
                    {
                        rate_limited = true;
                    }
                    _ => {}
                }
            }

            // Fallback: check local TrustedPeer cache ONLY when already paired (`trusted_entry` exists)
            if !rate_limited && target_ep_addr.is_none() {
                if let Some(tp) = trusted_entry {
                    if tp.last_ticket.starts_with(TICKET_PREFIX) {
                        if let Ok(t) = OpenUUTicket::decode(&tp.last_ticket) {
                            if let Ok(addr) = t.to_endpoint_addr(&extra_relays) {
                                target_ep_addr = Some(addr);
                                resolved_ticket = Some(t);
                            }
                        }
                    }
                    if target_ep_addr.is_none() && !tp.endpoint_id.is_empty() {
                        if let Ok(pk) = PublicKey::from_str(&tp.endpoint_id) {
                            let addrs: Vec<TransportAddr> = extra_relays
                                .iter()
                                .cloned()
                                .map(TransportAddr::Relay)
                                .collect();
                            target_ep_addr = Some(EndpointAddr::from_parts(pk, addrs));
                        }
                    }
                }
            }

            if target_ep_addr.is_none() {
                let hint = if rate_limited {
                    RATE_LIMIT_ERR
                } else if cur_id.wan_config.coord_url.trim().is_empty() {
                    "未配置 9 位设备码寻址服务地址：请在「网络与日志」点击「使用公共服务域名」，或直接粘贴被控端复制的 openuu:// 跨网连接串"
                } else {
                    UNIFIED_AUTH_OR_CODE_ERR
                };
                emit_status(on_status, ctx, &format!("connect failed: {hint}"));
                return;
            }
        } else if let Some(tp) = cur_id.find_trusted_by_code_or_id(&raw_target) {
            // Reconnecting to a saved TrustedPeer by `device_id` or `endpoint_id`
            saved_code = tp.device_code.clone();
            if !cur_id.wan_config.coord_url.trim().is_empty() {
                let resolve_res = if !pin_owned.trim().is_empty() && tp.device_code.len() == 9 {
                    coord_resolve_code(
                        &cur_id.wan_config.coord_url,
                        cur_id.wan_config.allow_insecure_tls,
                        &tp.device_code,
                        &pin_owned,
                    )
                    .await
                } else if !tp.endpoint_id.is_empty() {
                    coord_resolve_endpoint(
                        &cur_id.wan_config.coord_url,
                        cur_id.wan_config.allow_insecure_tls,
                        &tp.endpoint_id,
                    )
                    .await
                } else {
                    Err(crate::error::OpenUUError::PairingRejected(
                        UNIFIED_AUTH_OR_CODE_ERR.into(),
                    ))
                };
                if let Ok(resp) = resolve_res {
                    if resp.found {
                        if let Ok(t) = OpenUUTicket::decode(&resp.ticket) {
                            if let Ok(addr) = t.to_endpoint_addr(&extra_relays) {
                                target_ep_addr = Some(addr);
                                resolved_ticket = Some(t);
                            }
                        }
                    }
                }
            }
            if target_ep_addr.is_none() && tp.last_ticket.starts_with(TICKET_PREFIX) {
                if let Ok(t) = OpenUUTicket::decode(&tp.last_ticket) {
                    if let Ok(addr) = t.to_endpoint_addr(&extra_relays) {
                        target_ep_addr = Some(addr);
                        resolved_ticket = Some(t);
                    }
                }
            }
            if target_ep_addr.is_none() && !tp.endpoint_id.is_empty() {
                if let Ok(pk) = PublicKey::from_str(&tp.endpoint_id) {
                    let addrs: Vec<TransportAddr> = extra_relays
                        .iter()
                        .cloned()
                        .map(TransportAddr::Relay)
                        .collect();
                    target_ep_addr = Some(EndpointAddr::from_parts(pk, addrs));
                }
            }
            // If TrustedPeer was a direct IP:Port LAN/DDNS entry without Iroh EndpointId
            if target_ep_addr.is_none() && !tp.last_ticket.is_empty() {
                let (h, p) = split_host_and_port(&tp.last_ticket, fallback_port);
                if let Ok(sa) = resolve_host_socket_addr(&h, p).await {
                    let fp = Some(tp.cert_fingerprint.clone()).filter(|s| !s.is_empty());
                    match connect_to_host_pinned(&cur_id, sa, &pin_owned, fp).await {
                        Ok((session, channels, ack, _, _)) => {
                            emit_status(
                                on_status,
                                ctx,
                                &format!("connected to host: {}", ack.device_name),
                            );
                            attach_session_callbacks(
                                session,
                                channels,
                                active_session,
                                on_control,
                                on_video,
                                on_status,
                                ctx,
                                "disconnected from host",
                            );
                            return;
                        }
                        Err(e) => {
                            emit_status(on_status, ctx, &format!("connect failed: {e}"));
                            return;
                        }
                    }
                }
            }
        } else if let Ok(pk) = PublicKey::from_str(&raw_target) {
            // Raw Iroh EndpointId string
            let addrs: Vec<TransportAddr> = extra_relays
                .iter()
                .cloned()
                .map(TransportAddr::Relay)
                .collect();
            target_ep_addr = Some(EndpointAddr::from_parts(pk, addrs));
        } else {
            // Direct IPv4 / IPv6 / DDNS hostname[:port]
            let (host_part, port_part) = split_host_and_port(&raw_target, fallback_port);
            emit_status(
                on_status,
                ctx,
                &format!("connecting to {host_part}:{port_part}..."),
            );
            match resolve_host_socket_addr(&host_part, port_part).await {
                Ok(addr) => match connect_to_host_pinned(&cur_id, addr, &pin_owned, None).await {
                    Ok((session, channels, ack, cert_fp, verified_pk)) => {
                        if let Ok(mut guard) = identity_arc.lock() {
                            let _ = guard.trust_peer(TrustedPeer {
                                device_id: ack.device_id.clone(),
                                device_name: ack.device_name.clone(),
                                cert_fingerprint: cert_fp.unwrap_or_default(),
                                endpoint_id: verified_pk.unwrap_or_default(),
                                device_code: String::new(),
                                last_relay_url: String::new(),
                                last_ticket: format!("{host_part}:{port_part}"),
                                last_connected_ms: now_epoch_ms(),
                            });
                        }
                        emit_status(
                            on_status,
                            ctx,
                            &format!("connected to host: {}", ack.device_name),
                        );
                        attach_session_callbacks(
                            session,
                            channels,
                            active_session,
                            on_control,
                            on_video,
                            on_status,
                            ctx,
                            "disconnected from host",
                        );
                        return;
                    }
                    Err(e) => {
                        emit_status(on_status, ctx, &format!("connect failed: {e}"));
                        return;
                    }
                },
                Err(e) => {
                    emit_status(on_status, ctx, &format!("connect failed: {e}"));
                    return;
                }
            }
        }

        // ====================================================================
        // Dial via Iroh (Cascading: IPv6 Direct -> IPv4 STUN P2P -> HK Relay -> n0 Fallback)
        // ====================================================================
        let Some(ep_addr) = target_ep_addr else {
            emit_status(on_status, ctx, "connect failed: unable to build target EndpointAddr");
            return;
        };

        emit_status(
            on_status,
            ctx,
            "正在建立跨网加密连接（并发探测 IPv6 / P2P 打洞 / 中继兜底）...",
        );

        let existing_client_ep = iroh_client_slot.lock().ok().and_then(|g| g.clone());
        let client_ep = match existing_client_ep {
            Some(ep) => ep,
            None => match bind_iroh_endpoint(&cur_id, false).await {
                Ok(ep) => {
                    if let Ok(mut slot) = iroh_client_slot.lock() {
                        *slot = Some(ep.clone());
                    }
                    ep
                }
                Err(e) => {
                    emit_status(on_status, ctx, &format!("connect failed: {e}"));
                    return;
                }
            },
        };

        let dial_timeout = Duration::from_secs(22);
        let mut connect_res = match tokio::time::timeout(
            dial_timeout,
            connect_via_iroh(&client_ep, &cur_id, ep_addr.clone(), &pin_owned),
        )
        .await
        {
            Ok(res) => res,
            Err(_) => Err(crate::error::OpenUUError::Wan(
                "连接超时（22s）：双方中继或直连 UDP 不可达".into(),
            )),
        };

        // On non-auth WAN errors: invalidate cached client endpoint (handles Wi-Fi/VPN changes)
        // and, if the user pasted a possibly stale `openuu://` ticket while coord_url is configured,
        // try refreshing the Host's latest live ticket by 256-bit EndpointId and retry once!
        if let Err(ref first_err) = connect_res {
            if !matches!(first_err, crate::error::OpenUUError::PairingRejected(_)) {
                if let Ok(mut slot) = iroh_client_slot.lock() {
                    if let Some(stale) = slot.take() {
                        tokio::spawn(async move {
                            stale.close().await;
                        });
                    }
                }

                if raw_target.starts_with(TICKET_PREFIX)
                    && !cur_id.wan_config.coord_url.trim().is_empty()
                {
                    if let Some(ref orig_ticket) = resolved_ticket {
                        if orig_ticket.endpoint_id.len() == 64 {
                            if let Ok(resp) = coord_resolve_endpoint(
                                &cur_id.wan_config.coord_url,
                                cur_id.wan_config.allow_insecure_tls,
                                &orig_ticket.endpoint_id,
                            )
                            .await
                            {
                                if resp.found && !resp.ticket.is_empty() && resp.ticket != raw_target
                                {
                                    if let Ok(fresh_ticket) = OpenUUTicket::decode(&resp.ticket) {
                                        if let Ok(fresh_addr) =
                                            fresh_ticket.to_endpoint_addr(&extra_relays)
                                        {
                                            emit_status(
                                                on_status,
                                                ctx,
                                                "原连接串已过期或不可达，已从寻址服刷新最新地址并重试...",
                                            );
                                            if let Ok(fresh_ep) =
                                                bind_iroh_endpoint(&cur_id, false).await
                                            {
                                                if let Ok(mut slot) = iroh_client_slot.lock() {
                                                    *slot = Some(fresh_ep.clone());
                                                }
                                                resolved_ticket = Some(fresh_ticket);
                                                connect_res = match tokio::time::timeout(
                                                    dial_timeout,
                                                    connect_via_iroh(
                                                        &fresh_ep,
                                                        &cur_id,
                                                        fresh_addr,
                                                        &pin_owned,
                                                    ),
                                                )
                                                .await
                                                {
                                                    Ok(res) => res,
                                                    Err(_) => Err(crate::error::OpenUUError::Wan(
                                                        "重试连接超时（22s）：请检查双方网络/代理或自建中继连通性".into(),
                                                    )),
                                                };
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        match connect_res {
            Ok((session, channels, ack, verified_host_pk)) => {
                let link = session.link_telemetry();
                let ticket_str = resolved_ticket
                    .as_ref()
                    .and_then(|t| t.encode().ok())
                    .unwrap_or_default();
                let relay_str = resolved_ticket
                    .as_ref()
                    .and_then(|t| t.relay_urls.first().cloned())
                    .unwrap_or_default();

                if let Ok(mut guard) = identity_arc.lock() {
                    let _ = guard.trust_peer(TrustedPeer {
                        device_id: ack.device_id.clone(),
                        device_name: ack.device_name.clone(),
                        cert_fingerprint: String::new(),
                        endpoint_id: verified_host_pk,
                        device_code: saved_code,
                        last_relay_url: relay_str,
                        last_ticket: ticket_str,
                        last_connected_ms: now_epoch_ms(),
                    });
                }

                let mode_zh = match link.mode {
                    crate::wan::LinkMode::Lan => "局域网直连",
                    crate::wan::LinkMode::WanDirect => "P2P 直连",
                    crate::wan::LinkMode::WanRelay => "中继保底",
                };
                emit_status(
                    on_status,
                    ctx,
                    &format!(
                        "connected to host: {} ({} {}ms)",
                        ack.device_name, mode_zh, link.rtt_ms
                    ),
                );
                attach_session_callbacks(
                    session,
                    channels,
                    active_session,
                    on_control,
                    on_video,
                    on_status,
                    ctx,
                    "disconnected from host",
                );
            }
            Err(e) => {
                let msg = match e {
                    crate::error::OpenUUError::PairingRejected(ref m) => m.clone(),
                    _ if norm_code.len() == 9 => UNIFIED_AUTH_OR_CODE_ERR.to_string(),
                    _ => {
                        let relays: Vec<String> =
                            ep_addr.relay_urls().map(|u| u.to_string()).collect();
                        let direct_cnt = ep_addr.ip_addrs().count();
                        if relays.is_empty() {
                            format!("{e}（无中继地址，候选直连IP={direct_cnt}）")
                        } else {
                            format!(
                                "{e}（目标中继={}，候选直连IP={direct_cnt}）",
                                relays.join(",")
                            )
                        }
                    }
                };
                emit_status(on_status, ctx, &format!("connect failed: {msg}"));
            }
        }
    });

    0
}

fn split_host_and_port(raw: &str, default_port: u16) -> (String, u16) {
    let trimmed = raw.trim();
    // Bracketed IPv6: `[240e:...]:39481` or `[240e:...]`
    if let Some(rest) = trimmed.strip_prefix('[') {
        if let Some((v6, after)) = rest.split_once(']') {
            if let Some(p_str) = after.strip_prefix(':') {
                if let Ok(p) = p_str.parse::<u16>() {
                    return (v6.to_string(), p);
                }
            }
            return (v6.to_string(), default_port);
        }
    }
    // Unbracketed IPv6 literal has multiple colons (`240e:390::1`)
    if trimmed.matches(':').count() > 1 {
        return (trimmed.to_string(), default_port);
    }
    if let Some((h, p_str)) = trimmed.rsplit_once(':') {
        if let Ok(p) = p_str.parse::<u16>() {
            return (h.to_string(), p);
        }
    }
    (trimmed.to_string(), default_port)
}

#[no_mangle]
pub unsafe extern "C" fn openuu_disconnect(rt: *mut OpenUURuntime) {
    if rt.is_null() {
        return;
    }
    let rt = &*rt;
    if let Ok(mut guard) = rt.active_session.lock() {
        if let Some(session) = guard.take() {
            session.close();
        }
    }
}

#[no_mangle]
pub unsafe extern "C" fn openuu_stop_host(rt: *mut OpenUURuntime) {
    if rt.is_null() {
        return;
    }
    let rt = &*rt;
    rt.host_running.store(false, Ordering::SeqCst);
    rt.host_stop_notify.notify_waiters();

    if let Ok(mut guard) = rt.active_session.lock() {
        if let Some(session) = guard.take() {
            session.close();
        }
    }
    if let Ok(mut ep_guard) = rt.host_endpoint.lock() {
        if let Some(ep) = ep_guard.take() {
            ep.close(0u32.into(), b"host stopped");
        }
    }
    if let Ok(mut iroh_guard) = rt.iroh_host_endpoint.lock() {
        if let Some(ep) = iroh_guard.take() {
            rt.tokio_rt.spawn(async move {
                ep.close().await;
            });
        }
    }
    if let Ok(mut t_guard) = rt.host_ticket.lock() {
        t_guard.clear();
    }
    if let Ok(mut st) = rt.coord_status.lock() {
        *st = "已停止".to_string();
    }
    if let Ok(mut disc_guard) = rt.discovery.lock() {
        *disc_guard = None;
    }
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_video_frame(
    rt: *mut OpenUURuntime,
    codec: u8,
    flags: u8,
    window_id: u32,
    timestamp_us: u64,
    width: u16,
    height: u16,
    data: *const u8,
    data_len: usize,
) -> i32 {
    if rt.is_null() || data.is_null() || data_len == 0 {
        return -1;
    }
    let rt = &*rt;
    let Ok(codec) = VideoCodec::try_from(codec) else {
        return -2;
    };
    let Some(session) = rt.active_session.lock().ok().and_then(|g| g.clone()) else {
        return -3;
    };
    let payload = Bytes::copy_from_slice(slice::from_raw_parts(data, data_len));
    let frame = VideoFrame {
        codec,
        flags,
        window_id,
        timestamp_us,
        width,
        height,
        payload,
    };
    if session.try_send_video_frame(&frame).is_err() {
        rt.tokio_rt.spawn(async move {
            let _ = session.send_video_frame(&frame).await;
        });
    }
    0
}

fn send_control_async(rt: &OpenUURuntime, payload: pb::control_envelope::Payload) -> i32 {
    let Some(session) = rt.active_session.lock().ok().and_then(|g| g.clone()) else {
        return -3;
    };
    let env = pb::ControlEnvelope {
        seq: rt.next_seq(),
        payload: Some(payload),
    };
    if session.try_send_control(&env).is_err() {
        rt.tokio_rt.spawn(async move {
            let _ = session.send_control(&env).await;
        });
    }
    0
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_mouse_event(
    rt: *mut OpenUURuntime,
    window_id: u32,
    x: f32,
    y: f32,
    event_type: u8,
    button: u32,
    click_count: u32,
    modifiers: u32,
) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::MouseEvent(pb::MouseEvent {
            window_id,
            x,
            y,
            r#type: event_type as i32,
            button,
            click_count,
            modifiers,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_scroll_event(
    rt: *mut OpenUURuntime,
    window_id: u32,
    x: f32,
    y: f32,
    delta_x: f32,
    delta_y: f32,
    is_continuous: bool,
    modifiers: u32,
) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ScrollEvent(pb::ScrollEvent {
            window_id,
            x,
            y,
            delta_x,
            delta_y,
            is_continuous,
            modifiers,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_key_event(
    rt: *mut OpenUURuntime,
    window_id: u32,
    key_code: u32,
    is_down: bool,
    is_repeat: bool,
    modifiers: u32,
) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::KeyEvent(pb::KeyEvent {
            window_id,
            key_code,
            is_down,
            is_repeat,
            modifiers,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_text_commit(
    rt: *mut OpenUURuntime,
    window_id: u32,
    utf8_text: *const c_char,
) -> i32 {
    if rt.is_null() || utf8_text.is_null() {
        return -1;
    }
    let Ok(text) = CStr::from_ptr(utf8_text).to_str() else {
        return -2;
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::TextCommit(pb::TextCommitEvent {
            window_id,
            text: text.to_string(),
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_request_keyframe(rt: *mut OpenUURuntime, window_id: u32) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::RequestKeyframe(pb::RequestKeyframe { window_id }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_cursor_update(
    rt: *mut OpenUURuntime,
    kind: *const c_char,
    png_data: *const u8,
    png_len: usize,
    hotspot_x: f32,
    hotspot_y: f32,
) -> i32 {
    if rt.is_null() || kind.is_null() {
        return -1;
    }
    let Ok(kind_str) = CStr::from_ptr(kind).to_str() else {
        return -2;
    };
    let png = if !png_data.is_null() && png_len > 0 {
        slice::from_raw_parts(png_data, png_len).to_vec()
    } else {
        Vec::new()
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::CursorUpdate(pb::CursorUpdate {
            kind: kind_str.to_string(),
            png_data: png,
            hotspot_x,
            hotspot_y,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_window_topology_json(
    rt: *mut OpenUURuntime,
    windows_json: *const c_char,
) -> i32 {
    if rt.is_null() || windows_json.is_null() {
        return -1;
    }
    let Ok(json_str) = CStr::from_ptr(windows_json).to_str() else {
        return -2;
    };
    let Ok(items) = serde_json::from_str::<Vec<WindowSummaryJson>>(json_str) else {
        return -3;
    };
    let windows = items
        .into_iter()
        .enumerate()
        .map(|(idx, w)| pb::WindowInfo {
            window_id: w.window_id,
            parent_window_id: w.parent_window_id,
            kind: w.kind,
            rel_x: w.rel_x,
            rel_y: w.rel_y,
            width: w.width,
            height: w.height,
            scale_factor: 2.0,
            title: w.title,
            z_order: idx as u32,
            icon_png_b64: w.icon_png_b64,
        })
        .collect();
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::WindowTopology(pb::WindowTopologyUpdate { windows }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_request_app_list(rt: *mut OpenUURuntime) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ListAppsReq(pb::ListAppsRequest {}),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_resize_window(
    rt: *mut OpenUURuntime,
    window_id: u32,
    width: f32,
    height: f32,
) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ResizeWindow(pb::ResizeWindowRequest {
            window_id,
            width,
            height,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_clipboard_text(
    rt: *mut OpenUURuntime,
    content_hash: *const c_char,
    utf8_text: *const c_char,
) -> i32 {
    if rt.is_null() || content_hash.is_null() || utf8_text.is_null() {
        return -1;
    }
    let Ok(hash) = CStr::from_ptr(content_hash).to_str() else {
        return -2;
    };
    let Ok(text) = CStr::from_ptr(utf8_text).to_str() else {
        return -3;
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ClipboardSync(pb::ClipboardSync {
            content_hash: hash.to_string(),
            kind: pb::clipboard_sync::Kind::Text as i32,
            text: text.to_string(),
            blob_id: String::new(),
            mime_type: "text/plain".to_string(),
            image_data: Vec::new(),
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_clipboard_image(
    rt: *mut OpenUURuntime,
    content_hash: *const c_char,
    mime_type: *const c_char,
    image_data: *const u8,
    image_len: usize,
) -> i32 {
    if rt.is_null() || content_hash.is_null() || image_data.is_null() || image_len == 0 {
        return -1;
    }
    let Ok(hash) = CStr::from_ptr(content_hash).to_str() else {
        return -2;
    };
    let mime = if mime_type.is_null() {
        "image/png".to_string()
    } else {
        CStr::from_ptr(mime_type)
            .to_str()
            .unwrap_or("image/png")
            .to_string()
    };
    let bytes = std::slice::from_raw_parts(image_data, image_len).to_vec();
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ClipboardSync(pb::ClipboardSync {
            content_hash: hash.to_string(),
            kind: pb::clipboard_sync::Kind::Image as i32,
            text: String::new(),
            blob_id: String::new(),
            mime_type: mime,
            image_data: bytes,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_notification(
    rt: *mut OpenUURuntime,
    app_bundle_id: *const c_char,
    title: *const c_char,
    subtitle: *const c_char,
    body: *const c_char,
    timestamp_ms: u64,
) -> i32 {
    if rt.is_null() || app_bundle_id.is_null() {
        return -1;
    }
    let bundle = CStr::from_ptr(app_bundle_id)
        .to_str()
        .unwrap_or_default()
        .to_string();
    let title_str = if title.is_null() {
        String::new()
    } else {
        CStr::from_ptr(title).to_str().unwrap_or_default().to_string()
    };
    let subtitle_str = if subtitle.is_null() {
        String::new()
    } else {
        CStr::from_ptr(subtitle)
            .to_str()
            .unwrap_or_default()
            .to_string()
    };
    let body_str = if body.is_null() {
        String::new()
    } else {
        CStr::from_ptr(body).to_str().unwrap_or_default().to_string()
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::Notification(pb::NotificationEvent {
            app_bundle_id: bundle,
            title: title_str,
            subtitle: subtitle_str,
            body: body_str,
            timestamp_ms,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_badge_update(
    rt: *mut OpenUURuntime,
    app_bundle_id: *const c_char,
    badge_text: *const c_char,
) -> i32 {
    if rt.is_null() || app_bundle_id.is_null() {
        return -1;
    }
    let bundle = CStr::from_ptr(app_bundle_id)
        .to_str()
        .unwrap_or_default()
        .to_string();
    let badge = if badge_text.is_null() {
        String::new()
    } else {
        CStr::from_ptr(badge_text)
            .to_str()
            .unwrap_or_default()
            .to_string()
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::BadgeUpdate(pb::BadgeUpdate {
            app_bundle_id: bundle,
            badge_text: badge,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_file_blob(
    rt: *mut OpenUURuntime,
    window_id: u32,
    x: f32,
    y: f32,
    blob_id: *const c_char,
    filename: *const c_char,
    local_path: *const c_char,
) -> i32 {
    if rt.is_null() || blob_id.is_null() || filename.is_null() || local_path.is_null() {
        return -1;
    }
    let Ok(blob_str) = CStr::from_ptr(blob_id).to_str() else {
        return -2;
    };
    let Ok(name_str) = CStr::from_ptr(filename).to_str() else {
        return -3;
    };
    let Ok(path_str) = CStr::from_ptr(local_path).to_str() else {
        return -4;
    };
    let rt_ref = &*rt;
    let session = match rt_ref.active_session.lock().ok().and_then(|g| g.clone()) {
        Some(s) => s,
        None => return -5,
    };
    let blob = blob_str.to_string();
    let name = name_str.to_string();
    let path = std::path::PathBuf::from(path_str);
    rt_ref.tokio_rt.spawn(async move {
        if let Err(e) = session
            .send_file_blob(window_id, x, y, blob, name, path)
            .await
        {
            tracing::warn!("send_file_blob failed: {e}");
        }
    });
    0
}

#[no_mangle]
pub unsafe extern "C" fn openuu_send_app_list_json(
    rt: *mut OpenUURuntime,
    apps_json: *const c_char,
) -> i32 {
    if rt.is_null() || apps_json.is_null() {
        return -1;
    }
    let Ok(json_str) = CStr::from_ptr(apps_json).to_str() else {
        return -2;
    };
    let Ok(items) = serde_json::from_str::<Vec<AppSummaryJson>>(json_str) else {
        return -3;
    };
    let apps = items
        .into_iter()
        .map(|a| pb::AppInfo {
            bundle_id: a.bundle_id,
            name: a.name,
            pid: a.pid,
            window_count: a.window_count,
            icon_png_b64: a.icon_png_b64,
        })
        .collect();
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ListAppsResp(pb::ListAppsResponse { apps }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_start_remote_session(
    rt: *mut OpenUURuntime,
    bundle_id: *const c_char,
    window_id: u32,
) -> i32 {
    if rt.is_null() || bundle_id.is_null() {
        return -1;
    }
    let Ok(bid) = CStr::from_ptr(bundle_id).to_str() else {
        return -2;
    };
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::StartSession(pb::StartSessionRequest {
            bundle_id: bid.to_string(),
            window_id,
            max_fps: 60,
            codec: 2,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_stop_remote_session(
    rt: *mut OpenUURuntime,
    window_id: u32,
) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::StopSession(pb::StopSessionRequest { window_id }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn openuu_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc as std_mpsc;
    use std::time::Duration;

    static FFI_ENV_LOCK: Mutex<()> = Mutex::new(());

    extern "C" fn test_ctrl_cb(ctx: *mut c_void, json_ptr: *const c_char) {
        unsafe {
            let tx = &*(ctx as *const std_mpsc::Sender<String>);
            let s = CStr::from_ptr(json_ptr).to_string_lossy().into_owned();
            let _ = tx.send(s);
        }
    }

    #[test]
    fn ffi_app_dirs_and_runtime_create_with_dir() {
        let _guard = FFI_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        struct ResetGuard;
        impl Drop for ResetGuard {
            fn drop(&mut self) {
                crate::identity::set_global_app_dirs(None, None);
            }
        }
        let _reset = ResetGuard;

        let unique = uuid::Uuid::new_v4().to_string();
        let base_tmp = std::env::temp_dir().join(format!("openuu-appdirs-test-{unique}"));
        let global_cfg_dir = base_tmp.join("global-cfg");
        let global_cache_dir = base_tmp.join("global-cache");
        let explicit_cfg_dir = base_tmp.join("explicit-cfg");

        unsafe {
            let cfg_c = CString::new(global_cfg_dir.to_string_lossy().as_ref()).unwrap();
            let cache_c = CString::new(global_cache_dir.to_string_lossy().as_ref()).unwrap();
            assert_eq!(openuu_set_app_dirs(cfg_c.as_ptr(), cache_c.as_ptr()), 0);

            // Global overrides take precedence over env/default dirs
            assert_eq!(DeviceIdentity::default_config_dir(), global_cfg_dir);
            assert_eq!(crate::identity::default_cache_dir(), global_cache_dir);

            let name_global = CString::new("Mobile-Global-Test").unwrap();
            let rt_global = openuu_runtime_create(name_global.as_ptr());
            assert!(!rt_global.is_null());
            assert!(
                global_cfg_dir.join("identity.json").exists(),
                "identity.json must be created inside global config_dir"
            );

            let json_ptr1 = openuu_get_identity_json(rt_global);
            assert!(!json_ptr1.is_null());
            let json_str1 = CStr::from_ptr(json_ptr1).to_str().unwrap().to_string();
            openuu_free_string(json_ptr1);
            let parsed1: serde_json::Value = serde_json::from_str(&json_str1).unwrap();
            assert_eq!(parsed1["device_name"], "Mobile-Global-Test");
            assert_eq!(parsed1["device_code"].as_str().unwrap().len(), 9);
            assert!(!parsed1["device_id"].as_str().unwrap().is_empty());
            assert!(!parsed1["endpoint_id"].as_str().unwrap().is_empty());

            // Explicit config_dir via openuu_runtime_create_with_dir
            let name_explicit = CString::new("Mobile-Explicit-Dir").unwrap();
            let exp_dir_c = CString::new(explicit_cfg_dir.to_string_lossy().as_ref()).unwrap();
            let rt_explicit =
                openuu_runtime_create_with_dir(name_explicit.as_ptr(), exp_dir_c.as_ptr());
            assert!(!rt_explicit.is_null());
            assert!(
                explicit_cfg_dir.join("identity.json").exists(),
                "identity.json must be created inside explicit config_dir"
            );

            let json_ptr2 = openuu_get_identity_json(rt_explicit);
            assert!(!json_ptr2.is_null());
            let json_str2 = CStr::from_ptr(json_ptr2).to_str().unwrap().to_string();
            openuu_free_string(json_ptr2);
            let parsed2: serde_json::Value = serde_json::from_str(&json_str2).unwrap();
            assert_eq!(parsed2["device_name"], "Mobile-Explicit-Dir");
            assert_eq!(parsed2["device_code"].as_str().unwrap().len(), 9);
            assert_ne!(parsed1["device_id"], parsed2["device_id"]);

            openuu_runtime_destroy(rt_explicit);
            openuu_runtime_destroy(rt_global);

            // Clearing overrides restores temp_dir fallback
            assert_eq!(openuu_set_app_dirs(std::ptr::null(), std::ptr::null()), 0);
            assert_eq!(crate::identity::default_cache_dir(), std::env::temp_dir());
        }

        let _ = std::fs::remove_dir_all(&base_tmp);
    }

    #[test]
    fn ffi_mouse_event_loopback() {
        let _guard = FFI_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            let tmp_cfg = std::env::temp_dir().join("openuu-ffi-test-cfg");
            std::env::set_var("OPENUU_CONFIG_DIR", &tmp_cfg);
            let host_name = CString::new("FFI-Host").unwrap();
            let client_name = CString::new("FFI-Client").unwrap();
            let host_rt = openuu_runtime_create(host_name.as_ptr());
            let client_rt = openuu_runtime_create(client_name.as_ptr());
            assert!(!host_rt.is_null() && !client_rt.is_null());

            let (tx, rx) = std_mpsc::channel::<String>();
            let tx_ptr = (&tx as *const std_mpsc::Sender<String>) as *mut c_void;

            let mut pin_buf = [0 as c_char; 16];
            let port = openuu_start_host(
                host_rt,
                0,
                pin_buf.as_mut_ptr(),
                pin_buf.len(),
                Some(test_ctrl_cb),
                None,
                None,
                tx_ptr,
            );
            assert!(port > 0);
            let pin = CStr::from_ptr(pin_buf.as_ptr())
                .to_str()
                .unwrap()
                .to_string();

            let ip = CString::new("127.0.0.1").unwrap();
            let pin_c = CString::new(pin).unwrap();
            let rc = openuu_connect_client(
                client_rt,
                ip.as_ptr(),
                port,
                pin_c.as_ptr(),
                None,
                None,
                None,
                std::ptr::null_mut(),
            );
            assert_eq!(rc, 0);

            std::thread::sleep(Duration::from_millis(250));

            let send_rc = openuu_send_mouse_event(client_rt, 777, 123.5, 456.25, 1, 0, 1, 0);
            assert_eq!(send_rc, 0);

            // Drain initial `link_quality` event and find `mouse` event
            let mut found_mouse = false;
            for _ in 0..4 {
                if let Ok(received) = rx.recv_timeout(Duration::from_secs(2)) {
                    if received.contains("\"type\":\"mouse\"") {
                        assert!(received.contains("\"window_id\":777"), "got: {received}");
                        assert!(received.contains("\"event_type\":1"), "got: {received}");
                        found_mouse = true;
                        break;
                    }
                }
            }
            assert!(found_mouse, "host should receive mouse JSON");

            openuu_disconnect(client_rt);
            openuu_stop_host(host_rt);
            openuu_runtime_destroy(client_rt);
            openuu_runtime_destroy(host_rt);
        }
    }

    #[test]
    fn ffi_concurrent_multi_host_control() {
        let _guard = FFI_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        unsafe {
            let tmp_a = std::env::temp_dir().join("openuu-multi-host-a");
            let tmp_b = std::env::temp_dir().join("openuu-multi-host-b");
            let tmp_c = std::env::temp_dir().join("openuu-multi-client");

            std::env::set_var("OPENUU_CONFIG_DIR", &tmp_a);
            let name_a = CString::new("Home-Mac").unwrap();
            let host_a = openuu_runtime_create(name_a.as_ptr());

            std::env::set_var("OPENUU_CONFIG_DIR", &tmp_b);
            let name_b = CString::new("Office-Mac").unwrap();
            let host_b = openuu_runtime_create(name_b.as_ptr());

            std::env::set_var("OPENUU_CONFIG_DIR", &tmp_c);
            let cname = CString::new("Controller-Mac").unwrap();
            let sess_a = openuu_runtime_create(cname.as_ptr());
            let sess_b = openuu_runtime_create(cname.as_ptr());

            let (tx_a, rx_a) = std_mpsc::channel::<String>();
            let (tx_b, rx_b) = std_mpsc::channel::<String>();

            let mut pin_a_buf = [0 as c_char; 16];
            let port_a = openuu_start_host(
                host_a,
                0,
                pin_a_buf.as_mut_ptr(),
                pin_a_buf.len(),
                Some(test_ctrl_cb),
                None,
                None,
                (&tx_a as *const _) as *mut c_void,
            );
            let pin_a = CStr::from_ptr(pin_a_buf.as_ptr()).to_str().unwrap().to_string();

            let mut pin_b_buf = [0 as c_char; 16];
            let port_b = openuu_start_host(
                host_b,
                0,
                pin_b_buf.as_mut_ptr(),
                pin_b_buf.len(),
                Some(test_ctrl_cb),
                None,
                None,
                (&tx_b as *const _) as *mut c_void,
            );
            let pin_b = CStr::from_ptr(pin_b_buf.as_ptr()).to_str().unwrap().to_string();

            // Simultaneously connect to BOTH Host A and Host B!
            let target_a = CString::new(format!("127.0.0.1:{port_a}")).unwrap();
            let target_b = CString::new(format!("127.0.0.1:{port_b}")).unwrap();
            let pin_a_c = CString::new(pin_a).unwrap();
            let pin_b_c = CString::new(pin_b).unwrap();

            assert_eq!(
                openuu_connect_smart(sess_a, target_a.as_ptr(), port_a, pin_a_c.as_ptr(), None, None, None, std::ptr::null_mut()),
                0
            );
            assert_eq!(
                openuu_connect_smart(sess_b, target_b.as_ptr(), port_b, pin_b_c.as_ptr(), None, None, None, std::ptr::null_mut()),
                0
            );

            std::thread::sleep(Duration::from_millis(300));

            // Send text input simultaneously to SAME window_id (101) on Host A vs Host B — zero crosstalk!
            let txt_a = CString::new("发给家里电脑").unwrap();
            let txt_b = CString::new("发给公司电脑").unwrap();
            assert_eq!(openuu_send_text_commit(sess_a, 101, txt_a.as_ptr()), 0);
            assert_eq!(openuu_send_text_commit(sess_b, 101, txt_b.as_ptr()), 0);

            let mut got_a = false;
            for _ in 0..4 {
                if let Ok(ev) = rx_a.recv_timeout(Duration::from_secs(2)) {
                    if ev.contains("发给家里电脑") {
                        got_a = true;
                        break;
                    }
                }
            }
            let mut got_b = false;
            for _ in 0..4 {
                if let Ok(ev) = rx_b.recv_timeout(Duration::from_secs(2)) {
                    if ev.contains("发给公司电脑") {
                        got_b = true;
                        break;
                    }
                }
            }
            assert!(got_a && got_b, "both hosts must receive their own independent events simultaneously");

            openuu_disconnect(sess_a);
            openuu_disconnect(sess_b);
            openuu_stop_host(host_a);
            openuu_stop_host(host_b);
            openuu_runtime_destroy(sess_a);
            openuu_runtime_destroy(sess_b);
            openuu_runtime_destroy(host_a);
            openuu_runtime_destroy(host_b);
        }
    }
}

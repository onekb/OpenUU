use std::ffi::{CStr, CString};
use std::net::{IpAddr, SocketAddr};
use std::os::raw::{c_char, c_void};
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use bytes::Bytes;
use serde::{Deserialize, Serialize};
use tokio::runtime::Runtime;

use crate::discovery::DiscoveryService;
use crate::identity::{generate_pairing_pin, DeviceIdentity};
use crate::protocol::{pb, VideoCodec, VideoFrame};
use crate::transport::{accept_client_session, bind_host_endpoint, connect_to_host, PeerSession};

pub type ChameyeControlCallback = extern "C" fn(*mut c_void, *const c_char);
pub type ChameyeVideoCallback = extern "C" fn(
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
pub type ChameyeStatusCallback = extern "C" fn(*mut c_void, *const c_char);

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

pub struct ChameyeRuntime {
    tokio_rt: Runtime,
    identity: DeviceIdentity,
    discovery: Mutex<Option<DiscoveryService>>,
    host_endpoint: Mutex<Option<quinn::Endpoint>>,
    active_session: Arc<Mutex<Option<Arc<PeerSession>>>>,
    seq: AtomicU64,
}

impl ChameyeRuntime {
    fn next_seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }
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
    Other {
        debug: String,
    },
}

fn envelope_to_json(env: &pb::ControlEnvelope) -> String {
    let evt = match &env.payload {
        Some(pb::control_envelope::Payload::ListAppsReq(_)) => ControlEventJson::ListAppsReq,
        Some(pb::control_envelope::Payload::ListAppsResp(resp)) => ControlEventJson::ListAppsResp {
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
        },
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
                encode_base64(&cb.image_data)
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

fn emit_status(cb: Option<ChameyeStatusCallback>, ctx: SendPtr, msg: &str) {
    if let Some(cb) = cb {
        if let Ok(cstr) = CString::new(msg) {
            cb(ctx.as_ptr(), cstr.as_ptr());
        }
    }
}

fn encode_base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((input.len() + 2) / 3 * 4);
    let mut i = 0;
    while i < input.len() {
        let b0 = input[i] as u32;
        let b1 = if i + 1 < input.len() { input[i + 1] as u32 } else { 0 };
        let b2 = if i + 2 < input.len() { input[i + 2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(TABLE[((triple >> 18) & 0x3F) as usize] as char);
        out.push(TABLE[((triple >> 12) & 0x3F) as usize] as char);
        if i + 1 < input.len() {
            out.push(TABLE[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if i + 2 < input.len() {
            out.push(TABLE[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        i += 3;
    }
    out
}

#[no_mangle]
pub unsafe extern "C" fn chameye_runtime_create(device_name: *const c_char) -> *mut ChameyeRuntime {
    let name = if device_name.is_null() {
        None
    } else {
        CStr::from_ptr(device_name)
            .to_str()
            .ok()
            .filter(|s| !s.is_empty())
            .map(String::from)
    };
    let Ok(tokio_rt) = Runtime::new() else {
        return std::ptr::null_mut();
    };
    let Ok(identity) = DeviceIdentity::load_or_create(None, name) else {
        return std::ptr::null_mut();
    };
    let rt = Box::new(ChameyeRuntime {
        tokio_rt,
        identity,
        discovery: Mutex::new(None),
        host_endpoint: Mutex::new(None),
        active_session: Arc::new(Mutex::new(None)),
        seq: AtomicU64::new(10),
    });
    Box::into_raw(rt)
}

#[no_mangle]
pub unsafe extern "C" fn chameye_runtime_destroy(rt: *mut ChameyeRuntime) {
    if !rt.is_null() {
        drop(Box::from_raw(rt));
    }
}

#[no_mangle]
pub unsafe extern "C" fn chameye_start_host(
    rt: *mut ChameyeRuntime,
    bind_port: u16,
    out_pin_buf: *mut c_char,
    out_pin_buf_len: usize,
    on_control: Option<ChameyeControlCallback>,
    on_video: Option<ChameyeVideoCallback>,
    on_status: Option<ChameyeStatusCallback>,
    user_ctx: *mut c_void,
) -> u16 {
    if rt.is_null() {
        return 0;
    }
    let rt = &*rt;
    // Reuse caller-provided PIN in `out_pin_buf` if non-empty, otherwise generate a fresh 6-digit PIN.
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

    let bind_addr: SocketAddr = format!("0.0.0.0:{bind_port}").parse().unwrap();
    let endpoint = match rt
        .tokio_rt
        .block_on(async { bind_host_endpoint(&rt.identity, bind_addr) })
    {
        Ok(ep) => ep,
        Err(e) => {
            emit_status(on_status, SendPtr::new(user_ctx), &format!("host bind error: {e}"));
            return 0;
        }
    };
    let local_port = endpoint.local_addr().map(|a| a.port()).unwrap_or(0);
    if let Ok(mut ep_guard) = rt.host_endpoint.lock() {
        *ep_guard = Some(endpoint.clone());
    }

    // Advertise over mDNS
    if let Ok(mut disc_guard) = rt.discovery.lock() {
        if disc_guard.is_none() {
            if let Ok(d) = DiscoveryService::new() {
                *disc_guard = Some(d);
            }
        }
        if let Some(d) = disc_guard.as_ref() {
            let _ = d.advertise(
                &rt.identity.device_id,
                &rt.identity.device_name,
                std::env::consts::OS,
                local_port,
            );
        }
    }

    let identity = rt.identity.clone();
    let active_session = Arc::clone(&rt.active_session);
    let ctx = SendPtr::new(user_ctx);

    emit_status(
        on_status,
        ctx,
        &format!("host listening on port {local_port} (PIN: {pin})"),
    );

    rt.tokio_rt.spawn(async move {
        loop {
            match accept_client_session(&endpoint, &identity, Some(&pin)).await {
                Ok((session, mut channels, hello)) => {
                    emit_status(
                        on_status,
                        ctx,
                        &format!("client connected: {}", hello.device_name),
                    );
                    if let Ok(mut guard) = active_session.lock() {
                        *guard = Some(Arc::clone(&session));
                    }
                    let ctx_ctrl = ctx;
                    tokio::spawn(async move {
                        while let Some(env) = channels.control_rx.recv().await {
                            if let Some(cb) = on_control {
                                let json = envelope_to_json(&env);
                                if let Ok(cstr) = CString::new(json) {
                                    cb(ctx_ctrl.as_ptr(), cstr.as_ptr());
                                }
                            }
                        }
                        emit_status(on_status, ctx_ctrl, "client disconnected");
                    });
                    let ctx_vid = ctx;
                    tokio::spawn(async move {
                        while let Some(frame) = channels.video_rx.recv().await {
                            if let Some(cb) = on_video {
                                cb(
                                    ctx_vid.as_ptr(),
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

    local_port
}

#[no_mangle]
pub unsafe extern "C" fn chameye_start_discovery(rt: *mut ChameyeRuntime) -> i32 {
    if rt.is_null() {
        return -1;
    }
    let rt = &*rt;
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
        if d.start_browsing(Some(rt.identity.device_id.clone())).is_ok() {
            return 0;
        }
    }
    -3
}

#[no_mangle]
pub unsafe extern "C" fn chameye_list_peers_json(rt: *mut ChameyeRuntime) -> *mut c_char {
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
pub unsafe extern "C" fn chameye_connect_client(
    rt: *mut ChameyeRuntime,
    host_ip: *const c_char,
    port: u16,
    pin: *const c_char,
    on_control: Option<ChameyeControlCallback>,
    on_video: Option<ChameyeVideoCallback>,
    on_status: Option<ChameyeStatusCallback>,
    user_ctx: *mut c_void,
) -> i32 {
    if rt.is_null() || host_ip.is_null() || pin.is_null() {
        return -1;
    }
    let rt = &*rt;
    let Ok(ip_str) = CStr::from_ptr(host_ip).to_str() else {
        return -2;
    };
    let Ok(ip) = ip_str.parse::<IpAddr>() else {
        return -3;
    };
    let Ok(pin_str) = CStr::from_ptr(pin).to_str() else {
        return -4;
    };
    let addr = SocketAddr::new(ip, port);
    let identity = rt.identity.clone();
    let pin_owned = pin_str.to_string();
    let active_session = Arc::clone(&rt.active_session);
    let ctx = SendPtr::new(user_ctx);

    rt.tokio_rt.spawn(async move {
        emit_status(on_status, ctx, &format!("connecting to {addr}..."));
        match connect_to_host(&identity, addr, &pin_owned).await {
            Ok((session, mut channels, ack)) => {
                emit_status(
                    on_status,
                    ctx,
                    &format!("connected to host: {}", ack.device_name),
                );
                if let Ok(mut guard) = active_session.lock() {
                    *guard = Some(Arc::clone(&session));
                }
                let ctx_ctrl = ctx;
                tokio::spawn(async move {
                    while let Some(env) = channels.control_rx.recv().await {
                        if let Some(cb) = on_control {
                            let json = envelope_to_json(&env);
                            if let Ok(cstr) = CString::new(json) {
                                cb(ctx_ctrl.as_ptr(), cstr.as_ptr());
                            }
                        }
                    }
                    emit_status(on_status, ctx_ctrl, "disconnected from host");
                });
                let ctx_vid = ctx;
                tokio::spawn(async move {
                    while let Some(frame) = channels.video_rx.recv().await {
                        if let Some(cb) = on_video {
                            cb(
                                ctx_vid.as_ptr(),
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
            }
            Err(e) => {
                emit_status(on_status, ctx, &format!("connect failed: {e}"));
            }
        }
    });

    0
}

#[no_mangle]
pub unsafe extern "C" fn chameye_disconnect(rt: *mut ChameyeRuntime) {
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
pub unsafe extern "C" fn chameye_stop_host(rt: *mut ChameyeRuntime) {
    if rt.is_null() {
        return;
    }
    let rt = &*rt;
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
    // Drop DiscoveryService to cleanly unregister mDNS advertisement
    if let Ok(mut disc_guard) = rt.discovery.lock() {
        *disc_guard = None;
    }
}

#[no_mangle]
pub unsafe extern "C" fn chameye_send_video_frame(
    rt: *mut ChameyeRuntime,
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

fn send_control_async(rt: &ChameyeRuntime, payload: pb::control_envelope::Payload) -> i32 {
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
pub unsafe extern "C" fn chameye_send_mouse_event(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_scroll_event(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_key_event(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_text_commit(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_request_keyframe(rt: *mut ChameyeRuntime, window_id: u32) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::RequestKeyframe(pb::RequestKeyframe { window_id }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn chameye_send_cursor_update(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_window_topology_json(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_request_app_list(rt: *mut ChameyeRuntime) -> i32 {
    if rt.is_null() {
        return -1;
    }
    send_control_async(
        &*rt,
        pb::control_envelope::Payload::ListAppsReq(pb::ListAppsRequest {}),
    )
}

#[no_mangle]
pub unsafe extern "C" fn chameye_send_resize_window(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_clipboard_text(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_clipboard_image(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_notification(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_badge_update(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_file_blob(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_send_app_list_json(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_start_remote_session(
    rt: *mut ChameyeRuntime,
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
            codec: 1,
        }),
    )
}

#[no_mangle]
pub unsafe extern "C" fn chameye_stop_remote_session(
    rt: *mut ChameyeRuntime,
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
pub unsafe extern "C" fn chameye_free_string(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc as std_mpsc;
    use std::time::Duration;

    extern "C" fn test_ctrl_cb(ctx: *mut c_void, json_ptr: *const c_char) {
        unsafe {
            let tx = &*(ctx as *const std_mpsc::Sender<String>);
            let s = CStr::from_ptr(json_ptr).to_string_lossy().into_owned();
            let _ = tx.send(s);
        }
    }

    #[test]
    fn ffi_mouse_event_loopback() {
        unsafe {
            let host_name = CString::new("FFI-Host").unwrap();
            let client_name = CString::new("FFI-Client").unwrap();
            let host_rt = chameye_runtime_create(host_name.as_ptr());
            let client_rt = chameye_runtime_create(client_name.as_ptr());
            assert!(!host_rt.is_null() && !client_rt.is_null());

            let (tx, rx) = std_mpsc::channel::<String>();
            let tx_ptr = (&tx as *const std_mpsc::Sender<String>) as *mut c_void;

            let mut pin_buf = [0 as c_char; 16];
            let port = chameye_start_host(
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
            let pin = CStr::from_ptr(pin_buf.as_ptr()).to_str().unwrap().to_string();

            let ip = CString::new("127.0.0.1").unwrap();
            let pin_c = CString::new(pin).unwrap();
            let rc = chameye_connect_client(
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

            // Wait briefly for async QUIC handshake
            std::thread::sleep(Duration::from_millis(200));

            let send_rc = chameye_send_mouse_event(client_rt, 777, 123.5, 456.25, 1, 0, 1, 0);
            assert_eq!(send_rc, 0);

            let received = rx.recv_timeout(Duration::from_secs(2)).expect("host should receive mouse JSON");
            assert!(received.contains("\"type\":\"mouse\""), "got: {received}");
            assert!(received.contains("\"window_id\":777"), "got: {received}");
            assert!(received.contains("\"event_type\":1"), "got: {received}");

            chameye_disconnect(client_rt);
            chameye_disconnect(host_rt);
            chameye_runtime_destroy(client_rt);
            chameye_runtime_destroy(host_rt);
        }
    }
}

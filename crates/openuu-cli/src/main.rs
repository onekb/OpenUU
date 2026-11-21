use std::ffi::{CStr, CString};
use std::io::Write;
use std::net::SocketAddr;
use std::os::raw::{c_char, c_void};
use std::sync::mpsc as std_mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use openuu_core::discovery::DiscoveryService;
use openuu_core::ffi::{
    openuu_free_string, openuu_get_identity_json, openuu_runtime_create_with_dir,
    openuu_runtime_destroy, openuu_send_app_list_json, openuu_send_clipboard_text,
    openuu_send_notification, openuu_send_video_frame, openuu_send_window_topology_json,
    openuu_start_host, openuu_stop_host, OpenUURuntime,
};
use openuu_core::identity::{
    generate_strong_access_code, normalize_device_code, now_epoch_ms, DeviceIdentity,
};
use openuu_core::protocol::pb;
use openuu_core::transport::{
    accept_client_session, accept_iroh_session, bind_host_endpoint, connect_to_host,
    connect_via_iroh,
};
use openuu_core::wan::{
    bind_iroh_endpoint, coord_register_heartbeat, coord_resolve_code, parse_custom_relay_urls,
    OpenUUTicket, PinRateLimiter, TICKET_PREFIX,
};

const MOCK_FRAMES_BIN: &[u8] = include_bytes!("../assets/mock_frames.bin");
const FULL_DESKTOP_BUNDLE_ID: &str = "__openuu_full_desktop__";
const FULL_DESKTOP_WINDOW_ID: u32 = 0x7FFF_FF00; // 2147483392

fn parse_flag(args: &[String], flag: &str) -> Option<String> {
    args.windows(2)
        .find(|w| w[0] == flag)
        .map(|w| w[1].clone())
}

struct MockFrame {
    flags: u8,
    data: Vec<u8>,
}

fn parse_mock_frames(raw: &[u8]) -> Vec<MockFrame> {
    let mut frames = Vec::new();
    let mut off = 0usize;
    while off + 5 <= raw.len() {
        let flags = raw[off];
        let len = u32::from_be_bytes([raw[off + 1], raw[off + 2], raw[off + 3], raw[off + 4]])
            as usize;
        off += 5;
        if off + len > raw.len() {
            break;
        }
        frames.push(MockFrame {
            flags,
            data: raw[off..off + len].to_vec(),
        });
        off += len;
    }
    frames
}

enum MockCallbackMsg {
    Control(String),
    Status(String),
}

struct MockCallbackCtx {
    tx: std_mpsc::Sender<MockCallbackMsg>,
}

fn emit_stdout_line(line: &str) {
    let stdout = std::io::stdout();
    let mut lock = stdout.lock();
    let _ = writeln!(lock, "{line}");
    let _ = lock.flush();
}

extern "C" fn mock_on_control(user_ctx: *mut c_void, event_json: *const c_char) {
    if user_ctx.is_null() || event_json.is_null() {
        return;
    }
    unsafe {
        let ctx = &*(user_ctx as *const MockCallbackCtx);
        let s = CStr::from_ptr(event_json).to_string_lossy().into_owned();
        emit_stdout_line(&format!("MOCK_EVENT {s}"));
        let _ = ctx.tx.send(MockCallbackMsg::Control(s));
    }
}

extern "C" fn mock_on_status(user_ctx: *mut c_void, status: *const c_char) {
    if user_ctx.is_null() || status.is_null() {
        return;
    }
    unsafe {
        let ctx = &*(user_ctx as *const MockCallbackCtx);
        let s = CStr::from_ptr(status).to_string_lossy().into_owned();
        emit_stdout_line(&format!("MOCK_STATUS {s}"));
        let _ = ctx.tx.send(MockCallbackMsg::Status(s));
    }
}

struct StreamState {
    active_windows: Vec<u32>,
    frame_idx: usize,
}

#[derive(Clone, Copy)]
struct RuntimePtr(*mut OpenUURuntime);
unsafe impl Send for RuntimePtr {}
unsafe impl Sync for RuntimePtr {}

impl RuntimePtr {
    fn as_ptr(self) -> *mut OpenUURuntime {
        self.0
    }
}

fn read_identity_json(rt: *mut OpenUURuntime) -> serde_json::Value {
    unsafe {
        let ptr = openuu_get_identity_json(rt);
        if ptr.is_null() {
            return serde_json::Value::Null;
        }
        let s = CStr::from_ptr(ptr).to_string_lossy().into_owned();
        openuu_free_string(ptr);
        serde_json::from_str(&s).unwrap_or(serde_json::Value::Null)
    }
}

fn run_mock_host(args: &[String]) -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter("info,openuu_core=info")
        .init();

    let port: u16 = parse_flag(args, "--port")
        .and_then(|s| s.parse().ok())
        .unwrap_or(39481);
    let pin = parse_flag(args, "--pin").unwrap_or_else(|| "123456".to_string());
    let config_dir = parse_flag(args, "--config-dir");

    let frames = Arc::new(parse_mock_frames(MOCK_FRAMES_BIN));
    if frames.is_empty() {
        return Err("embedded mock_frames.bin contains zero frames".into());
    }

    let device_name_c = CString::new("OpenUU-Mock-Mac")?;
    let config_dir_c = match config_dir.as_deref() {
        Some(dir) if !dir.trim().is_empty() => Some(CString::new(dir.trim())?),
        _ => None,
    };

    let rt = unsafe {
        openuu_runtime_create_with_dir(
            device_name_c.as_ptr(),
            config_dir_c
                .as_ref()
                .map_or(std::ptr::null(), |c| c.as_ptr()),
        )
    };
    if rt.is_null() {
        return Err("openuu_runtime_create_with_dir returned null".into());
    }

    let (cb_tx, cb_rx) = std_mpsc::channel::<MockCallbackMsg>();
    let cb_ctx = Box::new(MockCallbackCtx { tx: cb_tx });
    let cb_ctx_ptr = Box::into_raw(cb_ctx) as *mut c_void;

    let mut pin_buf = [0 as c_char; 64];
    let pin_bytes = pin.as_bytes();
    let copy_len = pin_bytes.len().min(pin_buf.len() - 1);
    for i in 0..copy_len {
        pin_buf[i] = pin_bytes[i] as c_char;
    }

    let bound_port = unsafe {
        openuu_start_host(
            rt,
            port,
            pin_buf.as_mut_ptr(),
            pin_buf.len(),
            Some(mock_on_control),
            None,
            Some(mock_on_status),
            cb_ctx_ptr,
        )
    };
    if bound_port == 0 {
        unsafe {
            openuu_runtime_destroy(rt);
            drop(Box::from_raw(cb_ctx_ptr as *mut MockCallbackCtx));
        }
        return Err(format!("openuu_start_host failed on port {port}").into());
    }

    let actual_pin = unsafe {
        CStr::from_ptr(pin_buf.as_ptr())
            .to_string_lossy()
            .into_owned()
    };

    // Wait up to ~5s for WAN host_ticket (including RelayUrl/Coord registration when WAN is reachable).
    let wait_start = Instant::now();
    let mut device_code = String::new();
    let mut host_ticket = String::new();
    loop {
        let id_val = read_identity_json(rt);
        if let Some(code) = id_val.get("device_code").and_then(|v| v.as_str()) {
            device_code = code.to_string();
        }
        if let Some(ticket) = id_val.get("host_ticket").and_then(|v| v.as_str()) {
            host_ticket = ticket.to_string();
        }
        let coord_status = id_val
            .get("coord_status")
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let wan_settled = !host_ticket.is_empty()
            && !coord_status.is_empty()
            && coord_status != "未启动"
            && coord_status != "正在连接跨网打洞/中继网络...";
        if wan_settled || wait_start.elapsed() >= Duration::from_secs(5) {
            break;
        }
        std::thread::sleep(Duration::from_millis(150));
    }

    emit_stdout_line(&format!(
        "MOCK_HOST_READY port={bound_port} pin={actual_pin} code={device_code} ticket={host_ticket}"
    ));

    let stream_state = Arc::new(Mutex::new(StreamState {
        active_windows: Vec::new(),
        frame_idx: 0,
    }));

    // 25 FPS video streaming loop (40ms interval)
    let stream_state_vid = Arc::clone(&stream_state);
    let frames_vid = Arc::clone(&frames);
    let rt_ptr = RuntimePtr(rt);
    std::thread::spawn(move || {
        let start = Instant::now();
        let frame_interval = Duration::from_millis(40);
        let mut next_tick = Instant::now();
        loop {
            let now = Instant::now();
            if next_tick > now {
                std::thread::sleep(next_tick - now);
            }
            next_tick += frame_interval;
            let cur_now = Instant::now();
            if next_tick + frame_interval < cur_now {
                next_tick = cur_now + frame_interval;
            }

            let (windows, idx) = {
                let mut st = stream_state_vid.lock().unwrap();
                if st.active_windows.is_empty() {
                    continue;
                }
                let cur_idx = st.frame_idx % frames_vid.len();
                st.frame_idx = (cur_idx + 1) % frames_vid.len();
                (st.active_windows.clone(), cur_idx)
            };

            let frame = &frames_vid[idx];
            let ts_us = start.elapsed().as_micros() as u64;
            for wid in windows {
                unsafe {
                    openuu_send_video_frame(
                        rt_ptr.as_ptr(),
                        1, // H.264
                        frame.flags,
                        wid,
                        ts_us,
                        1920, // 2x Retina of 960x600
                        1200,
                        frame.data.as_ptr(),
                        frame.data.len(),
                    );
                }
            }
        }
    });

    // Control event loop
    while let Ok(msg) = cb_rx.recv() {
        match msg {
            MockCallbackMsg::Status(status) => {
                if status.contains("disconnected") {
                    if let Ok(mut st) = stream_state.lock() {
                        st.active_windows.clear();
                        st.frame_idx = 0;
                    }
                }
            }
            MockCallbackMsg::Control(event_json) => {
                let Ok(val) = serde_json::from_str::<serde_json::Value>(&event_json) else {
                    continue;
                };
                let evt_type = val.get("type").and_then(|v| v.as_str()).unwrap_or("");
                match evt_type {
                    "list_apps_req" => {
                        let apps = serde_json::json!([
                            {
                                "bundle_id": FULL_DESKTOP_BUNDLE_ID,
                                "name": "整台桌面",
                                "pid": 1,
                                "window_count": 1
                            },
                            {
                                "bundle_id": "com.tencent.xinWeChat",
                                "name": "微信",
                                "pid": 1001,
                                "window_count": 1
                            },
                            {
                                "bundle_id": "com.apple.Safari",
                                "name": "Safari",
                                "pid": 1002,
                                "window_count": 1
                            }
                        ]);
                        if let Ok(apps_c) = CString::new(apps.to_string()) {
                            unsafe {
                                openuu_send_app_list_json(rt, apps_c.as_ptr());
                            }
                        }

                        if let (Ok(bundle_c), Ok(title_c), Ok(sub_c), Ok(body_c)) = (
                            CString::new("com.tencent.xinWeChat"),
                            CString::new("OpenUU Remote Mac"),
                            CString::new("Mock Host Ready"),
                            CString::new("欢迎连接 OpenUU E2E 模拟主机，微信 / Safari 已就绪"),
                        ) {
                            unsafe {
                                openuu_send_notification(
                                    rt,
                                    bundle_c.as_ptr(),
                                    title_c.as_ptr(),
                                    sub_c.as_ptr(),
                                    body_c.as_ptr(),
                                    now_epoch_ms(),
                                );
                            }
                        }

                        if let (Ok(hash_c), Ok(text_c)) = (
                            CString::new("mock-host-welcome-clip-v1"),
                            CString::new("OpenUU Remote Mac · E2E Clipboard Ready"),
                        ) {
                            unsafe {
                                openuu_send_clipboard_text(rt, hash_c.as_ptr(), text_c.as_ptr());
                            }
                        }
                    }
                    "start_session" => {
                        let bundle_id = val
                            .get("bundle_id")
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        let (topology, windows): (serde_json::Value, Vec<u32>) =
                            if bundle_id == FULL_DESKTOP_BUNDLE_ID {
                                (
                                    serde_json::json!([
                                        {
                                            "window_id": FULL_DESKTOP_WINDOW_ID,
                                            "title": "Mac 整屏桌面",
                                            "width": 960.0,
                                            "height": 600.0,
                                            "kind": 0
                                        }
                                    ]),
                                    vec![FULL_DESKTOP_WINDOW_ID],
                                )
                            } else {
                                (
                                    serde_json::json!([
                                        {
                                            "window_id": 101,
                                            "title": "微信 - 聊天",
                                            "width": 960.0,
                                            "height": 600.0,
                                            "kind": 0
                                        },
                                        {
                                            "window_id": 102,
                                            "title": "Safari - OpenUU Docs",
                                            "width": 960.0,
                                            "height": 600.0,
                                            "kind": 0
                                        }
                                    ]),
                                    vec![101, 102],
                                )
                            };

                        if let Ok(topo_c) = CString::new(topology.to_string()) {
                            unsafe {
                                openuu_send_window_topology_json(rt, topo_c.as_ptr());
                            }
                        }
                        if let Ok(mut st) = stream_state.lock() {
                            st.active_windows = windows;
                            st.frame_idx = 0; // Start immediately on SPS+PPS+IDR keyframe
                        }
                    }
                    "stop_session" => {
                        let wid = val.get("window_id").and_then(|v| v.as_u64()).unwrap_or(0) as u32;
                        if let Ok(mut st) = stream_state.lock() {
                            if wid == 0 {
                                st.active_windows.clear();
                            } else {
                                st.active_windows.retain(|&w| w != wid);
                            }
                        }
                    }
                    "request_keyframe" => {
                        if let Ok(mut st) = stream_state.lock() {
                            st.frame_idx = 0;
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    unsafe {
        openuu_stop_host(rt);
        openuu_runtime_destroy(rt);
        drop(Box::from_raw(cb_ctx_ptr as *mut MockCallbackCtx));
    }
    Ok(())
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("mock-host") {
        return run_mock_host(&args);
    }

    tracing_subscriber::fmt()
        .with_env_filter("info,openuu_core=debug")
        .init();

    let rt = tokio::runtime::Runtime::new()?;
    rt.block_on(async_main(args))
}

async fn async_main(args: Vec<String>) -> Result<(), Box<dyn std::error::Error>> {
    match args.get(1).map(String::as_str) {
        Some("host") => {
            let port: u16 = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(39481);
            let identity = DeviceIdentity::load_or_create(None, None)?;
            let pin = generate_strong_access_code();
            let addr: SocketAddr = format!("0.0.0.0:{port}").parse()?;
            let endpoint = bind_host_endpoint(&identity, addr)?;
            let bound_port = endpoint.local_addr()?.port();

            let discovery = DiscoveryService::new()?;
            discovery.advertise_ext(
                &identity.device_id,
                &identity.device_name,
                std::env::consts::OS,
                bound_port,
                &identity.device_code,
                &identity.endpoint_id_str(),
            )?;

            println!("OpenUU Host listening on UDP port {bound_port}");
            println!("9-Digit Device Code: {}", identity.formatted_device_code());
            println!("Access Password: {pin}");
            println!("Waiting for Client...");

            let (session, mut channels, hello) =
                accept_client_session(&endpoint, &identity, Some(&pin)).await?;
            println!("Client connected: {} ({})", hello.device_name, hello.os);

            while let Some(env) = channels.control_rx.recv().await {
                println!("Received control: {:?}", env.payload);
                if let Some(pb::control_envelope::Payload::Ping(p)) = env.payload {
                    let pong = pb::ControlEnvelope {
                        seq: env.seq + 1,
                        payload: Some(pb::control_envelope::Payload::Pong(pb::Pong {
                            timestamp_us: p.timestamp_us,
                        })),
                    };
                    session.send_control(&pong).await?;
                }
            }
        }
        Some("wan-host") => {
            let mut identity = DeviceIdentity::load_or_create(None, None)?;
            if let Some(relay) = parse_flag(&args, "--relay") {
                identity.wan_config.relay_url = relay;
            }
            if let Some(tok) = parse_flag(&args, "--relay-token") {
                identity.wan_config.relay_auth_token = tok;
            }
            if let Some(coord) = parse_flag(&args, "--coord") {
                identity.wan_config.coord_url = coord;
            }
            if args.iter().any(|a| a == "--no-public-fallback") {
                identity.wan_config.enable_public_fallback = false;
            }
            let force_relay = args.iter().any(|a| a == "--force-relay");
            let pin = parse_flag(&args, "--pin").unwrap_or_else(generate_strong_access_code);
            let iroh_ep = bind_iroh_endpoint(&identity, false).await?;
            let _ = tokio::time::timeout(Duration::from_secs(6), iroh_ep.online()).await;

            let mut ticket = OpenUUTicket::from_endpoint(&iroh_ep, &identity, 0);
            if force_relay {
                ticket.direct_addrs.clear();
            }
            let ticket_str = ticket.encode()?;
            if !identity.wan_config.coord_url.is_empty() {
                match coord_register_heartbeat(
                    &identity.wan_config.coord_url,
                    identity.wan_config.allow_insecure_tls,
                    &identity,
                    &ticket_str,
                    Some(&pin),
                )
                .await
                {
                    Ok(resp) => println!("Registered with coord server: code={}", resp.assigned_code),
                    Err(e) => eprintln!("Warning: coord registration failed ({e})"),
                }
            }

            println!("=== OpenUU WAN P2P/Relay Host Ready ===");
            println!("Device Code : {}", identity.formatted_device_code());
            println!("Password    : {pin}");
            println!("EndpointId  : {}", iroh_ep.id());
            println!("Ticket      : {ticket_str}");

            let limiter = PinRateLimiter::default();
            let (session, mut channels, hello, _) =
                accept_iroh_session(&iroh_ep, &identity, Some(&pin), &limiter).await?;
            let link = session.link_telemetry();
            println!(
                "WAN Client connected: {} (mode={}, rtt={}ms)",
                hello.device_name,
                link.mode.as_str(),
                link.rtt_ms
            );

            while let Some(env) = channels.control_rx.recv().await {
                if let Some(pb::control_envelope::Payload::Ping(p)) = env.payload {
                    let pong = pb::ControlEnvelope {
                        seq: env.seq + 1,
                        payload: Some(pb::control_envelope::Payload::Pong(pb::Pong {
                            timestamp_us: p.timestamp_us,
                        })),
                    };
                    session.send_control(&pong).await?;
                }
            }
        }
        Some("wan-client") => {
            let target = args
                .get(2)
                .ok_or("usage: openuu-cli wan-client <9-digit-code | openuu://ticket> [pin] [--coord URL] [--relay URL]")?;
            let pin = args
                .get(3)
                .filter(|s| !s.starts_with("--"))
                .cloned()
                .unwrap_or_default();
            let mut identity = DeviceIdentity::load_or_create(None, None)?;
            if let Some(relay) = parse_flag(&args, "--relay") {
                identity.wan_config.relay_url = relay;
            }
            if let Some(tok) = parse_flag(&args, "--relay-token") {
                identity.wan_config.relay_auth_token = tok;
            }
            if let Some(coord) = parse_flag(&args, "--coord") {
                identity.wan_config.coord_url = coord;
            }
            if args.iter().any(|a| a == "--no-public-fallback") {
                identity.wan_config.enable_public_fallback = false;
            }
            let force_relay = args.iter().any(|a| a == "--force-relay");

            let extra_relays = parse_custom_relay_urls(&identity.wan_config.relay_url);
            let mut ticket = if target.starts_with(TICKET_PREFIX) {
                OpenUUTicket::decode(target)?
            } else if normalize_device_code(target).len() == 9 {
                let resp = coord_resolve_code(
                    &identity.wan_config.coord_url,
                    identity.wan_config.allow_insecure_tls,
                    target,
                    &pin,
                )
                .await?;
                OpenUUTicket::decode(&resp.ticket)?
            } else {
                return Err("target must be a 9-digit device code or openuu:// ticket".into());
            };
            if force_relay {
                ticket.direct_addrs.clear();
            }

            let ep_addr = ticket.to_endpoint_addr(&extra_relays)?;
            let iroh_ep = bind_iroh_endpoint(&identity, false).await?;
            let (session, mut channels, ack, _) =
                connect_via_iroh(&iroh_ep, &identity, ep_addr, &pin).await?;
            let link = session.link_telemetry();
            println!(
                "Connected to WAN Host: {} (mode={}, rtt={}ms)",
                ack.device_name,
                link.mode.as_str(),
                link.rtt_ms
            );

            let ping = pb::ControlEnvelope {
                seq: 2,
                payload: Some(pb::control_envelope::Payload::Ping(pb::Ping {
                    timestamp_us: 99,
                })),
            };
            session.send_control(&ping).await?;
            if let Some(resp) = channels.control_rx.recv().await {
                println!("WAN Host replied: {:?}", resp.payload);
            }
            session.close();
            iroh_ep.close().await;
        }
        Some("discover") => {
            let discovery = DiscoveryService::new()?;
            discovery.start_browsing(None)?;
            println!("Browsing LAN for OpenUU Hosts (5s)...");
            tokio::time::sleep(Duration::from_secs(5)).await;
            let peers = discovery.list_peers();
            if peers.is_empty() {
                println!("No OpenUU Hosts found.");
            } else {
                for p in peers {
                    println!(
                        "- {} [code: {}] ({}) {:?}:{}",
                        p.device_name, p.device_code, p.os, p.addresses, p.port
                    );
                }
            }
        }
        Some("client") => {
            let addr_str = args
                .get(2)
                .ok_or("usage: openuu-cli client <ip:port> <pin>")?;
            let pin = args
                .get(3)
                .ok_or("usage: openuu-cli client <ip:port> <pin>")?;
            let addr: SocketAddr = addr_str.parse()?;
            let identity = DeviceIdentity::load_or_create(None, None)?;
            let (session, mut channels, ack) = connect_to_host(&identity, addr, pin).await?;
            println!("Connected to Host: {} ({})", ack.device_name, ack.os);

            let ping = pb::ControlEnvelope {
                seq: 2,
                payload: Some(pb::control_envelope::Payload::Ping(pb::Ping {
                    timestamp_us: 42,
                })),
            };
            session.send_control(&ping).await?;
            if let Some(resp) = channels.control_rx.recv().await {
                println!("Host replied: {:?}", resp.payload);
            }
            session.close();
        }
        _ => {
            println!("Usage:");
            println!("  openuu-cli host [port]");
            println!("  openuu-cli discover");
            println!("  openuu-cli client <ip:port> <pin>");
            println!("  openuu-cli wan-host [--relay URL] [--coord URL] [--pin CODE]");
            println!("  openuu-cli wan-client <9-digit-code | openuu://ticket> [pin] [--relay URL] [--coord URL]");
            println!("  openuu-cli mock-host [--port 39481] [--pin 123456] [--config-dir /tmp/...]");
        }
    }

    Ok(())
}

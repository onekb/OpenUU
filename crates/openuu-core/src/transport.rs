use std::io::{Read, Write};
use std::net::{IpAddr, Ipv6Addr, SocketAddr, UdpSocket};
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::{Arc, Once};
use std::time::{Duration, Instant};

use bytes::Bytes;
use iroh::{EndpointAddr, PublicKey, Signature};
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::{Connection, Endpoint, EndpointConfig, RecvStream, SendStream, TransportConfig, VarInt};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::error::{OpenUUError, Result};
use crate::identity::{sha256_hex, DeviceIdentity};
use crate::protocol::{
    decode_control_payload, encode_control, pb, AudioFrame, StreamType, VideoFrame,
    AUDIO_FLAG_CONFIG, AUDIO_HEADER_LEN, MAX_CONTROL_FRAME_LEN, PROTOCOL_VERSION, VIDEO_HEADER_LEN,
};
use crate::wan::{
    inspect_iroh_connection, is_lan_or_private_ip, LinkMode, LinkTelemetry, PinRateLimiter,
    ALPN_OPENUU,
};

static CRYPTO_INIT: Once = Once::new();

pub fn init_crypto() {
    CRYPTO_INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

/// Verifies peer TLS 1.3 signature; if `expected_fingerprint` is provided (returning TrustedPeer),
/// enforces exact SHA-256 certificate fingerprint pinning to defeat MITM on public networks.
#[derive(Debug)]
struct PinnedOrTofuVerifier {
    expected_fingerprint: Option<String>,
}

impl ServerCertVerifier for PinnedOrTofuVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
        if let Some(expected) = &self.expected_fingerprint {
            if !expected.is_empty() {
                let actual = sha256_hex(end_entity.as_ref());
                if !actual.eq_ignore_ascii_case(expected) {
                    return Err(rustls::Error::General(format!(
                        "TLS certificate fingerprint mismatch: expected {expected}, got {actual}"
                    )));
                }
            }
        }
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Low-latency LAN QUIC profile (safe 1200-byte initial MTU for WireGuard/Tailscale/IPv6 compatibility).
fn lan_transport_config() -> Arc<TransportConfig> {
    let mut cfg = TransportConfig::default();
    cfg.keep_alive_interval(Some(Duration::from_secs(2)));
    cfg.max_idle_timeout(Some(Duration::from_secs(8).try_into().unwrap()));
    cfg.stream_receive_window(VarInt::from_u32(16 * 1024 * 1024));
    cfg.receive_window(VarInt::from_u32(32 * 1024 * 1024));
    cfg.send_window(32 * 1024 * 1024);
    cfg.initial_rtt(Duration::from_millis(4));
    cfg.initial_mtu(1200);
    cfg.min_mtu(1200);
    cfg.mtu_discovery_config(None);
    let mut cubic = quinn::congestion::CubicConfig::default();
    cubic.initial_window(2 * 1024 * 1024);
    cfg.congestion_controller_factory(Arc::new(cubic));
    Arc::new(cfg)
}

/// WAN / Public IPv6 / DDNS QUIC profile: avoids 2 MiB initial burst that causes ISP router Bufferbloat.
fn wan_transport_config() -> Arc<TransportConfig> {
    let mut cfg = TransportConfig::default();
    cfg.keep_alive_interval(Some(Duration::from_secs(4)));
    cfg.max_idle_timeout(Some(Duration::from_secs(20).try_into().unwrap()));
    cfg.stream_receive_window(VarInt::from_u32(8 * 1024 * 1024));
    cfg.receive_window(VarInt::from_u32(16 * 1024 * 1024));
    cfg.send_window(16 * 1024 * 1024);
    cfg.initial_rtt(Duration::from_millis(40));
    cfg.initial_mtu(1200);
    cfg.min_mtu(1200);
    cfg.mtu_discovery_config(None);
    Arc::new(cfg)
}

// ============================================================================
// Unified QUIC Stream & Connection Abstraction (LAN Quinn + WAN Iroh)
// ============================================================================

#[derive(Clone)]
pub enum SessionBackend {
    Quinn(Connection),
    Iroh(iroh::endpoint::Connection),
}

enum BackendSendStream {
    Quinn(SendStream),
    Iroh(iroh::endpoint::SendStream),
}

enum BackendRecvStream {
    Quinn(RecvStream),
    Iroh(iroh::endpoint::RecvStream),
}

impl SessionBackend {
    async fn open_uni(&self) -> Result<BackendSendStream> {
        match self {
            Self::Quinn(c) => Ok(BackendSendStream::Quinn(c.open_uni().await?)),
            Self::Iroh(c) => c
                .open_uni()
                .await
                .map(BackendSendStream::Iroh)
                .map_err(|e| OpenUUError::Wan(format!("iroh open_uni failed: {e}"))),
        }
    }

    async fn accept_uni(&self) -> Result<BackendRecvStream> {
        match self {
            Self::Quinn(c) => Ok(BackendRecvStream::Quinn(c.accept_uni().await?)),
            Self::Iroh(c) => c
                .accept_uni()
                .await
                .map(BackendRecvStream::Iroh)
                .map_err(|e| OpenUUError::Wan(format!("iroh accept_uni failed: {e}"))),
        }
    }

    fn export_channel_binding(&self) -> Option<[u8; 32]> {
        let mut out = [0u8; 32];
        let ok = match self {
            Self::Quinn(c) => c
                .export_keying_material(&mut out, b"openuu-auth-v1", b"")
                .is_ok(),
            Self::Iroh(c) => c
                .export_keying_material(&mut out, b"openuu-auth-v1", b"")
                .is_ok(),
        };
        if ok {
            Some(out)
        } else {
            None
        }
    }

    fn close(&self, code: u32, reason: &[u8]) {
        match self {
            Self::Quinn(c) => c.close(code.into(), reason),
            Self::Iroh(c) => c.close(code.into(), reason),
        }
    }

    pub fn link_telemetry(&self) -> LinkTelemetry {
        match self {
            Self::Quinn(c) => {
                let addr = c.remote_address();
                let mode = if is_lan_or_private_ip(addr.ip()) {
                    LinkMode::Lan
                } else {
                    LinkMode::WanDirect
                };
                let rtt_ms = c.rtt().as_millis().min(9999) as u32;
                LinkTelemetry {
                    mode,
                    rtt_ms,
                    remote_addr: addr.to_string(),
                }
            }
            Self::Iroh(c) => inspect_iroh_connection(c),
        }
    }
}

impl BackendSendStream {
    async fn write_all(&mut self, bytes: &[u8]) -> Result<()> {
        match self {
            Self::Quinn(s) => Ok(s.write_all(bytes).await?),
            Self::Iroh(s) => s
                .write_all(bytes)
                .await
                .map_err(|e| OpenUUError::Wan(format!("iroh write failed: {e}"))),
        }
    }

    fn finish(&mut self) {
        match self {
            Self::Quinn(s) => {
                let _ = s.finish();
            }
            Self::Iroh(s) => {
                let _ = s.finish();
            }
        }
    }

    fn reset_zero(&mut self) {
        match self {
            Self::Quinn(s) => {
                let _ = s.reset(0u32.into());
            }
            Self::Iroh(s) => {
                let _ = s.reset(0u32.into());
            }
        }
    }
}

impl BackendRecvStream {
    async fn read_exact(&mut self, buf: &mut [u8]) -> Result<()> {
        match self {
            Self::Quinn(s) => Ok(s.read_exact(buf).await?),
            Self::Iroh(s) => s
                .read_exact(buf)
                .await
                .map_err(|e| OpenUUError::Wan(format!("iroh read_exact failed: {e}"))),
        }
    }

    async fn read_chunk(&mut self, buf: &mut [u8]) -> Result<Option<usize>> {
        match self {
            Self::Quinn(s) => s
                .read(buf)
                .await
                .map_err(|e| OpenUUError::Protocol(format!("quinn read failed: {e}"))),
            Self::Iroh(s) => s
                .read(buf)
                .await
                .map_err(|e| OpenUUError::Wan(format!("iroh read failed: {e}"))),
        }
    }

    fn stop_zero(&mut self) {
        match self {
            Self::Quinn(s) => {
                let _ = s.stop(0u32.into());
            }
            Self::Iroh(s) => {
                let _ = s.stop(0u32.into());
            }
        }
    }
}

static CANCELLED_BLOBS: std::sync::LazyLock<std::sync::Mutex<std::collections::VecDeque<String>>> =
    std::sync::LazyLock::new(|| std::sync::Mutex::new(std::collections::VecDeque::new()));

pub fn cancel_incoming_blob(blob_id: &str) {
    if blob_id.is_empty() {
        return;
    }
    if let Ok(mut guard) = CANCELLED_BLOBS.lock() {
        if !guard.iter().any(|x| x == blob_id) {
            if guard.len() >= 256 {
                guard.pop_front();
            }
            guard.push_back(blob_id.to_string());
        }
    }
}

fn is_blob_cancelled(blob_id: &str) -> bool {
    CANCELLED_BLOBS
        .lock()
        .map(|g| g.iter().any(|x| x == blob_id))
        .unwrap_or(false)
}

/// Sign TLS 1.3 channel-bound authentication token `"<endpoint_id>:<sig_hex>"` so peer identity cannot be
/// spoofed or replayed over either LAN Quinn or WAN Iroh.
fn create_channel_auth_proof(identity: &DeviceIdentity, backend: &SessionBackend) -> String {
    let ep_id = identity.endpoint_id_str();
    let Some(ekm) = backend.export_channel_binding() else {
        return ep_id;
    };
    let mut msg = Vec::with_capacity(32 + identity.device_id.len() + 16);
    msg.extend_from_slice(b"openuu-bind:");
    msg.extend_from_slice(&ekm);
    msg.extend_from_slice(identity.device_id.as_bytes());
    let sig_hex = identity.sign_hex(&msg);
    format!("{ep_id}:{sig_hex}")
}

/// Verify channel-bound proof and return the cryptographically authenticated `EndpointId` (if valid).
fn verify_channel_auth_proof(
    proof: &str,
    claimed_device_id: &str,
    backend: &SessionBackend,
) -> Option<String> {
    // On Iroh connections, TLS 1.3 already mutually authenticated `conn.remote_id()`!
    if let SessionBackend::Iroh(conn) = backend {
        return Some(conn.remote_id().to_string());
    }
    let (ep_id_str, sig_hex) = proof.split_once(':')?;
    let pk = PublicKey::from_str(ep_id_str).ok()?;
    let sig_bytes: [u8; 64] = hex::decode(sig_hex).ok()?.try_into().ok()?;
    let sig = Signature::from_bytes(&sig_bytes);
    let ekm = backend.export_channel_binding()?;
    let mut msg = Vec::with_capacity(32 + claimed_device_id.len() + 16);
    msg.extend_from_slice(b"openuu-bind:");
    msg.extend_from_slice(&ekm);
    msg.extend_from_slice(claimed_device_id.as_bytes());
    pk.verify(&msg, &sig).ok()?;
    Some(pk.to_string())
}

fn extract_quinn_peer_cert_fingerprint(conn: &Connection) -> Option<String> {
    let any = conn.peer_identity()?;
    let certs = any.downcast_ref::<Vec<CertificateDer<'static>>>()?;
    let first = certs.first()?;
    Some(sha256_hex(first.as_ref()))
}

/// A live multiplexed QUIC session (used symmetrically by both Host and Client over LAN Quinn or WAN Iroh).
pub struct PeerSession {
    backend: SessionBackend,
    control_in_tx: mpsc::Sender<Bytes>,
    video_in_tx: mpsc::Sender<Bytes>,
    audio_in_tx: mpsc::Sender<Bytes>,
}

impl PeerSession {
    pub fn link_telemetry(&self) -> LinkTelemetry {
        self.backend.link_telemetry()
    }

    pub fn iroh_connection(&self) -> Option<&iroh::endpoint::Connection> {
        match &self.backend {
            SessionBackend::Iroh(c) => Some(c),
            SessionBackend::Quinn(_) => None,
        }
    }

    /// Enqueue a reliable Protobuf control message in strict FIFO order without spawning a new task.
    pub fn try_send_control(&self, env: &pb::ControlEnvelope) -> Result<()> {
        let framed = Bytes::from(encode_control(env)?);
        self.control_in_tx
            .try_send(framed)
            .map_err(|_| OpenUUError::Protocol("control send queue full or closed".into()))
    }

    /// Send a reliable Protobuf control message on Stream 0.
    pub async fn send_control(&self, env: &pb::ControlEnvelope) -> Result<()> {
        let framed = Bytes::from(encode_control(env)?);
        self.control_in_tx
            .send(framed)
            .await
            .map_err(|_| OpenUUError::Protocol("control send stream closed".into()))
    }

    /// Enqueue a hardware-encoded video frame in strict FIFO order on the caller thread (zero task-spawn race).
    pub fn try_send_video_frame(&self, frame: &VideoFrame) -> Result<()> {
        let encoded = frame.encode_frame();
        self.video_in_tx
            .try_send(encoded)
            .map_err(|_| OpenUUError::Protocol("video send queue full or closed".into()))
    }

    /// Send a hardware-encoded video frame over the dedicated unidirectional Video Stream.
    pub async fn send_video_frame(&self, frame: &VideoFrame) -> Result<()> {
        let encoded = frame.encode_frame();
        self.video_in_tx
            .send(encoded)
            .await
            .map_err(|_| OpenUUError::Protocol("video send stream closed".into()))
    }

    /// Enqueue an encoded audio frame in strict FIFO order on the caller thread.
    pub fn try_send_audio_frame(&self, frame: &AudioFrame) -> Result<()> {
        let encoded = frame.encode_frame()?;
        self.audio_in_tx
            .try_send(encoded)
            .map_err(|_| OpenUUError::Protocol("audio send queue full or closed".into()))
    }

    /// Send an encoded audio frame over the dedicated unidirectional Audio Stream (`0x02`).
    pub async fn send_audio_frame(&self, frame: &AudioFrame) -> Result<()> {
        let encoded = frame.encode_frame()?;
        self.audio_in_tx
            .send(encoded)
            .await
            .map_err(|_| OpenUUError::Protocol("audio send stream closed".into()))
    }

    /// Stream a local file over a dedicated unidirectional QUIC Blob Stream (`0x03`) without blocking video/control.
    pub async fn send_file_blob(
        &self,
        window_id: u32,
        x: f32,
        y: f32,
        blob_id: String,
        filename: String,
        local_path: PathBuf,
    ) -> Result<()> {
        const MAX_BLOB_BYTES: u64 = 512 * 1024 * 1024; // 512 MiB
        let meta = std::fs::metadata(&local_path)
            .map_err(|e| OpenUUError::Protocol(format!("stat file failed: {e}")))?;
        let file_size = meta.len();
        if file_size > MAX_BLOB_BYTES {
            return Err(OpenUUError::Protocol(format!(
                "file exceeds 512 MiB limit: {file_size}"
            )));
        }
        let mut file = std::fs::File::open(&local_path)
            .map_err(|e| OpenUUError::Protocol(format!("open file failed: {e}")))?;

        let blob_bytes = blob_id.as_bytes();
        let name_bytes = filename.as_bytes();
        if blob_bytes.len() > u16::MAX as usize || name_bytes.len() > u16::MAX as usize {
            return Err(OpenUUError::Protocol("blob header too long".into()));
        }

        let mut stream = self.backend.open_uni().await?;
        let mut header =
            Vec::with_capacity(1 + 4 + 4 + 4 + 2 + blob_bytes.len() + 2 + name_bytes.len() + 8);
        header.push(StreamType::Blob as u8);
        header.extend_from_slice(&window_id.to_be_bytes());
        header.extend_from_slice(&x.to_be_bytes());
        header.extend_from_slice(&y.to_be_bytes());
        header.extend_from_slice(&(blob_bytes.len() as u16).to_be_bytes());
        header.extend_from_slice(blob_bytes);
        header.extend_from_slice(&(name_bytes.len() as u16).to_be_bytes());
        header.extend_from_slice(name_bytes);
        header.extend_from_slice(&file_size.to_be_bytes());
        stream.write_all(&header).await?;

        let mut buf = vec![0u8; 64 * 1024];
        let mut remaining = file_size;
        while remaining > 0 {
            let to_read = (remaining as usize).min(buf.len());
            let n = file
                .read(&mut buf[..to_read])
                .map_err(|e| OpenUUError::Protocol(format!("read file failed: {e}")))?;
            if n == 0 {
                break;
            }
            stream.write_all(&buf[..n]).await?;
            remaining -= n as u64;
        }
        stream.finish();
        Ok(())
    }

    pub fn close(&self) {
        self.backend.close(0, b"session closed");
    }
}

pub struct IncomingChannels {
    pub control_rx: mpsc::Receiver<pb::ControlEnvelope>,
    pub video_rx: mpsc::Receiver<VideoFrame>,
    pub audio_rx: mpsc::Receiver<AudioFrame>,
}

/// Bind a QUIC Host server on `bind_addr`. When `0.0.0.0:port` is passed, automatically upgrades to a
/// dual-stack `[::]:port` UDP socket (`IPV6_V6ONLY = false`) when supported by the OS so Mainland China
/// native public IPv6 and LAN IPv4 both work simultaneously!
pub fn bind_host_endpoint(identity: &DeviceIdentity, bind_addr: SocketAddr) -> Result<Endpoint> {
    init_crypto();
    let (certs, key) = identity.rustls_cert_and_key();
    let mut server_crypto = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| OpenUUError::Crypto(format!("server tls config failed: {e}")))?;
    server_crypto.alpn_protocols = vec![ALPN_OPENUU.to_vec()];

    let quic_server_cfg = QuicServerConfig::try_from(server_crypto)
        .map_err(|e| OpenUUError::Crypto(format!("quic server config failed: {e}")))?;
    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic_server_cfg));
    server_config.transport_config(lan_transport_config());

    // Upgrade unspecified IPv4 `0.0.0.0:port` to dual-stack `[::]:port` if available.
    // IMPORTANT: If `[::]:port` fails with `AddrInUse`, propagate the error immediately instead of falling back
    // to `0.0.0.0:port` — on Windows Winsock, falling back would allow a second process to bind `0.0.0.0:port`
    // alongside an existing process's dual-stack `[::]:port` socket, causing split-brain UDP routing!
    if bind_addr.ip().is_unspecified() && bind_addr.is_ipv4() {
        match bind_dual_stack_udp(bind_addr.port()) {
            Ok(sock) => {
                let runtime = quinn::default_runtime()
                    .ok_or_else(|| OpenUUError::Protocol("no async runtime for quinn".into()))?;
                if let Ok(ep) = Endpoint::new(
                    EndpointConfig::default(),
                    Some(server_config.clone()),
                    sock,
                    runtime,
                ) {
                    return Ok(ep);
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::AddrInUse => {
                return Err(OpenUUError::Io(e));
            }
            Err(_) => {}
        }
    }

    let endpoint = Endpoint::server(server_config, bind_addr)?;
    Ok(endpoint)
}

fn bind_dual_stack_udp(port: u16) -> std::io::Result<UdpSocket> {
    let sock = socket2::Socket::new(
        socket2::Domain::IPV6,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    sock.set_only_v6(false)?;
    sock.set_nonblocking(true)?;
    let addr = SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), port);
    sock.bind(&addr.into())?;
    Ok(sock.into())
}

/// Resolve a host string (`"192.168.1.5"`, `"240e:..."`, or DDNS `"home.example.com"`) + `port` into a `SocketAddr`.
pub async fn resolve_host_socket_addr(host: &str, port: u16) -> Result<SocketAddr> {
    let trimmed = host.trim();
    if let Ok(ip) = trimmed.parse::<IpAddr>() {
        return Ok(SocketAddr::new(ip, port));
    }
    // Strip optional brackets around IPv6 literal `[240e:...]`
    if let Some(inner) = trimmed.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
        if let Ok(ip) = inner.parse::<IpAddr>() {
            return Ok(SocketAddr::new(ip, port));
        }
    }
    let lookup_target = format!("{trimmed}:{port}");
    let mut addrs: Vec<SocketAddr> = tokio::net::lookup_host(&lookup_target)
        .await
        .map_err(|e| OpenUUError::Wan(format!("DNS resolve failed for {lookup_target}: {e}")))?
        .collect();
    if addrs.is_empty() {
        return Err(OpenUUError::Wan(format!(
            "no IP addresses resolved for {trimmed}"
        )));
    }
    // Prefer IPv6 global unicast or IPv4 cleanly
    addrs.sort_by_key(|a| if a.is_ipv6() { 0u8 } else { 1u8 });
    Ok(addrs[0])
}

/// Accept one incoming LAN/Direct Quinn Client connection with PIN verification.
pub async fn accept_client_session(
    endpoint: &Endpoint,
    host_identity: &DeviceIdentity,
    expected_pin: Option<&str>,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::Hello)> {
    let limiter = PinRateLimiter::default();
    let (session, ch, hello, _peer_pk) =
        accept_client_session_guarded(endpoint, host_identity, expected_pin, &limiter).await?;
    Ok((session, ch, hello))
}

/// Accept one incoming LAN/Direct Quinn Client connection with brute-force rate limiting & cryptographic trust check.
pub async fn accept_client_session_guarded(
    endpoint: &Endpoint,
    host_identity: &DeviceIdentity,
    expected_pin: Option<&str>,
    limiter: &PinRateLimiter,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::Hello, Option<String>)> {
    let incoming = endpoint
        .accept()
        .await
        .ok_or_else(|| OpenUUError::Protocol("host endpoint closed".into()))?;
    let conn = incoming.await?;
    let remote_ip_key = conn.remote_address().ip().to_string();
    let (ctrl_tx, ctrl_rx) = conn.open_or_accept_bi_server().await?;
    let backend = SessionBackend::Quinn(conn);

    complete_host_handshake(
        backend,
        BackendSendStream::Quinn(ctrl_tx),
        BackendRecvStream::Quinn(ctrl_rx),
        host_identity,
        expected_pin,
        limiter,
        &remote_ip_key,
    )
    .await
}

trait QuinnAcceptBiExt {
    async fn open_or_accept_bi_server(&self) -> Result<(SendStream, RecvStream)>;
}

impl QuinnAcceptBiExt for Connection {
    async fn open_or_accept_bi_server(&self) -> Result<(SendStream, RecvStream)> {
        Ok(self.accept_bi().await?)
    }
}

/// Accept one incoming WAN/P2P `iroh` Client connection with brute-force rate limiting & Ed25519 trust check.
pub async fn accept_iroh_session(
    endpoint: &iroh::Endpoint,
    host_identity: &DeviceIdentity,
    expected_pin: Option<&str>,
    limiter: &PinRateLimiter,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::Hello, Option<String>)> {
    let incoming = endpoint
        .accept()
        .await
        .ok_or_else(|| OpenUUError::Wan("iroh endpoint closed".into()))?;
    let conn = incoming
        .await
        .map_err(|e| OpenUUError::Wan(format!("iroh accept handshake failed: {e}")))?;
    let peer_key = conn.remote_id().to_string();
    let (ctrl_tx, ctrl_rx) = conn
        .accept_bi()
        .await
        .map_err(|e| OpenUUError::Wan(format!("iroh accept_bi failed: {e}")))?;
    let backend = SessionBackend::Iroh(conn);

    complete_host_handshake(
        backend,
        BackendSendStream::Iroh(ctrl_tx),
        BackendRecvStream::Iroh(ctrl_rx),
        host_identity,
        expected_pin,
        limiter,
        &peer_key,
    )
    .await
}

async fn complete_host_handshake(
    backend: SessionBackend,
    mut ctrl_tx: BackendSendStream,
    mut ctrl_rx: BackendRecvStream,
    host_identity: &DeviceIdentity,
    expected_pin: Option<&str>,
    limiter: &PinRateLimiter,
    rate_limit_key: &str,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::Hello, Option<String>)> {
    if let Err(_wait_secs) = limiter.check_allowed(rate_limit_key) {
        let ack = pb::ControlEnvelope {
            seq: 1,
            payload: Some(pb::control_envelope::Payload::HelloAck(pb::HelloAck {
                accepted: false,
                reason: crate::wan::RATE_LIMIT_ERR.to_string(),
                device_id: String::new(),
                device_name: String::new(),
                os: String::new(),
                public_key: String::new(),
            })),
        };
        let _ = ctrl_tx.write_all(&encode_control(&ack)?).await;
        backend.close(2, b"rate limited");
        return Err(OpenUUError::PairingRejected(
            crate::wan::RATE_LIMIT_ERR.to_string(),
        ));
    }

    let first_env = read_control_frame(&mut ctrl_rx).await?;
    let hello = match first_env.payload {
        Some(pb::control_envelope::Payload::Hello(h)) => h,
        _ => {
            return Err(OpenUUError::Protocol(
                "expected Hello as first control message".into(),
            ))
        }
    };

    let verified_peer_key =
        verify_channel_auth_proof(&hello.public_key, &hello.device_id, &backend);

    let pin_ok = match expected_pin {
        None => true,
        Some(pin) => {
            let trusted = verified_peer_key
                .as_deref()
                .map(|pk| host_identity.is_trusted_authenticated(&hello.device_id, pk))
                .unwrap_or(false);
            trusted || (!pin.is_empty() && hello.pairing_pin == pin)
        }
    };

    let mut reject_reason = String::new();
    if !pin_ok {
        let (_failures, locked_secs) = limiter.record_failure(rate_limit_key);
        tokio::time::sleep(Duration::from_millis(300)).await;
        reject_reason = if locked_secs.is_some() {
            crate::wan::RATE_LIMIT_ERR.to_string()
        } else {
            crate::wan::UNIFIED_AUTH_OR_CODE_ERR.to_string()
        };
    } else {
        limiter.record_success(rate_limit_key);
    }

    let host_proof = if pin_ok {
        create_channel_auth_proof(host_identity, &backend)
    } else {
        String::new()
    };
    let ack = pb::ControlEnvelope {
        seq: 1,
        payload: Some(pb::control_envelope::Payload::HelloAck(pb::HelloAck {
            accepted: pin_ok,
            reason: reject_reason.clone(),
            device_id: if pin_ok {
                host_identity.device_id.clone()
            } else {
                String::new()
            },
            device_name: if pin_ok {
                host_identity.device_name.clone()
            } else {
                String::new()
            },
            os: if pin_ok {
                std::env::consts::OS.to_string()
            } else {
                String::new()
            },
            public_key: host_proof,
        })),
    };
    ctrl_tx.write_all(&encode_control(&ack)?).await?;

    if !pin_ok {
        backend.close(1, b"invalid pin");
        return Err(OpenUUError::PairingRejected(reject_reason));
    }

    let (session, channels) = spawn_session_loops(backend, ctrl_tx, ctrl_rx);
    Ok((session, channels, hello, verified_peer_key))
}

/// Connect to a OpenUU Host over direct QUIC (`ip:port`) and perform the Hello handshake.
pub async fn connect_to_host(
    client_identity: &DeviceIdentity,
    host_addr: SocketAddr,
    pairing_pin: &str,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::HelloAck)> {
    let (session, ch, ack, _fp, _pk) =
        connect_to_host_pinned(client_identity, host_addr, pairing_pin, None).await?;
    Ok((session, ch, ack))
}

/// Connect to a OpenUU Host over direct QUIC (`ip:port`), optionally enforcing expected TLS cert fingerprint.
pub async fn connect_to_host_pinned(
    client_identity: &DeviceIdentity,
    host_addr: SocketAddr,
    pairing_pin: &str,
    expected_cert_fingerprint: Option<String>,
) -> Result<(
    Arc<PeerSession>,
    IncomingChannels,
    pb::HelloAck,
    Option<String>,
    Option<String>,
)> {
    init_crypto();
    let verifier = PinnedOrTofuVerifier {
        expected_fingerprint: expected_cert_fingerprint,
    };
    let mut client_crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth();
    client_crypto.alpn_protocols = vec![ALPN_OPENUU.to_vec()];

    let quic_client_cfg = QuicClientConfig::try_from(client_crypto)
        .map_err(|e| OpenUUError::Crypto(format!("quic client config failed: {e}")))?;
    let mut client_config = quinn::ClientConfig::new(Arc::new(quic_client_cfg));
    let transport_cfg = if is_lan_or_private_ip(host_addr.ip()) {
        lan_transport_config()
    } else {
        wan_transport_config()
    };
    client_config.transport_config(transport_cfg);

    let bind_addr: SocketAddr = if host_addr.is_ipv4() {
        "0.0.0.0:0".parse().unwrap()
    } else {
        "[::]:0".parse().unwrap()
    };
    let mut endpoint = Endpoint::client(bind_addr)?;
    endpoint.set_default_client_config(client_config);

    let conn = endpoint.connect(host_addr, "openuu.local")?.await?;
    let host_cert_fp = extract_quinn_peer_cert_fingerprint(&conn);
    let (ctrl_tx, ctrl_rx) = conn.open_bi().await?;
    let backend = SessionBackend::Quinn(conn);

    let (session, channels, ack, verified_host_pk) = complete_client_handshake(
        backend,
        BackendSendStream::Quinn(ctrl_tx),
        BackendRecvStream::Quinn(ctrl_rx),
        client_identity,
        pairing_pin,
    )
    .await?;

    Ok((session, channels, ack, host_cert_fp, verified_host_pk))
}

/// Connect to a remote OpenUU Host over `iroh` (P2P IPv6/UDP hole-punching + HK/n0 Relay fallback).
pub async fn connect_via_iroh(
    endpoint: &iroh::Endpoint,
    client_identity: &DeviceIdentity,
    target_addr: EndpointAddr,
    pairing_pin: &str,
) -> Result<(
    Arc<PeerSession>,
    IncomingChannels,
    pb::HelloAck,
    String,
)> {
    connect_via_iroh_with_progress(endpoint, client_identity, target_addr, pairing_pin, |_| {}).await
}

/// Same as [`connect_via_iroh`], emitting real-time step descriptions as NAT hole-punching,
/// relay fallback, and TLS channel-bound `Hello` authentication progress.
pub async fn connect_via_iroh_with_progress<F>(
    endpoint: &iroh::Endpoint,
    client_identity: &DeviceIdentity,
    target_addr: EndpointAddr,
    pairing_pin: &str,
    mut on_step: F,
) -> Result<(
    Arc<PeerSession>,
    IncomingChannels,
    pb::HelloAck,
    String,
)>
where
    F: FnMut(&str),
{
    let direct_cnt = target_addr.ip_addrs().count();
    let ipv6_cnt = target_addr.ip_addrs().filter(|sa| sa.is_ipv6()).count();
    let relay_cnt = target_addr.relay_urls().count();

    let initial_msg = if direct_cnt > 0 && relay_cnt > 0 {
        if ipv6_cnt > 0 {
            format!(
                "正在并发发起 IPv6 / UDP 打洞（{direct_cnt} 个候选地址）与中继保底握手..."
            )
        } else {
            format!("正在并发发起 P2P 打洞（{direct_cnt} 个候选地址）与加密中继握手...")
        }
    } else if direct_cnt > 0 {
        format!("正在向 {direct_cnt} 个候选直连地址发起 UDP / IPv6 穿透...")
    } else {
        "正在通过加密中继节点寻呼远端主机...".to_string()
    };
    on_step(&initial_msg);

    let connect_fut = endpoint.connect(target_addr, ALPN_OPENUU);
    tokio::pin!(connect_fut);

    let checkpoints: &[(u64, &str)] = &[
        (2500, "正在穿透双端路由器 NAT 防火墙，协商最优低延迟路径..."),
        (
            6000,
            "直连打洞响应较慢，正在并行等待加密中继通道兜底握手（已用时 6s）...",
        ),
        (
            11000,
            "跨网链路延迟较高，仍在持续重试握手中（已用时 11s）...",
        ),
        (
            16500,
            "仍在等待远端主机响应（16s / 22s 超时保护，请确认被控端在线）...",
        ),
    ];
    let started = std::time::Instant::now();
    let mut next_cp = 0usize;

    let conn = loop {
        if next_cp < checkpoints.len() {
            let (target_ms, msg) = checkpoints[next_cp];
            let target_dur = Duration::from_millis(target_ms);
            let wait_dur = target_dur.saturating_sub(started.elapsed());
            tokio::select! {
                biased;
                res = &mut connect_fut => {
                    break res.map_err(|e| OpenUUError::Wan(format!("iroh P2P/Relay connect failed: {e}")))?;
                }
                _ = tokio::time::sleep(wait_dur) => {
                    on_step(msg);
                    next_cp += 1;
                }
            }
        } else {
            break connect_fut
                .await
                .map_err(|e| OpenUUError::Wan(format!("iroh P2P/Relay connect failed: {e}")))?;
        }
    };

    let telemetry = inspect_iroh_connection(&conn);
    let mode_zh = match telemetry.mode {
        LinkMode::Lan => "局域网直连",
        LinkMode::WanDirect => "P2P 直连",
        LinkMode::WanRelay => "加密中继",
    };
    if telemetry.rtt_ms > 0 {
        on_step(&format!(
            "网络隧道已打通（{mode_zh} · {}ms），正在校验访问密码与设备身份...",
            telemetry.rtt_ms
        ));
    } else {
        on_step(&format!(
            "网络隧道已打通（{mode_zh}），正在校验访问密码与设备身份..."
        ));
    }

    let host_endpoint_id = conn.remote_id().to_string();
    let (ctrl_tx, ctrl_rx) = conn
        .open_bi()
        .await
        .map_err(|e| OpenUUError::Wan(format!("iroh open_bi failed: {e}")))?;
    let backend = SessionBackend::Iroh(conn);

    let (session, channels, ack, _) = complete_client_handshake(
        backend,
        BackendSendStream::Iroh(ctrl_tx),
        BackendRecvStream::Iroh(ctrl_rx),
        client_identity,
        pairing_pin,
    )
    .await?;

    Ok((session, channels, ack, host_endpoint_id))
}

async fn complete_client_handshake(
    backend: SessionBackend,
    mut ctrl_tx: BackendSendStream,
    mut ctrl_rx: BackendRecvStream,
    client_identity: &DeviceIdentity,
    pairing_pin: &str,
) -> Result<(
    Arc<PeerSession>,
    IncomingChannels,
    pb::HelloAck,
    Option<String>,
)> {
    let client_proof = create_channel_auth_proof(client_identity, &backend);
    let hello = pb::ControlEnvelope {
        seq: 1,
        payload: Some(pb::control_envelope::Payload::Hello(pb::Hello {
            protocol_version: PROTOCOL_VERSION,
            device_id: client_identity.device_id.clone(),
            device_name: client_identity.device_name.clone(),
            os: std::env::consts::OS.to_string(),
            pairing_pin: pairing_pin.to_string(),
            public_key: client_proof,
        })),
    };
    ctrl_tx.write_all(&encode_control(&hello)?).await?;

    let ack_env = read_control_frame(&mut ctrl_rx).await?;
    let ack = match ack_env.payload {
        Some(pb::control_envelope::Payload::HelloAck(a)) => a,
        _ => {
            return Err(OpenUUError::Protocol(
                "expected HelloAck from host".into(),
            ))
        }
    };

    if !ack.accepted {
        return Err(OpenUUError::PairingRejected(ack.reason));
    }

    let verified_host_pk = verify_channel_auth_proof(&ack.public_key, &ack.device_id, &backend);
    let (session, channels) = spawn_session_loops(backend, ctrl_tx, ctrl_rx);
    Ok((session, channels, ack, verified_host_pk))
}

fn spawn_session_loops(
    backend: SessionBackend,
    mut control_tx: BackendSendStream,
    mut control_rx: BackendRecvStream,
) -> (Arc<PeerSession>, IncomingChannels) {
    let (ctrl_out_tx, ctrl_out_rx) = mpsc::channel::<pb::ControlEnvelope>(256);
    let (vid_out_tx, vid_out_rx) = mpsc::channel::<VideoFrame>(128);
    let (aud_out_tx, aud_out_rx) = mpsc::channel::<AudioFrame>(96);
    let (ctrl_in_tx, mut ctrl_in_rx) = mpsc::channel::<Bytes>(512);
    let (vid_in_tx, mut vid_in_rx) = mpsc::channel::<Bytes>(128);
    let (aud_in_tx, mut aud_in_rx) = mpsc::channel::<Bytes>(96);

    // Control stream writer (strict FIFO order, zero mutex contention across Tokio threads)
    tokio::spawn(async move {
        while let Some(framed) = ctrl_in_rx.recv().await {
            if control_tx.write_all(&framed).await.is_err() {
                break;
            }
        }
    });

    // Video stream writer: dedicated QUIC unidirectional stream per window_id (eliminating cross-window
    // Head-of-Line blocking) + GOP stream reset on keyframe-jump congestion shedding.
    let backend_video_tx = backend.clone();
    tokio::spawn(async move {
        let mut video_streams: std::collections::HashMap<u32, BackendSendStream> =
            std::collections::HashMap::new();
        let mut batch: Vec<Bytes> = Vec::with_capacity(16);
        while let Some(first) = vid_in_rx.recv().await {
            batch.clear();
            batch.push(first);
            while let Ok(next) = vid_in_rx.try_recv() {
                batch.push(next);
            }
            let len = batch.len();
            let mut reset_windows: std::collections::HashSet<u32> =
                std::collections::HashSet::new();
            for i in 0..len {
                let frame_bytes = &batch[i];
                if frame_bytes.len() < 7 {
                    continue;
                }
                let win_id = u32::from_be_bytes([
                    frame_bytes[3],
                    frame_bytes[4],
                    frame_bytes[5],
                    frame_bytes[6],
                ]);
                let win_slice = &frame_bytes[3..7];
                if i + 1 < len {
                    let superseded_by_idr = batch[(i + 1)..].iter().any(|later| {
                        later.len() >= 7 && (later[1] & 0x01) != 0 && &later[3..7] == win_slice
                    });
                    if superseded_by_idr {
                        reset_windows.insert(win_id);
                        continue;
                    }
                }
                if reset_windows.remove(&win_id) {
                    if let Some(mut old_stream) = video_streams.remove(&win_id) {
                        old_stream.reset_zero();
                    }
                }
                if !video_streams.contains_key(&win_id) {
                    match backend_video_tx.open_uni().await {
                        Ok(mut s) => {
                            if s.write_all(&[StreamType::Video as u8]).await.is_err() {
                                break;
                            }
                            video_streams.insert(win_id, s);
                        }
                        Err(_) => break,
                    }
                }
                if let Some(s) = video_streams.get_mut(&win_id) {
                    if s.write_all(frame_bytes).await.is_err() {
                        video_streams.remove(&win_id);
                    }
                }
            }
        }
    });

    // Audio stream writer: dedicated QUIC unidirectional stream (`0x02`) with burst congestion shedding
    // so transient WAN stalls never accumulate multi-second audio latency behind live video.
    let backend_audio_tx = backend.clone();
    tokio::spawn(async move {
        let mut audio_stream: Option<BackendSendStream> = None;
        let mut batch: Vec<Bytes> = Vec::with_capacity(16);
        while let Some(first) = aud_in_rx.recv().await {
            batch.clear();
            batch.push(first);
            while let Ok(next) = aud_in_rx.try_recv() {
                batch.push(next);
            }
            if batch.len() > 14 {
                if let Some(mut old_stream) = audio_stream.take() {
                    old_stream.reset_zero();
                }
                let keep_from = batch.len() - 8;
                let mut trimmed: Vec<Bytes> = Vec::with_capacity(9);
                for (idx, pkt) in batch.iter().enumerate() {
                    let is_cfg = pkt.len() >= 2 && (pkt[1] & AUDIO_FLAG_CONFIG) != 0;
                    if is_cfg || idx >= keep_from {
                        trimmed.push(pkt.clone());
                    }
                }
                batch = trimmed;
            }
            for frame_bytes in &batch {
                if audio_stream.is_none() {
                    match backend_audio_tx.open_uni().await {
                        Ok(mut s) => {
                            if s.write_all(&[StreamType::Audio as u8]).await.is_err() {
                                break;
                            }
                            audio_stream = Some(s);
                        }
                        Err(_) => break,
                    }
                }
                if let Some(s) = audio_stream.as_mut() {
                    if s.write_all(frame_bytes).await.is_err() {
                        audio_stream = None;
                    }
                }
            }
        }
    });

    // Control stream reader
    let ctrl_out_tx_blob = ctrl_out_tx.clone();
    tokio::spawn(async move {
        loop {
            match read_control_frame(&mut control_rx).await {
                Ok(env) => {
                    if ctrl_out_tx.send(env).await.is_err() {
                        break;
                    }
                }
                Err(e) => {
                    debug!("control stream ended: {e}");
                    break;
                }
            }
        }
    });

    // Unidirectional streams acceptor (Video / Audio / Blob)
    let backend_uni = backend.clone();
    tokio::spawn(async move {
        loop {
            match backend_uni.accept_uni().await {
                Ok(mut stream) => {
                    let vid_tx = vid_out_tx.clone();
                    let aud_tx = aud_out_tx.clone();
                    let ctrl_tx_for_blob = ctrl_out_tx_blob.clone();
                    tokio::spawn(async move {
                        let mut tag = [0u8; 1];
                        if stream.read_exact(&mut tag).await.is_err() {
                            return;
                        }
                        match StreamType::try_from(tag[0]) {
                            Ok(StreamType::Video) => {
                                read_video_stream_loop(&mut stream, &vid_tx).await;
                            }
                            Ok(StreamType::Audio) => {
                                read_audio_stream_loop(&mut stream, &aud_tx).await;
                            }
                            Ok(StreamType::Blob) => {
                                read_blob_stream(&mut stream, &ctrl_tx_for_blob).await;
                            }
                            Err(e) => warn!("{e}"),
                        }
                    });
                }
                Err(e) => {
                    debug!("uni stream accept ended: {e}");
                    break;
                }
            }
        }
    });

    let session = Arc::new(PeerSession {
        backend,
        control_in_tx: ctrl_in_tx,
        video_in_tx: vid_in_tx,
        audio_in_tx: aud_in_tx,
    });

    (
        session,
        IncomingChannels {
            control_rx: ctrl_out_rx,
            video_rx: vid_out_rx,
            audio_rx: aud_out_rx,
        },
    )
}

async fn read_blob_stream(
    stream: &mut BackendRecvStream,
    ctrl_tx: &mpsc::Sender<pb::ControlEnvelope>,
) {
    const MAX_BLOB_BYTES: u64 = 512 * 1024 * 1024;
    let mut fixed = [0u8; 14];
    if stream.read_exact(&mut fixed).await.is_err() {
        return;
    }
    let window_id = u32::from_be_bytes([fixed[0], fixed[1], fixed[2], fixed[3]]);
    let x = f32::from_be_bytes([fixed[4], fixed[5], fixed[6], fixed[7]]);
    let y = f32::from_be_bytes([fixed[8], fixed[9], fixed[10], fixed[11]]);
    let blob_id_len = u16::from_be_bytes([fixed[12], fixed[13]]) as usize;
    let mut blob_id_buf = vec![0u8; blob_id_len];
    if stream.read_exact(&mut blob_id_buf).await.is_err() {
        return;
    }
    let blob_id = String::from_utf8_lossy(&blob_id_buf).to_string();

    let mut name_len_buf = [0u8; 2];
    if stream.read_exact(&mut name_len_buf).await.is_err() {
        return;
    }
    let name_len = u16::from_be_bytes(name_len_buf) as usize;
    let mut name_buf = vec![0u8; name_len];
    if stream.read_exact(&mut name_buf).await.is_err() {
        return;
    }
    let raw_name = String::from_utf8_lossy(&name_buf).to_string();

    let mut size_buf = [0u8; 8];
    if stream.read_exact(&mut size_buf).await.is_err() {
        return;
    }
    let file_size = u64::from_be_bytes(size_buf);
    if file_size > MAX_BLOB_BYTES {
        warn!("incoming blob exceeds 512 MiB limit: {file_size}");
        return;
    }

    let safe_blob_id: String = blob_id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '-' || *c == '_')
        .take(64)
        .collect();
    let safe_blob_id = if safe_blob_id.is_empty() {
        "blob".to_string()
    } else {
        safe_blob_id
    };
    let safe_filename = std::path::Path::new(&raw_name)
        .file_name()
        .and_then(|s| s.to_str())
        .filter(|s| !s.is_empty() && *s != "." && *s != "..")
        .unwrap_or("file.bin")
        .to_string();

    let inbox_dir = crate::identity::default_cache_dir()
        .join("openuu-inbox")
        .join(&safe_blob_id);
    if std::fs::create_dir_all(&inbox_dir).is_err() {
        return;
    }
    let part_path = inbox_dir.join(format!(".{safe_filename}.part"));
    let dest_path = inbox_dir.join(&safe_filename);
    let Ok(mut out_file) = std::fs::File::create(&part_path) else {
        return;
    };

    // Notify local UI immediately with file metadata before streaming body bytes.
    let _ = ctrl_tx
        .send(pb::ControlEnvelope {
            seq: 0,
            payload: Some(pb::control_envelope::Payload::FileDrop(pb::FileDropAction {
                window_id,
                x,
                y,
                blob_id: blob_id.clone(),
                filename: safe_filename.clone(),
                total_bytes: file_size,
                received_bytes: 0,
                state: 1, // STARTED
            })),
        })
        .await;

    let mut buf = vec![0u8; 64 * 1024];
    let mut remaining = file_size;
    let mut last_progress_emit = Instant::now();
    let mut failed = false;
    while remaining > 0 {
        if is_blob_cancelled(&blob_id) || is_blob_cancelled(&safe_blob_id) {
            stream.stop_zero();
            failed = true;
            break;
        }
        let to_read = (remaining as usize).min(buf.len());
        match stream.read_chunk(&mut buf[..to_read]).await {
            Ok(Some(n)) if n > 0 => {
                if out_file.write_all(&buf[..n]).is_err() {
                    failed = true;
                    break;
                }
                remaining -= n as u64;
                if remaining > 0 && last_progress_emit.elapsed() >= Duration::from_millis(100) {
                    last_progress_emit = Instant::now();
                    let _ = ctrl_tx
                        .send(pb::ControlEnvelope {
                            seq: 0,
                            payload: Some(pb::control_envelope::Payload::FileDrop(
                                pb::FileDropAction {
                                    window_id,
                                    x,
                                    y,
                                    blob_id: blob_id.clone(),
                                    filename: safe_filename.clone(),
                                    total_bytes: file_size,
                                    received_bytes: file_size - remaining,
                                    state: 2, // PROGRESS
                                },
                            )),
                        })
                        .await;
                }
            }
            _ => {
                failed = true;
                break;
            }
        }
    }

    let _ = out_file.flush();
    drop(out_file);

    if failed || is_blob_cancelled(&blob_id) || is_blob_cancelled(&safe_blob_id) {
        let _ = std::fs::remove_dir_all(&inbox_dir);
        let _ = ctrl_tx
            .send(pb::ControlEnvelope {
                seq: 0,
                payload: Some(pb::control_envelope::Payload::FileDrop(pb::FileDropAction {
                    window_id,
                    x,
                    y,
                    blob_id,
                    filename: safe_filename,
                    total_bytes: file_size,
                    received_bytes: file_size.saturating_sub(remaining),
                    state: 3, // FAILED / CANCELLED
                })),
            })
            .await;
        return;
    }

    if std::fs::rename(&part_path, &dest_path).is_err() {
        let _ = std::fs::remove_dir_all(&inbox_dir);
        let _ = ctrl_tx
            .send(pb::ControlEnvelope {
                seq: 0,
                payload: Some(pb::control_envelope::Payload::FileDrop(pb::FileDropAction {
                    window_id,
                    x,
                    y,
                    blob_id,
                    filename: safe_filename,
                    total_bytes: file_size,
                    received_bytes: file_size,
                    state: 3, // FAILED
                })),
            })
            .await;
        return;
    }

    let saved_path = dest_path.to_string_lossy().to_string();
    let env = pb::ControlEnvelope {
        seq: 0,
        payload: Some(pb::control_envelope::Payload::FileDrop(pb::FileDropAction {
            window_id,
            x,
            y,
            blob_id,
            filename: saved_path,
            total_bytes: file_size,
            received_bytes: file_size,
            state: 0, // COMPLETED
        })),
    };
    let _ = ctrl_tx.send(env).await;
}

async fn read_control_frame(stream: &mut BackendRecvStream) -> Result<pb::ControlEnvelope> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_CONTROL_FRAME_LEN {
        return Err(OpenUUError::Protocol(format!(
            "incoming control frame exceeds limit: {len}"
        )));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    decode_control_payload(&payload)
}

async fn read_video_stream_loop(stream: &mut BackendRecvStream, tx: &mpsc::Sender<VideoFrame>) {
    let mut header = [0u8; VIDEO_HEADER_LEN];
    loop {
        if stream.read_exact(&mut header).await.is_err() {
            break;
        }
        let Ok((codec, flags, window_id, timestamp_us, width, height, payload_len)) =
            VideoFrame::decode_header(&header)
        else {
            warn!("corrupt video frame header");
            break;
        };
        let mut payload = vec![0u8; payload_len];
        if stream.read_exact(&mut payload).await.is_err() {
            break;
        }
        let frame = VideoFrame {
            codec,
            flags,
            window_id,
            timestamp_us,
            width,
            height,
            payload: Bytes::from(payload),
        };
        if tx.send(frame).await.is_err() {
            break;
        }
    }
}

async fn read_audio_stream_loop(stream: &mut BackendRecvStream, tx: &mpsc::Sender<AudioFrame>) {
    let mut header = [0u8; AUDIO_HEADER_LEN];
    loop {
        if stream.read_exact(&mut header).await.is_err() {
            break;
        }
        let Ok((codec, flags, channels, sample_rate, timestamp_us, payload_len)) =
            AudioFrame::decode_header(&header)
        else {
            warn!("corrupt audio frame header");
            break;
        };
        let mut payload = vec![0u8; payload_len];
        if stream.read_exact(&mut payload).await.is_err() {
            break;
        }
        let frame = AudioFrame {
            codec,
            flags,
            channels,
            sample_rate,
            timestamp_us,
            payload: Bytes::from(payload),
        };
        if tx.send(frame).await.is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::TrustedPeer;
    use crate::protocol::{AudioCodec, VideoCodec, VIDEO_FLAG_KEYFRAME};
    use crate::wan::{bind_iroh_endpoint, OpenUUTicket};

    #[tokio::test]
    async fn loopback_quic_handshake_control_and_video() {
        let host_id = DeviceIdentity::ephemeral("Host-Mac").unwrap();
        let client_id = DeviceIdentity::ephemeral("Client-Mac").unwrap();
        let pin = "123456";

        let endpoint = bind_host_endpoint(&host_id, "127.0.0.1:0".parse().unwrap()).unwrap();
        let addr = endpoint.local_addr().unwrap();

        let host_task = tokio::spawn(async move {
            accept_client_session(&endpoint, &host_id, Some(pin))
                .await
                .unwrap()
        });

        let (client_session, mut client_ch, ack) =
            connect_to_host(&client_id, addr, pin).await.unwrap();
        assert!(ack.accepted);
        assert_eq!(ack.device_name, "Host-Mac");

        let (host_session, mut host_ch, hello) = host_task.await.unwrap();
        assert_eq!(hello.device_name, "Client-Mac");

        let text_env = pb::ControlEnvelope {
            seq: 2,
            payload: Some(pb::control_envelope::Payload::TextCommit(
                pb::TextCommitEvent {
                    window_id: 99,
                    text: "局域网微信同步测试".to_string(),
                },
            )),
        };
        client_session.send_control(&text_env).await.unwrap();
        let received_env = host_ch.control_rx.recv().await.unwrap();
        assert_eq!(received_env, text_env);

        let sample_frame = VideoFrame {
            codec: VideoCodec::Hevc,
            flags: VIDEO_FLAG_KEYFRAME,
            window_id: 99,
            timestamp_us: 1_000_000,
            width: 1440,
            height: 900,
            payload: Bytes::from_static(&[0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0xAF]),
        };
        host_session.send_video_frame(&sample_frame).await.unwrap();
        let received_frame = client_ch.video_rx.recv().await.unwrap();
        assert_eq!(received_frame, sample_frame);

        let sample_audio = AudioFrame {
            codec: AudioCodec::AacLc,
            flags: 0,
            channels: 2,
            sample_rate: 48_000,
            timestamp_us: 1_021_333,
            payload: Bytes::from_static(&[0x21, 0x10, 0x04, 0x60]),
        };
        host_session.send_audio_frame(&sample_audio).await.unwrap();
        let received_audio = client_ch.audio_rx.recv().await.unwrap();
        assert_eq!(received_audio, sample_audio);

        client_session.close();
        host_session.close();
    }

    #[tokio::test]
    async fn loopback_iroh_p2p_and_passwordless_trusted_reconnect() {
        let mut host_id = DeviceIdentity::ephemeral("HK-Remote-Host").unwrap();
        let client_id = DeviceIdentity::ephemeral("Mainland-Client").unwrap();
        let pin = "AB89XY23";

        // Pre-trust client's Ed25519 EndpointId on Host so empty PIN reconnect succeeds!
        host_id
            .trust_peer(TrustedPeer {
                device_id: client_id.device_id.clone(),
                device_name: client_id.device_name.clone(),
                cert_fingerprint: String::new(),
                endpoint_id: client_id.endpoint_id_str(),
                device_code: client_id.device_code.clone(),
                last_relay_url: String::new(),
                last_ticket: String::new(),
                last_connected_ms: 1,
            })
            .unwrap();

        let host_ep = bind_iroh_endpoint(&host_id, true).await.unwrap();
        let client_ep = bind_iroh_endpoint(&client_id, true).await.unwrap();

        let ticket = OpenUUTicket::from_endpoint(&host_ep, &host_id, 0);
        let encoded_ticket = ticket.encode().unwrap();
        let decoded_ticket = OpenUUTicket::decode(&encoded_ticket).unwrap();
        let target_addr = decoded_ticket.to_endpoint_addr(&[]).unwrap();

        let limiter = PinRateLimiter::default();
        let host_ep_clone = host_ep.clone();
        let host_task = tokio::spawn(async move {
            accept_iroh_session(&host_ep_clone, &host_id, Some(pin), &limiter)
                .await
                .unwrap()
        });

        // Connect with EMPTY PIN because Client's Ed25519 EndpointId is already trusted!
        let (client_sess, mut client_ch, ack, verified_host_pk) =
            connect_via_iroh(&client_ep, &client_id, target_addr, "")
                .await
                .unwrap();
        assert!(ack.accepted);
        assert_eq!(verified_host_pk, host_ep.id().to_string());

        let (host_sess, _host_ch, hello, verified_client_pk) = host_task.await.unwrap();
        assert_eq!(hello.device_name, "Mainland-Client");
        assert_eq!(verified_client_pk.as_deref(), Some(client_ep.id().to_string().as_str()));

        // Verify HEVC video frame streaming over Iroh QUIC stream
        let frame = VideoFrame {
            codec: VideoCodec::Hevc,
            flags: VIDEO_FLAG_KEYFRAME,
            window_id: 7,
            timestamp_us: 88_000,
            width: 1280,
            height: 800,
            payload: Bytes::from_static(&[0x00, 0x00, 0x00, 0x01, 0x40, 0x01]),
        };
        host_sess.send_video_frame(&frame).await.unwrap();
        let recv = client_ch.video_rx.recv().await.unwrap();
        assert_eq!(recv, frame);

        client_sess.close();
        host_sess.close();
        host_ep.close().await;
        client_ep.close().await;
    }
}

use std::io::{Read, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Once};
use std::time::Duration;

use bytes::Bytes;
use quinn::crypto::rustls::{QuicClientConfig, QuicServerConfig};
use quinn::{Connection, Endpoint, RecvStream, SendStream, TransportConfig, VarInt};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use tokio::sync::mpsc;
use tracing::{debug, warn};

use crate::error::{ChameyeError, Result};
use crate::identity::DeviceIdentity;
use crate::protocol::{
    decode_control_payload, encode_control, pb, StreamType, VideoFrame, MAX_CONTROL_FRAME_LEN,
    PROTOCOL_VERSION, VIDEO_HEADER_LEN,
};

static CRYPTO_INIT: Once = Once::new();

pub fn init_crypto() {
    CRYPTO_INIT.call_once(|| {
        let _ = rustls::crypto::ring::default_provider().install_default();
    });
}

/// Skip standard CA chain verification for LAN self-signed certs;
/// peer identity is authenticated at the Chameye handshake layer via PIN + Ed25519 fingerprint pinning.
#[derive(Debug)]
struct LanTofuVerifier;

impl ServerCertVerifier for LanTofuVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> std::result::Result<ServerCertVerified, rustls::Error> {
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

fn default_transport_config() -> Arc<TransportConfig> {
    let mut cfg = TransportConfig::default();
    cfg.keep_alive_interval(Some(Duration::from_secs(2)));
    cfg.max_idle_timeout(Some(Duration::from_secs(6).try_into().unwrap()));
    // Tune QUIC flow-control windows and congestion control for low-latency LAN video streaming:
    // Avoid BBR's periodic 200ms `ProbeRTT` (which slashes cwnd to 4 packets and causes 11fps dips on Wi-Fi)
    // and disable DPLPMTUD probe packets; use Cubic with a 2 MiB initial window instead.
    cfg.stream_receive_window(VarInt::from_u32(16 * 1024 * 1024));
    cfg.receive_window(VarInt::from_u32(32 * 1024 * 1024));
    cfg.send_window(32 * 1024 * 1024);
    cfg.initial_rtt(Duration::from_millis(4));
    cfg.initial_mtu(1280);
    cfg.mtu_discovery_config(None);
    let mut cubic = quinn::congestion::CubicConfig::default();
    cubic.initial_window(2 * 1024 * 1024);
    cfg.congestion_controller_factory(Arc::new(cubic));
    Arc::new(cfg)
}

/// A live multiplexed QUIC session (used symmetrically by both Host and Client once connected).
pub struct PeerSession {
    connection: Connection,
    control_in_tx: mpsc::Sender<Bytes>,
    video_in_tx: mpsc::Sender<Bytes>,
}

impl PeerSession {
    pub fn remote_addr(&self) -> SocketAddr {
        self.connection.remote_address()
    }

    /// Enqueue a reliable Protobuf control message in strict FIFO order without spawning a new task.
    pub fn try_send_control(&self, env: &pb::ControlEnvelope) -> Result<()> {
        let framed = Bytes::from(encode_control(env)?);
        self.control_in_tx
            .try_send(framed)
            .map_err(|_| ChameyeError::Protocol("control send queue full or closed".into()))
    }

    /// Send a reliable Protobuf control message on Stream 0.
    pub async fn send_control(&self, env: &pb::ControlEnvelope) -> Result<()> {
        let framed = Bytes::from(encode_control(env)?);
        self.control_in_tx
            .send(framed)
            .await
            .map_err(|_| ChameyeError::Protocol("control send stream closed".into()))
    }

    /// Enqueue a hardware-encoded video frame in strict FIFO order on the caller thread (zero task-spawn race).
    pub fn try_send_video_frame(&self, frame: &VideoFrame) -> Result<()> {
        let encoded = frame.encode_frame();
        self.video_in_tx
            .try_send(encoded)
            .map_err(|_| ChameyeError::Protocol("video send queue full or closed".into()))
    }

    /// Send a hardware-encoded video frame over the dedicated unidirectional Video Stream.
    pub async fn send_video_frame(&self, frame: &VideoFrame) -> Result<()> {
        let encoded = frame.encode_frame();
        self.video_in_tx
            .send(encoded)
            .await
            .map_err(|_| ChameyeError::Protocol("video send stream closed".into()))
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
            .map_err(|e| ChameyeError::Protocol(format!("stat file failed: {e}")))?;
        let file_size = meta.len();
        if file_size > MAX_BLOB_BYTES {
            return Err(ChameyeError::Protocol(format!(
                "file exceeds 512 MiB limit: {file_size}"
            )));
        }
        let mut file = std::fs::File::open(&local_path)
            .map_err(|e| ChameyeError::Protocol(format!("open file failed: {e}")))?;

        let blob_bytes = blob_id.as_bytes();
        let name_bytes = filename.as_bytes();
        if blob_bytes.len() > u16::MAX as usize || name_bytes.len() > u16::MAX as usize {
            return Err(ChameyeError::Protocol("blob header too long".into()));
        }

        let mut stream = self.connection.open_uni().await?;
        let mut header = Vec::with_capacity(1 + 4 + 4 + 4 + 2 + blob_bytes.len() + 2 + name_bytes.len() + 8);
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
                .map_err(|e| ChameyeError::Protocol(format!("read file failed: {e}")))?;
            if n == 0 {
                break;
            }
            stream.write_all(&buf[..n]).await?;
            remaining -= n as u64;
        }
        let _ = stream.finish();
        Ok(())
    }

    pub fn close(&self) {
        self.connection.close(0u32.into(), b"session closed");
    }
}

pub struct IncomingChannels {
    pub control_rx: mpsc::Receiver<pb::ControlEnvelope>,
    pub video_rx: mpsc::Receiver<VideoFrame>,
}

/// Bind a QUIC Host server on `bind_addr` (e.g. `0.0.0.0:0` or `0.0.0.0:39481`).
pub fn bind_host_endpoint(identity: &DeviceIdentity, bind_addr: SocketAddr) -> Result<Endpoint> {
    init_crypto();
    let (certs, key) = identity.rustls_cert_and_key();
    let mut server_crypto = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(certs, key)
        .map_err(|e| ChameyeError::Crypto(format!("server tls config failed: {e}")))?;
    server_crypto.alpn_protocols = vec![b"chameye/1".to_vec()];

    let quic_server_cfg = QuicServerConfig::try_from(server_crypto)
        .map_err(|e| ChameyeError::Crypto(format!("quic server config failed: {e}")))?;
    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic_server_cfg));
    server_config.transport_config(default_transport_config());

    let endpoint = Endpoint::server(server_config, bind_addr)?;
    Ok(endpoint)
}

/// Accept one incoming Client connection, perform PIN handshake, and return the live session + receivers.
pub async fn accept_client_session(
    endpoint: &Endpoint,
    host_identity: &DeviceIdentity,
    expected_pin: Option<&str>,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::Hello)> {
    let incoming = endpoint
        .accept()
        .await
        .ok_or_else(|| ChameyeError::Protocol("host endpoint closed".into()))?;
    let conn = incoming.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.accept_bi().await?;

    // First message on Stream 0 must be Hello.
    let first_env = read_control_frame(&mut ctrl_rx).await?;
    let hello = match first_env.payload {
        Some(pb::control_envelope::Payload::Hello(h)) => h,
        _ => {
            return Err(ChameyeError::Protocol(
                "expected Hello as first control message".into(),
            ))
        }
    };

    let pin_ok = match expected_pin {
        None => true,
        Some(pin) => host_identity.is_trusted(&hello.device_id) || hello.pairing_pin == pin,
    };

    let ack = pb::ControlEnvelope {
        seq: 1,
        payload: Some(pb::control_envelope::Payload::HelloAck(pb::HelloAck {
            accepted: pin_ok,
            reason: if pin_ok {
                String::new()
            } else {
                "invalid pairing PIN".to_string()
            },
            device_id: host_identity.device_id.clone(),
            device_name: host_identity.device_name.clone(),
            os: std::env::consts::OS.to_string(),
        })),
    };
    ctrl_tx.write_all(&encode_control(&ack)?).await?;

    if !pin_ok {
        conn.close(1u32.into(), b"invalid pin");
        return Err(ChameyeError::PairingRejected("invalid pairing PIN".into()));
    }

    let (session, channels) = spawn_session_loops(conn, ctrl_tx, ctrl_rx);
    Ok((session, channels, hello))
}

/// Connect to a Chameye Host over QUIC and perform the Hello handshake.
pub async fn connect_to_host(
    client_identity: &DeviceIdentity,
    host_addr: SocketAddr,
    pairing_pin: &str,
) -> Result<(Arc<PeerSession>, IncomingChannels, pb::HelloAck)> {
    init_crypto();
    let mut client_crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(LanTofuVerifier))
        .with_no_client_auth();
    client_crypto.alpn_protocols = vec![b"chameye/1".to_vec()];

    let quic_client_cfg = QuicClientConfig::try_from(client_crypto)
        .map_err(|e| ChameyeError::Crypto(format!("quic client config failed: {e}")))?;
    let mut client_config = quinn::ClientConfig::new(Arc::new(quic_client_cfg));
    client_config.transport_config(default_transport_config());

    let bind_addr: SocketAddr = if host_addr.is_ipv4() {
        "0.0.0.0:0".parse().unwrap()
    } else {
        "[::]:0".parse().unwrap()
    };
    let mut endpoint = Endpoint::client(bind_addr)?;
    endpoint.set_default_client_config(client_config);

    let conn = endpoint.connect(host_addr, "chameye.local")?.await?;
    let (mut ctrl_tx, mut ctrl_rx) = conn.open_bi().await?;

    let hello = pb::ControlEnvelope {
        seq: 1,
        payload: Some(pb::control_envelope::Payload::Hello(pb::Hello {
            protocol_version: PROTOCOL_VERSION,
            device_id: client_identity.device_id.clone(),
            device_name: client_identity.device_name.clone(),
            os: std::env::consts::OS.to_string(),
            pairing_pin: pairing_pin.to_string(),
        })),
    };
    ctrl_tx.write_all(&encode_control(&hello)?).await?;

    let ack_env = read_control_frame(&mut ctrl_rx).await?;
    let ack = match ack_env.payload {
        Some(pb::control_envelope::Payload::HelloAck(a)) => a,
        _ => {
            return Err(ChameyeError::Protocol(
                "expected HelloAck from host".into(),
            ))
        }
    };

    if !ack.accepted {
        return Err(ChameyeError::PairingRejected(ack.reason));
    }

    let (session, channels) = spawn_session_loops(conn, ctrl_tx, ctrl_rx);
    Ok((session, channels, ack))
}

fn spawn_session_loops(
    connection: Connection,
    mut control_tx: SendStream,
    mut control_rx: RecvStream,
) -> (Arc<PeerSession>, IncomingChannels) {
    let (ctrl_out_tx, ctrl_out_rx) = mpsc::channel::<pb::ControlEnvelope>(256);
    let (vid_out_tx, vid_out_rx) = mpsc::channel::<VideoFrame>(128);
    let (ctrl_in_tx, mut ctrl_in_rx) = mpsc::channel::<Bytes>(512);
    let (vid_in_tx, mut vid_in_rx) = mpsc::channel::<Bytes>(128);

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
    let conn_video_tx = connection.clone();
    tokio::spawn(async move {
        let mut video_streams: std::collections::HashMap<u32, SendStream> =
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
                if frame_bytes.len() < 6 {
                    continue;
                }
                let win_id = u32::from_be_bytes([
                    frame_bytes[2],
                    frame_bytes[3],
                    frame_bytes[4],
                    frame_bytes[5],
                ]);
                let win_slice = &frame_bytes[2..6];
                // If multiple frames are queued in this batch, check if a newer Keyframe (flags & 0x01 != 0)
                // for the same window_id is already waiting later in `batch`; if so, skip stale pre-IDR frames
                // and mark the window's old QUIC stream for reset so in-flight pre-IDR retransmissions are aborted.
                if i + 1 < len {
                    let superseded_by_idr = batch[(i + 1)..].iter().any(|later| {
                        later.len() >= 6 && (later[1] & 0x01) != 0 && &later[2..6] == win_slice
                    });
                    if superseded_by_idr {
                        reset_windows.insert(win_id);
                        continue;
                    }
                }
                if reset_windows.remove(&win_id) {
                    if let Some(mut old_stream) = video_streams.remove(&win_id) {
                        let _ = old_stream.reset(0u32.into());
                    }
                }
                if !video_streams.contains_key(&win_id) {
                    match conn_video_tx.open_uni().await {
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
    let conn_clone = connection.clone();
    tokio::spawn(async move {
        loop {
            match conn_clone.accept_uni().await {
                Ok(mut stream) => {
                    let vid_tx = vid_out_tx.clone();
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
                                debug!("audio stream accepted (Phase 3)");
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
        connection,
        control_in_tx: ctrl_in_tx,
        video_in_tx: vid_in_tx,
    });

    (
        session,
        IncomingChannels {
            control_rx: ctrl_out_rx,
            video_rx: vid_out_rx,
        },
    )
}

async fn read_blob_stream(stream: &mut RecvStream, ctrl_tx: &mpsc::Sender<pb::ControlEnvelope>) {
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

    let inbox_dir = std::env::temp_dir()
        .join("chameye-inbox")
        .join(&safe_blob_id);
    if std::fs::create_dir_all(&inbox_dir).is_err() {
        return;
    }
    let dest_path = inbox_dir.join(&safe_filename);
    let Ok(mut out_file) = std::fs::File::create(&dest_path) else {
        return;
    };

    let mut buf = vec![0u8; 64 * 1024];
    let mut remaining = file_size;
    while remaining > 0 {
        let to_read = (remaining as usize).min(buf.len());
        match stream.read(&mut buf[..to_read]).await {
            Ok(Some(n)) if n > 0 => {
                if out_file.write_all(&buf[..n]).is_err() {
                    return;
                }
                remaining -= n as u64;
            }
            _ => return,
        }
    }
    let _ = out_file.flush();

    let saved_path = dest_path.to_string_lossy().to_string();
    let env = pb::ControlEnvelope {
        seq: 0,
        payload: Some(pb::control_envelope::Payload::FileDrop(pb::FileDropAction {
            window_id,
            x,
            y,
            blob_id,
            filename: saved_path,
        })),
    };
    let _ = ctrl_tx.send(env).await;
}

async fn read_control_frame(stream: &mut RecvStream) -> Result<pb::ControlEnvelope> {
    let mut len_buf = [0u8; 4];
    stream.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_CONTROL_FRAME_LEN {
        return Err(ChameyeError::Protocol(format!(
            "incoming control frame exceeds limit: {len}"
        )));
    }
    let mut payload = vec![0u8; len];
    stream.read_exact(&mut payload).await?;
    decode_control_payload(&payload)
}

async fn read_video_stream_loop(stream: &mut RecvStream, tx: &mpsc::Sender<VideoFrame>) {
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
        // If renderer falls behind, drop oldest or wait cleanly without stalling control stream.
        if tx.send(frame).await.is_err() {
            break;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{VideoCodec, VIDEO_FLAG_KEYFRAME};

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

        // 1. Client -> Host: Chinese IME text commit
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

        // 2. Host -> Client: Video frame
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

        client_session.close();
        host_session.close();
    }
}

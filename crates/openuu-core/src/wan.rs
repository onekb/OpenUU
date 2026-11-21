use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use iroh::endpoint::{presets, QuicTransportConfig, VarInt};
use iroh::tls::CaTlsConfig;
use iroh::{Endpoint, EndpointAddr, PublicKey, RelayMap, RelayMode, RelayUrl, TransportAddr};
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{DigitallySignedStruct, SignatureScheme};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tracing::debug;

use crate::error::{OpenUUError, Result};
use crate::identity::{normalize_device_code, now_epoch_ms, DeviceIdentity};
use crate::transport::init_crypto;

pub const ALPN_OPENUU: &[u8] = b"openuu/1";
pub const TICKET_PREFIX: &str = "openuu://";
pub const UNIFIED_AUTH_OR_CODE_ERR: &str = "设备代码不存在或访问密码错误";
pub const RATE_LIMIT_ERR: &str = "尝试次数过多，请稍后再试";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LinkMode {
    Lan,
    WanDirect,
    WanRelay,
}

impl LinkMode {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Lan => "lan",
            Self::WanDirect => "wan_direct",
            Self::WanRelay => "wan_relay",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LinkTelemetry {
    pub mode: LinkMode,
    pub rtt_ms: u32,
    pub remote_addr: String,
}

/// Shareable / Coordinator-stored connection ticket bundling EndpointId, Relay URLs (HK + fallback),
/// and prioritized direct IP addresses (Global Unicast IPv6 -> Public IPv4 -> LAN IP).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenUUTicket {
    pub v: u32,
    pub endpoint_id: String,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub device_name: String,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub relay_urls: Vec<String>,
    #[serde(default)]
    pub direct_addrs: Vec<SocketAddr>,
    #[serde(default)]
    pub lan_quic_port: u16,
}

impl OpenUUTicket {
    pub fn from_endpoint(
        endpoint: &Endpoint,
        identity: &DeviceIdentity,
        lan_quic_port: u16,
    ) -> Self {
        let ep_addr = endpoint.addr();
        // Record ONLY the endpoint's actual active home relay(s) so clients never dial an
        // unregistered relay URL ahead of the Host's real home relay in `EndpointAddr`'s BTreeSet.
        let mut relay_urls: Vec<String> = ep_addr.relay_urls().map(|r| r.to_string()).collect();
        if relay_urls.is_empty() {
            relay_urls = parse_custom_relay_urls(&identity.wan_config.relay_url)
                .into_iter()
                .map(|u| u.to_string())
                .collect();
        }

        let mut direct_addrs: Vec<SocketAddr> = ep_addr
            .ip_addrs()
            .copied()
            .filter(|sa| !is_unusable_direct_ip(sa.ip()))
            .collect();
        // Drop loopback if any non-loopback address exists (keep loopback for pure-local unit tests)
        if direct_addrs.iter().any(|sa| !sa.ip().is_loopback()) {
            direct_addrs.retain(|sa| !sa.ip().is_loopback());
        }
        // Prioritize Global Unicast IPv6 (China telecom/unicom/mobile native IPv6), then Public IPv4, then LAN IPs!
        direct_addrs.sort_by_key(|sa| addr_priority(sa.ip()));

        Self {
            v: 1,
            endpoint_id: endpoint.id().to_string(),
            device_id: identity.device_id.clone(),
            device_name: identity.device_name.clone(),
            device_code: identity.device_code.clone(),
            relay_urls,
            direct_addrs,
            lan_quic_port,
        }
    }

    pub fn encode(&self) -> Result<String> {
        let json = serde_json::to_vec(self)
            .map_err(|e| OpenUUError::Wan(format!("ticket serialize failed: {e}")))?;
        Ok(format!("{TICKET_PREFIX}{}", URL_SAFE_NO_PAD.encode(json)))
    }

    pub fn decode(raw: &str) -> Result<Self> {
        let trimmed = raw.trim();
        let body = trimmed
            .strip_prefix(TICKET_PREFIX)
            .unwrap_or(trimmed)
            .trim();
        let bytes = URL_SAFE_NO_PAD
            .decode(body)
            .map_err(|e| OpenUUError::Wan(format!("invalid ticket base64: {e}")))?;
        serde_json::from_slice(&bytes)
            .map_err(|e| OpenUUError::Wan(format!("invalid ticket payload: {e}")))
    }

    pub fn to_endpoint_addr(&self, extra_relays: &[RelayUrl]) -> Result<EndpointAddr> {
        let pk = PublicKey::from_str(&self.endpoint_id)
            .map_err(|e| OpenUUError::Wan(format!("invalid endpoint_id in ticket: {e}")))?;
        let mut addrs: Vec<TransportAddr> = Vec::new();
        for r_str in &self.relay_urls {
            if let Ok(url) = RelayUrl::from_str(r_str) {
                let t = TransportAddr::Relay(url);
                if !addrs.contains(&t) {
                    addrs.push(t);
                }
            }
        }
        // Only fall back to client-side `extra_relays` if the ticket carried no active home relay.
        if addrs.is_empty() {
            for extra in extra_relays {
                let t = TransportAddr::Relay(extra.clone());
                if !addrs.contains(&t) {
                    addrs.push(t);
                }
            }
        }
        for sa in &self.direct_addrs {
            if !is_unusable_direct_ip(sa.ip()) {
                addrs.push(TransportAddr::Ip(*sa));
            }
        }
        Ok(EndpointAddr::from_parts(pk, addrs))
    }
}

/// Returns true for non-routable / virtual TUN Fake-IP addresses that should never be advertised
/// or probed as direct P2P candidates (e.g. Clash/Mihomo/Surge `198.18.0.0/15`, link-local, unspecified).
pub fn is_unusable_direct_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_unspecified()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_multicast()
                || (o[0] == 198 && (o[1] == 18 || o[1] == 19)) // RFC 2544 / TUN Fake-IP (198.18.0.0/15)
        }
        IpAddr::V6(v6) => v6.is_unspecified() || v6.is_unicast_link_local() || v6.is_multicast(),
    }
}

/// Rank IP addresses for China / global connectivity:
/// 0 = Global Unicast IPv6 (fastest direct path across CGNAT ISPs in Mainland China)
/// 1 = Public Unicast IPv4
/// 2 = Private LAN IPv4 / ULA IPv6
/// 3 = Loopback / Link-local / Virtual TUN
fn addr_priority(ip: IpAddr) -> u8 {
    if is_unusable_direct_ip(ip) {
        return 3;
    }
    match ip {
        IpAddr::V6(v6) => {
            if v6.is_loopback() || v6.is_unicast_link_local() || v6.is_unspecified() {
                3
            } else if (v6.segments()[0] & 0xfe00) == 0xfc00 {
                // Unique Local IPv6 (fc00::/7)
                2
            } else {
                // Global Unicast IPv6 (e.g. 240e::/20, 2408::/20, 2409::/20)
                0
            }
        }
        IpAddr::V4(v4) => {
            if v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() {
                3
            } else if v4.is_private()
                || (v4.octets()[0] == 100 && (v4.octets()[1] & 0b1100_0000) == 64)
            {
                // RFC1918 or CGNAT/Tailscale 100.64.0.0/10
                2
            } else {
                1
            }
        }
    }
}

pub fn is_lan_or_private_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || (o[0] == 169 && o[1] == 254)
                || (o[0] == 198 && (o[1] == 18 || o[1] == 19))
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_lan_or_private_ip(IpAddr::V4(v4));
            }
            v6.is_loopback()
                || v6.is_unicast_link_local()
                || (v6.segments()[0] & 0xfe00) == 0xfc00
        }
    }
}

pub fn parse_custom_relay_urls(raw: &str) -> Vec<RelayUrl> {
    raw.split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|s| RelayUrl::from_str(s).ok())
        .collect()
}

/// Optional TLS verifier for self-hosted pure-IP relays using self-signed certs (`allow_insecure_tls = true`).
/// Note: End-to-end QUIC traffic inside the relay tunnel is STILL mutually authenticated by Ed25519 `EndpointId`!
#[derive(Debug)]
struct InsecureRelayTlsVerifier;

impl ServerCertVerifier for InsecureRelayTlsVerifier {
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

/// Concurrently probes custom `iroh-relay` URLs (`GET <relay>/ping`) with a short timeout,
/// returning those that respond with HTTP 2xx so Host endpoints can implement true cascading
/// fallback (prefer healthy custom/domestic relay first; only fall back to overseas `n0` if down).
pub async fn probe_reachable_relays(
    relays: &[RelayUrl],
    allow_insecure_tls: bool,
) -> Vec<RelayUrl> {
    if relays.is_empty() {
        return Vec::new();
    }
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_millis(3500))
        .connect_timeout(Duration::from_millis(2500))
        .danger_accept_invalid_certs(allow_insecure_tls)
        .build()
    else {
        return relays.to_vec();
    };

    let mut handles = Vec::with_capacity(relays.len());
    for url in relays {
        let client = client.clone();
        let relay_url = url.clone();
        handles.push(tokio::spawn(async move {
            let base = relay_url.to_string();
            let ping_url = format!("{}/ping", base.trim_end_matches('/'));
            match client.get(&ping_url).send().await {
                Ok(resp) if resp.status().is_success() => Some(relay_url),
                _ => None,
            }
        }));
    }

    let mut healthy = Vec::new();
    for h in handles {
        if let Ok(Some(u)) = h.await {
            healthy.push(u);
        }
    }
    healthy
}

/// Build a WAN-tuned `iroh::Endpoint` with cascading relay configuration:
/// 1. Direct IPv6 / IPv4 UDP hole-punching
/// 2. Self-hosted Hong Kong / Cloudflare-Tunnel `iroh-relay` (if configured)
/// 3. Public `n0` global relay fallback (when `enable_public_fallback` is true)
pub async fn bind_iroh_endpoint(
    identity: &DeviceIdentity,
    local_only_no_relay: bool,
) -> Result<Endpoint> {
    bind_iroh_endpoint_with_role(identity, local_only_no_relay, false).await
}

/// Build a WAN-tuned `iroh::Endpoint` with role-aware relay selection:
/// - When `prefer_custom_relay_first == true` (Host mode) and `custom_relays` are configured:
///   probes `custom_relays` first. If at least one custom relay is healthy, anchors the Host ONLY
///   on the healthy custom relay(s) so `iroh` never abandons the domestic-accessible relay for an
///   overseas `n0` node (which can be TLS-reset for mainland clients). Falls back to public `n0`
///   relays automatically if all custom relays are unreachable and `enable_public_fallback` is true.
/// - When `prefer_custom_relay_first == false` (Client mode):
///   attaches Bearer auth token to custom relay(s) and merges public `n0` relays (if enabled) so
///   the client can connect seamlessly to hosts on either custom relays or legacy `n0` relays,
///   while retaining QUIC Address Discovery for P2P hole-punching.
pub async fn bind_iroh_endpoint_with_role(
    identity: &DeviceIdentity,
    local_only_no_relay: bool,
    prefer_custom_relay_first: bool,
) -> Result<Endpoint> {
    init_crypto();

    let idle_timeout = Duration::from_secs(20)
        .try_into()
        .map_err(|e| OpenUUError::Wan(format!("idle timeout invalid: {e}")))?;

    let quic_cfg = QuicTransportConfig::builder()
        .initial_mtu(1200)
        .min_mtu(1200)
        .initial_rtt(Duration::from_millis(40))
        .keep_alive_interval(Duration::from_secs(4))
        .max_idle_timeout(Some(idle_timeout))
        .stream_receive_window(VarInt::from_u32(8 * 1024 * 1024))
        .receive_window(VarInt::from_u32(16 * 1024 * 1024))
        .send_window(16 * 1024 * 1024)
        .build();

    let custom_relays = parse_custom_relay_urls(&identity.wan_config.relay_url);
    let relay_token = identity.wan_config.relay_auth_token.trim();

    let mut builder = if local_only_no_relay {
        Endpoint::builder(presets::Minimal)
            .clear_address_lookup()
            .relay_mode(RelayMode::Disabled)
    } else if !custom_relays.is_empty() && !identity.wan_config.enable_public_fallback {
        // Strict private relay mode (e.g. Cloudflare Tunnel / Hong Kong self-hosted relay only, zero overseas n0 traffic)
        let mut custom_map = RelayMap::from_iter(custom_relays);
        if !relay_token.is_empty() {
            custom_map = custom_map.with_auth_token(relay_token);
        }
        Endpoint::builder(presets::Minimal)
            .clear_address_lookup()
            .relay_mode(RelayMode::Custom(custom_map))
    } else if !custom_relays.is_empty() && prefer_custom_relay_first {
        // True cascading fallback for Host: anchor on healthy custom relay(s) first;
        // only fall back to overseas public n0 relays when every custom relay is unreachable.
        let healthy =
            probe_reachable_relays(&custom_relays, identity.wan_config.allow_insecure_tls).await;
        if !healthy.is_empty() {
            let mut custom_map = RelayMap::from_iter(healthy);
            if !relay_token.is_empty() {
                custom_map = custom_map.with_auth_token(relay_token);
            }
            Endpoint::builder(presets::Minimal)
                .clear_address_lookup()
                .relay_mode(RelayMode::Custom(custom_map))
        } else {
            let mut b = Endpoint::builder(presets::N0);
            if !identity.wan_config.coord_url.trim().is_empty() {
                b = b.clear_address_lookup();
            }
            b
        }
    } else if !custom_relays.is_empty() {
        // Client mixed mode: attach Bearer token ONLY to custom private relay(s), then merge public n0 relay pool
        let mut relay_map = RelayMap::from_iter(custom_relays);
        if !relay_token.is_empty() {
            relay_map = relay_map.with_auth_token(relay_token);
        }
        relay_map.extend(&RelayMode::Default.relay_map());
        let mut b = Endpoint::builder(presets::N0).relay_mode(RelayMode::Custom(relay_map));
        // If custom coord server is configured, don't block on potentially poisoned overseas DNS publishing
        if !identity.wan_config.coord_url.trim().is_empty() {
            b = b.clear_address_lookup();
        }
        b
    } else {
        Endpoint::builder(presets::N0)
    };

    if identity.wan_config.allow_insecure_tls {
        builder = builder.ca_tls_config(CaTlsConfig::custom_server_cert_verifier(Arc::new(
            |_provider| Ok(Arc::new(InsecureRelayTlsVerifier)),
        )));
    }

    let endpoint = builder
        .secret_key(identity.iroh_secret.clone())
        .alpns(vec![ALPN_OPENUU.to_vec()])
        .transport_config(quic_cfg)
        .bind()
        .await
        .map_err(|e| OpenUUError::Wan(format!("iroh endpoint bind failed: {e}")))?;

    Ok(endpoint)
}

/// Inspects the currently selected network path on an active `iroh` connection.
pub fn inspect_iroh_connection(conn: &iroh::endpoint::Connection) -> LinkTelemetry {
    let paths = conn.paths();
    let selected = paths
        .iter()
        .find(|p| p.is_selected())
        .or_else(|| paths.iter().next());

    if let Some(p) = selected {
        let rtt_ms = p.rtt().as_millis().min(9999) as u32;
        let addr_str = format!("{:?}", p.remote_addr());
        if p.is_relay() {
            return LinkTelemetry {
                mode: LinkMode::WanRelay,
                rtt_ms,
                remote_addr: addr_str,
            };
        }
        if let TransportAddr::Ip(sa) = p.remote_addr() {
            let mode = if is_lan_or_private_ip(sa.ip()) {
                LinkMode::Lan
            } else {
                LinkMode::WanDirect
            };
            return LinkTelemetry {
                mode,
                rtt_ms,
                remote_addr: sa.to_string(),
            };
        }
        return LinkTelemetry {
            mode: LinkMode::WanDirect,
            rtt_ms,
            remote_addr: addr_str,
        };
    }

    LinkTelemetry {
        mode: LinkMode::WanRelay,
        rtt_ms: 0,
        remote_addr: conn.remote_id().to_string(),
    }
}

// ============================================================================
// Brute-force PIN / Password Rate Limiter
// ============================================================================

struct FailureWindow {
    failures: u32,
    first_failure_at: Instant,
    locked_until: Option<Instant>,
}

/// Protects WAN/LAN Host against brute-force PIN guessing:
/// - Max 5 failed attempts within 10 minutes per peer key/IP -> 10-minute lockout.
#[derive(Default, Clone)]
pub struct PinRateLimiter {
    entries: Arc<Mutex<HashMap<String, FailureWindow>>>,
}

impl PinRateLimiter {
    const MAX_FAILURES: u32 = 5;
    const WINDOW: Duration = Duration::from_secs(600);
    const LOCKOUT: Duration = Duration::from_secs(600);

    pub fn check_allowed(&self, source_key: &str) -> std::result::Result<(), u64> {
        let Ok(mut guard) = self.entries.lock() else {
            return Ok(());
        };
        let now = Instant::now();
        if let Some(entry) = guard.get_mut(source_key) {
            if let Some(until) = entry.locked_until {
                if now < until {
                    return Err((until - now).as_secs().max(1));
                }
                guard.remove(source_key);
            } else if now.duration_since(entry.first_failure_at) > Self::WINDOW {
                guard.remove(source_key);
            }
        }
        Ok(())
    }

    pub fn record_failure(&self, source_key: &str) -> (u32, Option<u64>) {
        let Ok(mut guard) = self.entries.lock() else {
            return (1, None);
        };
        let now = Instant::now();
        // Prune stale entries when map grows
        if guard.len() > 512 {
            guard.retain(|_, v| {
                v.locked_until.map(|u| now < u).unwrap_or(false)
                    || now.duration_since(v.first_failure_at) <= Self::WINDOW
            });
        }
        let entry = guard
            .entry(source_key.to_string())
            .or_insert(FailureWindow {
                failures: 0,
                first_failure_at: now,
                locked_until: None,
            });
        if now.duration_since(entry.first_failure_at) > Self::WINDOW {
            entry.failures = 0;
            entry.first_failure_at = now;
            entry.locked_until = None;
        }
        entry.failures += 1;
        if entry.failures >= Self::MAX_FAILURES {
            let until = now + Self::LOCKOUT;
            entry.locked_until = Some(until);
            (entry.failures, Some(Self::LOCKOUT.as_secs()))
        } else {
            (entry.failures, None)
        }
    }

    pub fn record_success(&self, source_key: &str) {
        if let Ok(mut guard) = self.entries.lock() {
            guard.remove(source_key);
        }
    }
}

// ============================================================================
// OpenUU Coordination Server Client (9-Digit Device Code Directory)
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoordRegisterReq {
    pub device_code: String,
    pub device_id: String,
    pub device_name: String,
    pub endpoint_id: String,
    pub pubkey_hex: String,
    #[serde(default)]
    pub pin_proof_hex: String,
    pub ticket: String,
    pub timestamp_ms: u64,
    pub signature_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoordRegisterResp {
    pub ok: bool,
    pub assigned_code: String,
    #[serde(default)]
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CoordResolveResp {
    pub found: bool,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub device_name: String,
    #[serde(default)]
    pub endpoint_id: String,
    #[serde(default)]
    pub ticket: String,
    #[serde(default)]
    pub updated_at_ms: u64,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub message: String,
}

/// Computes a salted zero-knowledge PIN proof `SHA-256("openuu-pin-proof-v1:{code}:{pin}")`
/// so the coordination server never sees the plaintext PIN and never reveals whether a 9-digit
/// code exists unless the caller also supplies the matching PIN proof.
pub fn compute_pin_proof_hex(device_code: &str, pin: &str) -> String {
    let norm = normalize_device_code(device_code);
    let clean_pin = pin.trim();
    if norm.len() != 9 || clean_pin.is_empty() {
        return String::new();
    }
    let mut hasher = Sha256::new();
    hasher.update(format!("openuu-pin-proof-v1:{norm}:{clean_pin}").as_bytes());
    hex::encode(hasher.finalize())
}

pub fn build_coord_signing_message(
    device_code: &str,
    endpoint_id: &str,
    ticket: &str,
    timestamp_ms: u64,
    pin_proof_hex: &str,
) -> Vec<u8> {
    if pin_proof_hex.is_empty() {
        format!("openuu-coord-v1:{device_code}:{endpoint_id}:{ticket}:{timestamp_ms}").into_bytes()
    } else {
        format!(
            "openuu-coord-v2:{device_code}:{endpoint_id}:{ticket}:{timestamp_ms}:{pin_proof_hex}"
        )
        .into_bytes()
    }
}

fn build_http_client(allow_insecure_tls: bool) -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(6))
        .connect_timeout(Duration::from_secs(4))
        .danger_accept_invalid_certs(allow_insecure_tls)
        .build()
        .map_err(|e| OpenUUError::Wan(format!("http client init failed: {e}")))
}

pub async fn coord_register_heartbeat(
    coord_url: &str,
    allow_insecure_tls: bool,
    identity: &DeviceIdentity,
    ticket: &str,
    host_pin: Option<&str>,
) -> Result<CoordRegisterResp> {
    let base = coord_url.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err(OpenUUError::Wan("coord_url is empty".into()));
    }
    let client = build_http_client(allow_insecure_tls)?;
    let ts = now_epoch_ms();
    let endpoint_id = identity.endpoint_id_str();
    let pubkey_hex = hex::encode(identity.iroh_secret.public().as_bytes());
    let pin_proof_hex = host_pin
        .map(|p| compute_pin_proof_hex(&identity.device_code, p))
        .unwrap_or_default();
    let msg = build_coord_signing_message(
        &identity.device_code,
        &endpoint_id,
        ticket,
        ts,
        &pin_proof_hex,
    );
    let signature_hex = identity.sign_hex(&msg);

    let req = CoordRegisterReq {
        device_code: identity.device_code.clone(),
        device_id: identity.device_id.clone(),
        device_name: identity.device_name.clone(),
        endpoint_id,
        pubkey_hex,
        pin_proof_hex,
        ticket: ticket.to_string(),
        timestamp_ms: ts,
        signature_hex,
    };

    let url = format!("{base}/v1/register");
    debug!("Registering device code {} with {url}", identity.device_code);
    let resp = client
        .post(&url)
        .json(&req)
        .send()
        .await
        .map_err(|e| OpenUUError::Wan(format!("coord register failed: {e}")))?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = resp.text().await.unwrap_or_default();
        return Err(OpenUUError::Wan(format!(
            "coord register HTTP {status}: {body}"
        )));
    }

    resp.json::<CoordRegisterResp>()
        .await
        .map_err(|e| OpenUUError::Wan(format!("coord register decode failed: {e}")))
}

pub async fn coord_resolve_code(
    coord_url: &str,
    allow_insecure_tls: bool,
    raw_code: &str,
    pin: &str,
) -> Result<CoordResolveResp> {
    let base = coord_url.trim().trim_end_matches('/');
    if base.is_empty() {
        return Err(OpenUUError::Wan("未配置设备码寻址服务器地址 (coord_url)".into()));
    }
    let code = normalize_device_code(raw_code);
    let pin_proof = compute_pin_proof_hex(&code, pin);
    if code.len() != 9 || pin_proof.is_empty() {
        return Err(OpenUUError::PairingRejected(
            UNIFIED_AUTH_OR_CODE_ERR.into(),
        ));
    }
    let client = build_http_client(allow_insecure_tls)?;
    let url = format!("{base}/v1/resolve/{code}");
    let resp = client
        .get(&url)
        .header("X-OpenUU-Pin-Proof", pin_proof)
        .send()
        .await
        .map_err(|e| OpenUUError::Wan(format!("查询寻址服务失败: {e}")))?;

    match resp.status().as_u16() {
        429 => return Err(OpenUUError::PairingRejected(RATE_LIMIT_ERR.into())),
        401 | 403 | 404 => {
            return Err(OpenUUError::PairingRejected(
                UNIFIED_AUTH_OR_CODE_ERR.into(),
            ))
        }
        s if !(200..300).contains(&s) => {
            return Err(OpenUUError::Wan(format!("寻址服务返回 HTTP {s}")))
        }
        _ => {}
    }

    let parsed = resp
        .json::<CoordResolveResp>()
        .await
        .map_err(|e| OpenUUError::Wan(format!("解析寻址响应失败: {e}")))?;
    if !parsed.found {
        return Err(OpenUUError::PairingRejected(
            UNIFIED_AUTH_OR_CODE_ERR.into(),
        ));
    }
    Ok(parsed)
}

/// Resolves an already-trusted peer by its 256-bit Ed25519 `endpoint_id` (64 hex chars -> 2^256 keyspace,
/// mathematically immune to brute-force enumeration) for passwordless reconnects.
pub async fn coord_resolve_endpoint(
    coord_url: &str,
    allow_insecure_tls: bool,
    endpoint_id: &str,
) -> Result<CoordResolveResp> {
    let base = coord_url.trim().trim_end_matches('/');
    let clean_ep = endpoint_id.trim().to_lowercase();
    if base.is_empty() || clean_ep.len() != 64 {
        return Err(OpenUUError::PairingRejected(
            UNIFIED_AUTH_OR_CODE_ERR.into(),
        ));
    }
    let client = build_http_client(allow_insecure_tls)?;
    let url = format!("{base}/v1/resolve-endpoint/{clean_ep}");
    let resp = client
        .get(&url)
        .send()
        .await
        .map_err(|e| OpenUUError::Wan(format!("查询寻址服务失败: {e}")))?;

    match resp.status().as_u16() {
        429 => return Err(OpenUUError::PairingRejected(RATE_LIMIT_ERR.into())),
        401 | 403 | 404 => {
            return Err(OpenUUError::PairingRejected(
                UNIFIED_AUTH_OR_CODE_ERR.into(),
            ))
        }
        s if !(200..300).contains(&s) => {
            return Err(OpenUUError::Wan(format!("寻址服务返回 HTTP {s}")))
        }
        _ => {}
    }
    resp.json::<CoordResolveResp>()
        .await
        .map_err(|e| OpenUUError::Wan(format!("解析寻址响应失败: {e}")))
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchProbeQueryItem {
    pub id: String,
    #[serde(default)]
    pub endpoint_id: String,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub pin_proof_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BatchProbeResultItem {
    pub id: String,
    #[serde(default)]
    pub found: bool,
    #[serde(default)]
    pub online: bool,
    #[serde(default)]
    pub device_name: String,
    #[serde(default)]
    pub device_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordResolveBatchReq {
    queries: Vec<BatchProbeQueryItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordResolveBatchResp {
    #[serde(default)]
    items: Vec<BatchProbeResultItem>,
}

/// Resolves up to 32 saved Device Book entries in a single anti-enumeration HTTP request (`/v1/resolve-batch`),
/// authenticating each item via either 256-bit `endpoint_id` (trusted peer) or salted `pin_proof_hex`.
pub async fn coord_resolve_batch(
    coord_url: &str,
    allow_insecure_tls: bool,
    queries: &[BatchProbeQueryItem],
) -> Result<HashMap<String, BatchProbeResultItem>> {
    let base = coord_url.trim().trim_end_matches('/');
    if base.is_empty() || queries.is_empty() {
        return Ok(HashMap::new());
    }
    let slice: Vec<BatchProbeQueryItem> = queries.iter().take(32).cloned().collect();
    let client = build_http_client(allow_insecure_tls)?;
    let url = format!("{base}/v1/resolve-batch");
    let resp = client
        .post(&url)
        .json(&CoordResolveBatchReq { queries: slice })
        .send()
        .await
        .map_err(|e| OpenUUError::Wan(format!("批量查询寻址服务失败: {e}")))?;

    if !resp.status().is_success() {
        return Ok(HashMap::new());
    }
    let parsed = resp
        .json::<CoordResolveBatchResp>()
        .await
        .map_err(|e| OpenUUError::Wan(format!("解析批量寻址响应失败: {e}")))?;

    let mut out = HashMap::with_capacity(parsed.items.len());
    for item in parsed.items {
        out.insert(item.id.clone(), item);
    }
    Ok(out)
}

impl Default for CoordResolveResp {
    fn default() -> Self {
        Self {
            found: false,
            device_code: String::new(),
            device_id: String::new(),
            device_name: String::new(),
            endpoint_id: String::new(),
            ticket: String::new(),
            updated_at_ms: 0,
            online: false,
            error: String::new(),
            message: String::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticket_roundtrip_and_ipv6_priority() {
        let mut addrs: Vec<SocketAddr> = vec![
            "192.168.1.25:39481".parse().unwrap(),
            "127.0.0.1:39481".parse().unwrap(),
            "[240e:390:1234::88]:51234".parse().unwrap(),
            "113.108.12.34:51234".parse().unwrap(),
        ];
        addrs.sort_by_key(|a| addr_priority(a.ip()));
        // Global IPv6 must come first, then public IPv4, then private LAN, then loopback
        assert!(addrs[0].is_ipv6());
        assert_eq!(addrs[1], "113.108.12.34:51234".parse().unwrap());
        assert_eq!(addrs[2], "192.168.1.25:39481".parse().unwrap());
        assert_eq!(addrs[3], "127.0.0.1:39481".parse().unwrap());

        let id = DeviceIdentity::ephemeral("Test-Mac").unwrap();
        let ticket = OpenUUTicket {
            v: 1,
            endpoint_id: id.endpoint_id_str(),
            device_id: id.device_id.clone(),
            device_name: id.device_name.clone(),
            device_code: id.device_code.clone(),
            relay_urls: vec!["https://relay-hk.example.com.".to_string()],
            direct_addrs: addrs,
            lan_quic_port: 39481,
        };
        let encoded = ticket.encode().unwrap();
        assert!(encoded.starts_with(TICKET_PREFIX));
        let decoded = OpenUUTicket::decode(&encoded).unwrap();
        assert_eq!(decoded.endpoint_id, ticket.endpoint_id);
        assert_eq!(decoded.device_code, ticket.device_code);
        assert_eq!(decoded.direct_addrs.len(), 4);
    }

    #[test]
    fn pin_rate_limiter_locks_after_five_failures() {
        let limiter = PinRateLimiter::default();
        for i in 1..=4 {
            assert!(limiter.check_allowed("peer-a").is_ok());
            let (count, lock) = limiter.record_failure("peer-a");
            assert_eq!(count, i);
            assert!(lock.is_none());
        }
        let (count, lock) = limiter.record_failure("peer-a");
        assert_eq!(count, 5);
        assert!(lock.is_some());
        assert!(limiter.check_allowed("peer-a").is_err());
        // Different peer is unaffected
        assert!(limiter.check_allowed("peer-b").is_ok());
    }

    #[test]
    fn ticket_filters_fake_ip_and_preserves_active_home_relay() {
        let id = DeviceIdentity::ephemeral("Test-Mac").unwrap();
        let extra = parse_custom_relay_urls("https://openuu-relay.1kb.ren/");
        let ticket = OpenUUTicket {
            v: 1,
            endpoint_id: id.endpoint_id_str(),
            device_id: id.device_id.clone(),
            device_name: id.device_name.clone(),
            device_code: id.device_code.clone(),
            relay_urls: vec!["https://usw1-1.relay.n0.iroh.link./".to_string()],
            direct_addrs: vec![
                "198.18.0.1:51118".parse().unwrap(),
                "198.19.12.3:51118".parse().unwrap(),
                "113.88.70.225:17840".parse().unwrap(),
                "192.168.68.77:51118".parse().unwrap(),
            ],
            lan_quic_port: 39481,
        };

        let ep_addr = ticket.to_endpoint_addr(&extra).unwrap();
        let relays: Vec<String> = ep_addr.relay_urls().map(|u| u.to_string()).collect();
        // Must NOT inject client's extra relay when ticket already specifies the Host's active home relay
        assert_eq!(relays, vec!["https://usw1-1.relay.n0.iroh.link./"]);

        let ips: Vec<SocketAddr> = ep_addr.ip_addrs().copied().collect();
        assert!(!ips.iter().any(|sa| sa.ip().to_string().starts_with("198.18.")));
        assert!(!ips.iter().any(|sa| sa.ip().to_string().starts_with("198.19.")));
        assert!(ips.contains(&"113.88.70.225:17840".parse().unwrap()));
        assert!(ips.contains(&"192.168.68.77:51118".parse().unwrap()));

        // When ticket has no relay_urls, client extra_relays acts as fallback
        let mut no_relay_ticket = ticket;
        no_relay_ticket.relay_urls.clear();
        let ep_fallback = no_relay_ticket.to_endpoint_addr(&extra).unwrap();
        let fallback_relays: Vec<String> = ep_fallback.relay_urls().map(|u| u.to_string()).collect();
        assert_eq!(fallback_relays, vec!["https://openuu-relay.1kb.ren/"]);
    }
}

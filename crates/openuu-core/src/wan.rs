use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::str::FromStr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use iroh::endpoint::{presets, BindOpts, QuicTransportConfig, VarInt};
use iroh::tls::CaTlsConfig;
use iroh::{
    Endpoint, EndpointAddr, PublicKey, RelayConfig, RelayMap, RelayMode, RelayUrl, TransportAddr,
};
use rand::RngCore;
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
pub const DEFAULT_IROH_HOST_PORT: u16 = 39482;
pub const UNIFIED_AUTH_OR_CODE_ERR: &str = "设备代码不存在或访问密码错误";
pub const RATE_LIMIT_ERR: &str = "尝试次数过多，请稍后再试";

/// High-availability Mainland China + Global RFC 5389 STUN servers used to discover public IPv4
/// NAT mappings even when the active Relay runs behind Cloudflare Tunnel without UDP QAD (`7842`).
const STUN_SERVERS: &[&str] = &[
    "stun.miwifi.com:3478",
    "stun.qq.com:3478",
    "stun.chat.bilibili.com:3478",
    "stun.cloudflare.com:3478",
];
const STUN_MAGIC_COOKIE: u32 = 0x2112_A442;

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
    /// Optional SHA-256 fingerprint of Host's TLS certificate so direct QUIC fast-paths
    /// (same-subnet LAN when mDNS is AP-isolated, or direct IPv6/port-forwarded rescue) are MITM-pinned.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub cert_fingerprint: String,
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
        direct_addrs.dedup();

        Self {
            v: 1,
            endpoint_id: endpoint.id().to_string(),
            device_id: identity.device_id.clone(),
            device_name: identity.device_name.clone(),
            device_code: identity.device_code.clone(),
            relay_urls,
            direct_addrs,
            lan_quic_port,
            cert_fingerprint: identity.cert_fingerprint.clone(),
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

/// Returns true for non-routable / virtual TUN Fake-IP / documentation addresses that should never
/// be advertised or probed as direct P2P candidates (e.g. Clash/Mihomo/Surge/Sing-box `198.18.0.0/15`,
/// `fdfe:dcba:9876::/48`, link-local, unspecified, reserved).
pub fn is_unusable_direct_ip(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_unspecified()
                || v4.is_link_local()
                || v4.is_broadcast()
                || v4.is_multicast()
                || o[0] == 0
                || o[0] >= 240
                || (o[0] == 198 && (o[1] == 18 || o[1] == 19)) // RFC 2544 / TUN Fake-IP (198.18.0.0/15)
                || (o[0] == 192 && o[1] == 0 && o[2] == 2) // TEST-NET-1
                || (o[0] == 198 && o[1] == 51 && o[2] == 100) // TEST-NET-2
                || (o[0] == 203 && o[1] == 113 && o[2] == 0) // TEST-NET-3
        }
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_unusable_direct_ip(IpAddr::V4(v4));
            }
            let seg = v6.segments();
            v6.is_unspecified()
                || v6.is_unicast_link_local()
                || v6.is_multicast()
                || (seg[0] == 0x2001 && seg[1] == 0x0db8) // RFC 3849 Documentation
                || (seg[0] == 0x0100 && seg[1] == 0 && seg[2] == 0 && seg[3] == 0) // RFC 6666 Discard
                || (seg[0] == 0xfdfe && seg[1] == 0xdcba && seg[2] == 0x9876) // Clash/Mihomo/Sing-box TUN IPv6
                || (seg[0] & 0xfe00) == 0xfc00 // Unique Local IPv6 (VPN/TUN/Docker ULA, never WAN-routable)
        }
    }
}

/// Rank IP addresses for China / global connectivity:
/// 0 = Genuine Global Unicast IPv6 (2000::/3, fastest direct path across CGNAT ISPs in Mainland China)
/// 1 = Public Unicast IPv4
/// 2 = Private RFC1918 LAN IPv4 (192.168/16, 10/8, 172.16/12)
/// 3 = CGNAT / Overlay 100.64.0.0/10 / Deprecated 6to4 / Teredo
/// 4 = Loopback / Unusable
fn addr_priority(ip: IpAddr) -> u8 {
    if is_unusable_direct_ip(ip) {
        return 4;
    }
    match ip {
        IpAddr::V6(v6) => {
            let seg = v6.segments();
            if v6.is_loopback() || v6.is_unicast_link_local() || v6.is_unspecified() {
                4
            } else if (seg[0] & 0xe000) == 0x2000
                && seg[0] != 0x2002
                && !(seg[0] == 0x2001 && seg[1] == 0x0000)
            {
                // Native Global Unicast IPv6 (e.g. 240e::/20, 2408::/20, 2409::/20)
                0
            } else {
                3
            }
        }
        IpAddr::V4(v4) => {
            if v4.is_loopback() || v4.is_link_local() || v4.is_unspecified() {
                4
            } else if v4.octets()[0] == 100 && (v4.octets()[1] & 0b1100_0000) == 64 {
                // CGNAT / Tailscale / Surge 100.64.0.0/10
                3
            } else if v4.is_private() {
                // RFC1918 physical LAN
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

/// Returns local non-loopback private IPv4 addresses on this machine (used to check whether a
/// remote ticket's RFC1918 LAN IP sits on the exact same `/24` subnet when mDNS is AP-isolated).
pub fn local_private_ipv4s() -> Vec<Ipv4Addr> {
    let mut out = Vec::new();
    // Fast UDP routing-table probe to common private/public targets (transmits zero packets on wire)
    for target in ["192.168.1.1:80", "10.0.0.1:80", "172.16.0.1:80", "223.5.5.5:53"] {
        if let Ok(sock) = std::net::UdpSocket::bind("0.0.0.0:0") {
            if sock.connect(target).is_ok() {
                if let Ok(SocketAddr::V4(local)) = sock.local_addr() {
                    let ip = *local.ip();
                    if ip.is_private() && !out.contains(&ip) {
                        out.push(ip);
                    }
                }
            }
        }
    }
    out
}

pub fn shares_ipv4_lan_subnet(a: Ipv4Addr, b: Ipv4Addr) -> bool {
    if !a.is_private() || !b.is_private() {
        return false;
    }
    let oa = a.octets();
    let ob = b.octets();
    oa[0] == ob[0] && oa[1] == ob[1] && oa[2] == ob[2]
}

pub fn parse_custom_relay_urls(raw: &str) -> Vec<RelayUrl> {
    raw.split(|c: char| c == ',' || c == ';' || c.is_whitespace())
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|s| RelayUrl::from_str(s).ok())
        .collect()
}

// ============================================================================
// RFC 5389 Multi-Server STUN Pre-Prober (Restores IPv4 Hole-Punching on CF Tunnel Relays)
// ============================================================================

#[derive(Debug, Clone, Default)]
pub struct StunProbeOutcome {
    pub bound_v4_port: u16,
    pub external_addrs: Vec<SocketAddr>,
    pub symmetric_nat: bool,
}

pub(crate) fn build_stun_binding_request(tx_id: &[u8; 12]) -> [u8; 20] {
    let mut buf = [0u8; 20];
    // Binding Request = 0x0001, Length = 0x0000
    buf[0] = 0x00;
    buf[1] = 0x01;
    buf[4..8].copy_from_slice(&STUN_MAGIC_COOKIE.to_be_bytes());
    buf[8..20].copy_from_slice(tx_id);
    buf
}

pub(crate) fn parse_stun_binding_response(
    pkt: &[u8],
    expected_tx_id: &[u8; 12],
) -> Option<SocketAddr> {
    if pkt.len() < 20 {
        return None;
    }
    let msg_type = u16::from_be_bytes([pkt[0], pkt[1]]);
    let msg_len = u16::from_be_bytes([pkt[2], pkt[3]]) as usize;
    let cookie = u32::from_be_bytes([pkt[4], pkt[5], pkt[6], pkt[7]]);
    if msg_type != 0x0101 || cookie != STUN_MAGIC_COOKIE || pkt.len() < 20 + msg_len {
        return None;
    }
    if &pkt[8..20] != expected_tx_id {
        return None;
    }

    let cookie_bytes = STUN_MAGIC_COOKIE.to_be_bytes();
    let mut xor_mapped: Option<SocketAddr> = None;
    let mut plain_mapped: Option<SocketAddr> = None;

    let mut off = 20usize;
    let end = 20 + msg_len;
    while off + 4 <= end {
        let attr_type = u16::from_be_bytes([pkt[off], pkt[off + 1]]);
        let attr_len = u16::from_be_bytes([pkt[off + 2], pkt[off + 3]]) as usize;
        off += 4;
        if off + attr_len > end {
            break;
        }
        let val = &pkt[off..off + attr_len];
        // 0x0020 = RFC 5389 XOR-MAPPED-ADDRESS, 0x8020 = legacy draft XOR-MAPPED-ADDRESS (used by some CN STUN servers)
        if (attr_type == 0x0020 || attr_type == 0x8020) && attr_len >= 8 {
            let family = val[1];
            let port = u16::from_be_bytes([val[2], val[3]]) ^ 0x2112;
            if family == 0x01 {
                let ip = Ipv4Addr::new(
                    val[4] ^ cookie_bytes[0],
                    val[5] ^ cookie_bytes[1],
                    val[6] ^ cookie_bytes[2],
                    val[7] ^ cookie_bytes[3],
                );
                xor_mapped = Some(SocketAddr::V4(SocketAddrV4::new(ip, port)));
            } else if family == 0x02 && attr_len >= 20 {
                let mut raw = [0u8; 16];
                for i in 0..4 {
                    raw[i] = val[4 + i] ^ cookie_bytes[i];
                }
                for i in 0..12 {
                    raw[4 + i] = val[8 + i] ^ expected_tx_id[i];
                }
                xor_mapped = Some(SocketAddr::V6(SocketAddrV6::new(
                    Ipv6Addr::from(raw),
                    port,
                    0,
                    0,
                )));
            }
        } else if attr_type == 0x0001 && attr_len >= 8 {
            let family = val[1];
            let port = u16::from_be_bytes([val[2], val[3]]);
            if family == 0x01 {
                let ip = Ipv4Addr::new(val[4], val[5], val[6], val[7]);
                plain_mapped = Some(SocketAddr::V4(SocketAddrV4::new(ip, port)));
            } else if family == 0x02 && attr_len >= 20 {
                let mut raw = [0u8; 16];
                raw.copy_from_slice(&val[4..20]);
                plain_mapped = Some(SocketAddr::V6(SocketAddrV6::new(
                    Ipv6Addr::from(raw),
                    port,
                    0,
                    0,
                )));
            }
        }
        off += (attr_len + 3) & !3;
    }

    xor_mapped.or(plain_mapped)
}

/// Binds an IPv4 UDP socket on `preferred_v4_port` (falling back to an OS-assigned port if busy),
/// concurrently queries multiple domestic + global STUN servers to discover the router's external
/// `IPv4:Port` mapping and NAT symmetry in ~40-80ms, and immediately closes the socket so `iroh`
/// can bind the exact same local UDP port and reuse the live NAT mapping.
pub async fn probe_stun_nat_mapping(preferred_v4_port: u16) -> StunProbeOutcome {
    let sock = if preferred_v4_port != 0 {
        match tokio::net::UdpSocket::bind(SocketAddrV4::new(
            Ipv4Addr::UNSPECIFIED,
            preferred_v4_port,
        ))
        .await
        {
            Ok(s) => s,
            Err(_) => match tokio::net::UdpSocket::bind("0.0.0.0:0").await {
                Ok(s) => s,
                Err(_) => return StunProbeOutcome::default(),
            },
        }
    } else {
        match tokio::net::UdpSocket::bind("0.0.0.0:0").await {
            Ok(s) => s,
            Err(_) => return StunProbeOutcome::default(),
        }
    };

    let bound_v4_port = sock.local_addr().map(|a| a.port()).unwrap_or(0);
    if bound_v4_port == 0 {
        return StunProbeOutcome::default();
    }

    // Resolve STUN servers concurrently with a tight DNS timeout so poisoned/offline DNS never stalls startup
    let mut resolve_tasks = Vec::with_capacity(STUN_SERVERS.len());
    for &srv in STUN_SERVERS {
        resolve_tasks.push(tokio::spawn(async move {
            tokio::time::timeout(Duration::from_millis(320), tokio::net::lookup_host(srv))
                .await
                .ok()
                .and_then(|r| r.ok())
                .and_then(|mut iter| iter.find(|sa| sa.is_ipv4()))
        }));
    }

    let mut targets: Vec<SocketAddr> = Vec::with_capacity(STUN_SERVERS.len());
    for t in resolve_tasks {
        if let Ok(Some(sa)) = t.await {
            if !targets.iter().any(|existing| existing.ip() == sa.ip()) {
                targets.push(sa);
            }
        }
    }

    if targets.is_empty() {
        drop(sock);
        return StunProbeOutcome {
            bound_v4_port,
            external_addrs: Vec::new(),
            symmetric_nat: false,
        };
    }

    let mut sent_tx: Vec<(SocketAddr, [u8; 12])> = Vec::with_capacity(targets.len());
    for target in targets {
        let mut tx_id = [0u8; 12];
        rand::thread_rng().fill_bytes(&mut tx_id);
        let req = build_stun_binding_request(&tx_id);
        if sock.send_to(&req, target).await.is_ok() {
            sent_tx.push((target, tx_id));
        }
    }

    let mut observations: Vec<(IpAddr, SocketAddr)> = Vec::with_capacity(2);
    let overall_deadline = tokio::time::Instant::now() + Duration::from_millis(580);
    let mut second_reply_deadline: Option<tokio::time::Instant> = None;
    let mut recv_buf = [0u8; 256];

    loop {
        let cur_deadline = match second_reply_deadline {
            Some(d) if d < overall_deadline => d,
            _ => overall_deadline,
        };
        let now = tokio::time::Instant::now();
        if now >= cur_deadline {
            break;
        }
        match tokio::time::timeout(cur_deadline - now, sock.recv_from(&mut recv_buf)).await {
            Ok(Ok((n, from))) => {
                for &(srv_addr, ref tx_id) in &sent_tx {
                    if let Some(mapped) = parse_stun_binding_response(&recv_buf[..n], tx_id) {
                        if !is_lan_or_private_ip(mapped.ip())
                            && !is_unusable_direct_ip(mapped.ip())
                        {
                            let srv_ip = srv_addr.ip();
                            let _ = from;
                            if !observations.iter().any(|(ip, _)| *ip == srv_ip) {
                                observations.push((srv_ip, mapped));
                            }
                            if observations.len() == 1 && second_reply_deadline.is_none() {
                                second_reply_deadline =
                                    Some(tokio::time::Instant::now() + Duration::from_millis(95));
                            }
                        }
                        break;
                    }
                }
                if observations.len() >= 2 {
                    break;
                }
            }
            _ => break,
        }
    }

    // Release the socket BEFORE returning so `iroh` can immediately bind `0.0.0.0:bound_v4_port`.
    drop(sock);

    let mut external_addrs = Vec::new();
    let mut symmetric_nat = false;
    if let Some(&(_, first)) = observations.first() {
        external_addrs.push(first);
        if let Some(&(_, second)) = observations.get(1) {
            if second != first {
                symmetric_nat = true;
                if !external_addrs.contains(&second) {
                    external_addrs.push(second);
                }
                // Match iroh's `Qad4LocalPort`: if Host uses a fixed port and user set up router port-forwarding / DMZ
                if preferred_v4_port != 0 {
                    let static_fwd = SocketAddr::new(first.ip(), bound_v4_port);
                    if !external_addrs.contains(&static_fwd) {
                        external_addrs.push(static_fwd);
                    }
                }
                // Sequential-port Symmetric NAT prediction (delta +1 / +2 allocation)
                if first.ip() == second.ip() {
                    let diff = second.port() as i32 - first.port() as i32;
                    if diff.abs() >= 1 && diff.abs() <= 2 {
                        let predicted = second.port() as i32 + diff;
                        if (1024..=65534).contains(&predicted) {
                            let pred_sa = SocketAddr::new(second.ip(), predicted as u16);
                            if !external_addrs.contains(&pred_sa) {
                                external_addrs.push(pred_sa);
                            }
                        }
                    }
                }
            }
        }
    }

    debug!(
        bound_v4_port,
        ?external_addrs,
        symmetric_nat,
        "STUN pre-probe completed"
    );

    StunProbeOutcome {
        bound_v4_port,
        external_addrs,
        symmetric_nat,
    }
}

/// Lightweight ephemeral STUN check used by long-running Hosts to detect ISP PPPoE public IPv4 changes
/// without disturbing the active `iroh` UDP socket.
pub async fn probe_public_ipv4_ephemeral() -> Option<Ipv4Addr> {
    let res = probe_stun_nat_mapping(0).await;
    res.external_addrs.into_iter().find_map(|sa| match sa.ip() {
        IpAddr::V4(v4) => Some(v4),
        IpAddr::V6(_) => None,
    })
}

fn pick_available_v6_port(preferred: u16) -> u16 {
    if preferred == 0 {
        return 0;
    }
    let Ok(sock) = socket2::Socket::new(
        socket2::Domain::IPV6,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    ) else {
        return 0;
    };
    let _ = sock.set_only_v6(true);
    let addr = SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, preferred, 0, 0));
    if sock.bind(&addr.into()).is_ok() {
        preferred
    } else {
        0
    }
}

pub(crate) fn is_cloudflare_no_qad_relay(
    url: &RelayUrl,
    headers: Option<&reqwest::header::HeaderMap>,
) -> bool {
    if let Some(hdrs) = headers {
        if hdrs.contains_key("cf-ray") {
            return true;
        }
        if let Some(srv) = hdrs.get("server").and_then(|v| v.to_str().ok()) {
            if srv.to_ascii_lowercase().contains("cloudflare") {
                return true;
            }
        }
    }
    if let Some(host) = url.host_str() {
        let h = host.trim_end_matches('.').to_ascii_lowercase();
        if h == "openuu-relay.1kb.ren"
            || h.ends_with(".workers.dev")
            || h.ends_with(".trycloudflare.com")
        {
            return true;
        }
    }
    false
}

fn build_relay_config(
    url: RelayUrl,
    headers: Option<&reqwest::header::HeaderMap>,
    auth_token: &str,
) -> RelayConfig {
    let mut cfg = if is_cloudflare_no_qad_relay(&url, headers) {
        // Cloudflare Tunnel / Edge proxies HTTPS/WebSocket only and never forwards raw UDP 7842 QAD.
        // Disabling QAD eliminates wasted multi-second QUIC probe timeouts against CF Anycast IPs.
        RelayConfig::new(url, None)
    } else {
        RelayConfig::from(url)
    };
    if !auth_token.is_empty() {
        cfg = cfg.with_auth_token(auth_token);
    }
    cfg
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
/// returning `RelayConfig`s for healthy relays (automatically disabling UDP 7842 QAD on Cloudflare
/// Tunnel relays while preserving QAD on direct HK/VPS relays).
async fn probe_reachable_relay_configs(
    relays: &[RelayUrl],
    allow_insecure_tls: bool,
    auth_token: &str,
) -> Vec<RelayConfig> {
    if relays.is_empty() {
        return Vec::new();
    }
    let Ok(client) = reqwest::Client::builder()
        .timeout(Duration::from_millis(3500))
        .connect_timeout(Duration::from_millis(2500))
        .danger_accept_invalid_certs(allow_insecure_tls)
        .build()
    else {
        return relays
            .iter()
            .cloned()
            .map(|u| build_relay_config(u, None, auth_token))
            .collect();
    };

    let token_owned = auth_token.to_string();
    let mut handles = Vec::with_capacity(relays.len());
    for url in relays {
        let client = client.clone();
        let relay_url = url.clone();
        let tok = token_owned.clone();
        handles.push(tokio::spawn(async move {
            let base = relay_url.to_string();
            let ping_url = format!("{}/ping", base.trim_end_matches('/'));
            match client.get(&ping_url).send().await {
                Ok(resp) if resp.status().is_success() => {
                    Some(build_relay_config(relay_url, Some(resp.headers()), &tok))
                }
                _ => None,
            }
        }));
    }

    let mut healthy = Vec::new();
    for h in handles {
        if let Ok(Some(cfg)) = h.await {
            healthy.push(cfg);
        }
    }
    healthy
}

/// Concurrently probes custom `iroh-relay` URLs (`GET <relay>/ping`) with a short timeout,
/// returning those that respond with HTTP 2xx so Host endpoints can implement true cascading
/// fallback (prefer healthy custom/domestic relay first; only fall back to overseas `n0` if down).
pub async fn probe_reachable_relays(
    relays: &[RelayUrl],
    allow_insecure_tls: bool,
) -> Vec<RelayUrl> {
    probe_reachable_relay_configs(relays, allow_insecure_tls, "")
        .await
        .into_iter()
        .map(|c| c.url)
        .collect()
}

/// Build a WAN-tuned `iroh::Endpoint` with cascading relay configuration:
/// 1. Direct IPv6 / IPv4 UDP hole-punching (with domestic STUN external-addr pre-injection)
/// 2. Self-hosted Hong Kong / Cloudflare-Tunnel `iroh-relay` (if configured)
/// 3. Public `n0` global relay fallback (when `enable_public_fallback` is true)
pub async fn bind_iroh_endpoint(
    identity: &DeviceIdentity,
    local_only_no_relay: bool,
) -> Result<Endpoint> {
    let (ep, _) = bind_iroh_endpoint_with_port(identity, local_only_no_relay, false, 0).await?;
    Ok(ep)
}

/// Build a WAN-tuned `iroh::Endpoint` with role-aware relay selection.
pub async fn bind_iroh_endpoint_with_role(
    identity: &DeviceIdentity,
    local_only_no_relay: bool,
    prefer_custom_relay_first: bool,
) -> Result<Endpoint> {
    let preferred_port = if prefer_custom_relay_first && !local_only_no_relay {
        DEFAULT_IROH_HOST_PORT
    } else {
        0
    };
    let (ep, _) = bind_iroh_endpoint_with_port(
        identity,
        local_only_no_relay,
        prefer_custom_relay_first,
        preferred_port,
    )
    .await?;
    Ok(ep)
}

/// Build a WAN-tuned `iroh::Endpoint` with concurrent domestic STUN NAT-mapping discovery,
/// deterministic UDP port binding (enabling `Qad4LocalPort`, clean UPnP renewals, and firewall rules),
/// and role-aware Cloudflare/VPS relay selection.
pub async fn bind_iroh_endpoint_with_port(
    identity: &DeviceIdentity,
    local_only_no_relay: bool,
    prefer_custom_relay_first: bool,
    preferred_port: u16,
) -> Result<(Endpoint, StunProbeOutcome)> {
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

    // Run domestic STUN NAT pre-probing and custom Relay HTTP health checks concurrently so STUN adds ~0ms startup delay!
    let (stun_outcome, healthy_custom_cfgs) = if local_only_no_relay {
        (StunProbeOutcome::default(), Vec::new())
    } else if !custom_relays.is_empty() && prefer_custom_relay_first {
        tokio::join!(
            probe_stun_nat_mapping(preferred_port),
            probe_reachable_relay_configs(
                &custom_relays,
                identity.wan_config.allow_insecure_tls,
                relay_token,
            )
        )
    } else {
        (probe_stun_nat_mapping(preferred_port).await, Vec::new())
    };

    let make_base_builder = |quic_cfg: QuicTransportConfig| -> iroh::endpoint::Builder {
        let mut builder = if local_only_no_relay {
            Endpoint::builder(presets::Minimal)
                .clear_address_lookup()
                .relay_mode(RelayMode::Disabled)
        } else if !custom_relays.is_empty() && !identity.wan_config.enable_public_fallback {
            // Strict private relay mode (e.g. Cloudflare Tunnel / Hong Kong self-hosted relay only, zero overseas n0 traffic)
            let cfgs: Vec<RelayConfig> = custom_relays
                .iter()
                .cloned()
                .map(|u| build_relay_config(u, None, relay_token))
                .collect();
            Endpoint::builder(presets::Minimal)
                .clear_address_lookup()
                .relay_mode(RelayMode::Custom(RelayMap::from_iter(cfgs)))
        } else if !custom_relays.is_empty() && prefer_custom_relay_first {
            // True cascading fallback for Host: anchor on healthy custom relay(s) first;
            // only fall back to overseas public n0 relays when every custom relay is unreachable.
            if !healthy_custom_cfgs.is_empty() {
                Endpoint::builder(presets::Minimal)
                    .clear_address_lookup()
                    .relay_mode(RelayMode::Custom(RelayMap::from_iter(
                        healthy_custom_cfgs.clone(),
                    )))
            } else {
                let mut b = Endpoint::builder(presets::N0);
                if !identity.wan_config.coord_url.trim().is_empty() {
                    b = b.clear_address_lookup();
                }
                b
            }
        } else if !custom_relays.is_empty() {
            // Client mixed mode: attach Bearer token & CF QAD bypass ONLY to custom relay(s), then merge public n0 relay pool
            let cfgs: Vec<RelayConfig> = custom_relays
                .iter()
                .cloned()
                .map(|u| build_relay_config(u, None, relay_token))
                .collect();
            let relay_map = RelayMap::from_iter(cfgs);
            relay_map.extend(&RelayMode::Default.relay_map());
            let mut b = Endpoint::builder(presets::N0).relay_mode(RelayMode::Custom(relay_map));
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

        builder
            .secret_key(identity.iroh_secret.clone())
            .alpns(vec![ALPN_OPENUU.to_vec()])
            .transport_config(quic_cfg)
    };

    // Attempt binding the exact STUN-probed UDP port first so external NAT mappings match 1:1
    if !local_only_no_relay && stun_outcome.bound_v4_port != 0 {
        let v4_port = stun_outcome.bound_v4_port;
        let v6_port = pick_available_v6_port(v4_port);
        if let Ok(b_v4) = make_base_builder(quic_cfg.clone()).bind_addr_with_opts(
            SocketAddr::V4(SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, v4_port)),
            BindOpts::default(),
        ) {
            if let Ok(mut b) = b_v4.bind_addr_with_opts(
                SocketAddr::V6(SocketAddrV6::new(Ipv6Addr::UNSPECIFIED, v6_port, 0, 0)),
                BindOpts::default().set_is_required(false),
            ) {
                for &ext in &stun_outcome.external_addrs {
                    b = b.external_addr(ext);
                }
                if let Ok(ep) = b.bind().await {
                    return Ok((ep, stun_outcome));
                }
            }
        }
    }

    // Fallback: OS-assigned random port if `bound_v4_port` lost a sub-millisecond bind race
    let endpoint = make_base_builder(quic_cfg)
        .bind()
        .await
        .map_err(|e| OpenUUError::Wan(format!("iroh endpoint bind failed: {e}")))?;

    Ok((endpoint, StunProbeOutcome::default()))
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
            cert_fingerprint: id.cert_fingerprint.clone(),
        };
        let encoded = ticket.encode().unwrap();
        assert!(encoded.starts_with(TICKET_PREFIX));
        let decoded = OpenUUTicket::decode(&encoded).unwrap();
        assert_eq!(decoded.endpoint_id, ticket.endpoint_id);
        assert_eq!(decoded.device_code, ticket.device_code);
        assert_eq!(decoded.cert_fingerprint, id.cert_fingerprint);
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
                "[fdfe:dcba:9876::1]:51118".parse().unwrap(),
                "[fd7a:115c:a1e0::5]:51118".parse().unwrap(),
                "113.88.70.225:17840".parse().unwrap(),
                "192.168.68.77:51118".parse().unwrap(),
            ],
            lan_quic_port: 39481,
            cert_fingerprint: String::new(),
        };

        let ep_addr = ticket.to_endpoint_addr(&extra).unwrap();
        let relays: Vec<String> = ep_addr.relay_urls().map(|u| u.to_string()).collect();
        // Must NOT inject client's extra relay when ticket already specifies the Host's active home relay
        assert_eq!(relays, vec!["https://usw1-1.relay.n0.iroh.link./"]);

        let ips: Vec<SocketAddr> = ep_addr.ip_addrs().copied().collect();
        assert!(!ips.iter().any(|sa| sa.ip().to_string().starts_with("198.18.")));
        assert!(!ips.iter().any(|sa| sa.ip().to_string().starts_with("198.19.")));
        assert!(!ips.iter().any(|sa| sa.ip().is_ipv6())); // Clash/Tailscale ULA IPv6 filtered out
        assert!(ips.contains(&"113.88.70.225:17840".parse().unwrap()));
        assert!(ips.contains(&"192.168.68.77:51118".parse().unwrap()));

        // When ticket has no relay_urls, client extra_relays acts as fallback
        let mut no_relay_ticket = ticket;
        no_relay_ticket.relay_urls.clear();
        let ep_fallback = no_relay_ticket.to_endpoint_addr(&extra).unwrap();
        let fallback_relays: Vec<String> = ep_fallback.relay_urls().map(|u| u.to_string()).collect();
        assert_eq!(fallback_relays, vec!["https://openuu-relay.1kb.ren/"]);
    }

    #[test]
    fn stun_rfc5389_xor_mapped_ipv4_and_ipv6_parsing() {
        let tx_id: [u8; 12] = [
            0xb7, 0xe7, 0xa7, 0x01, 0xbc, 0x34, 0xd6, 0x86, 0xfa, 0x87, 0xdf, 0xae,
        ];
        let req = build_stun_binding_request(&tx_id);
        assert_eq!(&req[0..4], &[0x00, 0x01, 0x00, 0x00]);
        assert_eq!(&req[4..8], &[0x21, 0x12, 0xa4, 0x42]);
        assert_eq!(&req[8..20], &tx_id);

        // RFC 5769 IPv4 test vector: 192.0.2.1:32853 -> X-Port = 0xa147, X-Address = 0xe112a643
        let mut resp_v4 = Vec::new();
        resp_v4.extend_from_slice(&[0x01, 0x01, 0x00, 0x0c]); // Binding Success, len=12
        resp_v4.extend_from_slice(&[0x21, 0x12, 0xa4, 0x42]);
        resp_v4.extend_from_slice(&tx_id);
        resp_v4.extend_from_slice(&[0x00, 0x20, 0x00, 0x08]); // XOR-MAPPED-ADDRESS, len=8
        resp_v4.extend_from_slice(&[0x00, 0x01, 0xa1, 0x47, 0xe1, 0x12, 0xa6, 0x43]);

        let parsed_v4 = parse_stun_binding_response(&resp_v4, &tx_id).unwrap();
        assert_eq!(parsed_v4, "192.0.2.1:32853".parse().unwrap());

        // Mismatched transaction ID must be rejected
        let mut bad_tx = tx_id;
        bad_tx[0] ^= 0xff;
        assert!(parse_stun_binding_response(&resp_v4, &bad_tx).is_none());

        // Legacy 0x8020 XOR-MAPPED-ADDRESS (common on domestic CN STUN servers)
        let mut resp_legacy = resp_v4.clone();
        resp_legacy[20] = 0x80;
        resp_legacy[21] = 0x20;
        assert_eq!(
            parse_stun_binding_response(&resp_legacy, &tx_id).unwrap(),
            "192.0.2.1:32853".parse().unwrap()
        );

        // RFC 5769 IPv6 test vector: [2001:db8:1234:5678:11:2233:4455:6677]:32853
        let mut resp_v6 = Vec::new();
        resp_v6.extend_from_slice(&[0x01, 0x01, 0x00, 0x18]); // Binding Success, len=24
        resp_v6.extend_from_slice(&[0x21, 0x12, 0xa4, 0x42]);
        resp_v6.extend_from_slice(&tx_id);
        resp_v6.extend_from_slice(&[0x00, 0x20, 0x00, 0x14]); // XOR-MAPPED-ADDRESS, len=20
        resp_v6.extend_from_slice(&[
            0x00, 0x02, 0xa1, 0x47, 0x01, 0x13, 0xa9, 0xfa, 0xa5, 0xd3, 0xf1, 0x79, 0xbc, 0x25,
            0xf4, 0xb5, 0xbe, 0xd2, 0xb9, 0xd9,
        ]);
        let parsed_v6 = parse_stun_binding_response(&resp_v6, &tx_id).unwrap();
        assert_eq!(
            parsed_v6,
            "[2001:db8:1234:5678:11:2233:4455:6677]:32853"
                .parse()
                .unwrap()
        );
    }

    #[test]
    fn cloudflare_tunnel_relay_disables_doomed_qad_while_direct_vps_keeps_qad() {
        let cf_url = RelayUrl::from_str("https://openuu-relay.1kb.ren/").unwrap();
        let cf_cfg = build_relay_config(cf_url, None, "tok123");
        assert!(cf_cfg.quic.is_none());
        assert_eq!(cf_cfg.auth_token.as_deref(), Some("tok123"));

        let hk_vps_url = RelayUrl::from_str("https://relay-hk.myserver.com/").unwrap();
        let hk_cfg = build_relay_config(hk_vps_url.clone(), None, "tok123");
        assert!(hk_cfg.quic.is_some());

        let mut cf_headers = reqwest::header::HeaderMap::new();
        cf_headers.insert("cf-ray", "8abc123456-HKG".parse().unwrap());
        let proxied_cfg = build_relay_config(hk_vps_url, Some(&cf_headers), "");
        assert!(proxied_cfg.quic.is_none());
    }

    #[tokio::test]
    async fn iroh_external_addr_injection_surfaces_public_ipv4_in_ticket_without_qad() {
        init_crypto();
        let id = DeviceIdentity::ephemeral("CF-Tunnel-Host").unwrap();
        let injected_pub_v4: SocketAddr = "113.108.55.66:39482".parse().unwrap();

        let ep = Endpoint::builder(presets::Minimal)
            .clear_address_lookup()
            .relay_mode(RelayMode::Disabled)
            .secret_key(id.iroh_secret.clone())
            .alpns(vec![ALPN_OPENUU.to_vec()])
            .external_addr(injected_pub_v4)
            .bind()
            .await
            .unwrap();

        let ticket = OpenUUTicket::from_endpoint(&ep, &id, 39481);
        assert!(
            ticket.direct_addrs.contains(&injected_pub_v4),
            "injected STUN external IPv4 must appear in OpenUUTicket even when QAD is unavailable: {:?}",
            ticket.direct_addrs
        );
        assert_eq!(ticket.cert_fingerprint, id.cert_fingerprint);
        ep.close().await;
    }
}

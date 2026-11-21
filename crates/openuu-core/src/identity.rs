use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{OnceLock, RwLock};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::STANDARD as BASE64_STD;
use base64::Engine;
use iroh::SecretKey;
use rand::Rng;
use rcgen::{CertificateParams, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::error::{OpenUUError, Result};

fn default_true() -> bool {
    true
}

pub const DEFAULT_COORD_URL: &str = "https://openuu.1kb.ren";
pub const DEFAULT_RELAY_URL: &str = "https://openuu-relay.1kb.ren";
pub const DEFAULT_RELAY_AUTH_TOKEN: &str = "openuu-public-relay-fair-use";

fn default_coord_url() -> String {
    DEFAULT_COORD_URL.to_string()
}

fn default_relay_url() -> String {
    DEFAULT_RELAY_URL.to_string()
}

pub fn default_relay_auth_token() -> String {
    DEFAULT_RELAY_AUTH_TOKEN.to_string()
}

/// Multi-layer WAN & Relay configuration (supports CF Tunnel zero-IP relay, HK private server + public n0 fallback).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WanConfig {
    /// Default cloud coordination server URL ("https://openuu.1kb.ren"), overridable in Settings.
    #[serde(default = "default_coord_url")]
    pub coord_url: String,
    /// Self-hosted / Cloudflare-Tunnel iroh-relay URL(s), comma-separated (defaults to "https://openuu-relay.1kb.ren").
    #[serde(default = "default_relay_url")]
    pub relay_url: String,
    /// Optional Bearer token sent to private `relay_url` (`Authorization: Bearer <token>`).
    #[serde(default = "default_relay_auth_token")]
    pub relay_auth_token: String,
    /// Keep public n0 relays & Pkarr/DNS lookup enabled as ultimate fallback behind custom relay.
    #[serde(default = "default_true")]
    pub enable_public_fallback: bool,
    /// Allow self-signed TLS certificates when deploying pure-IP HTTPS servers without a domain.
    #[serde(default)]
    pub allow_insecure_tls: bool,
}

impl Default for WanConfig {
    fn default() -> Self {
        Self {
            coord_url: DEFAULT_COORD_URL.to_string(),
            relay_url: DEFAULT_RELAY_URL.to_string(),
            relay_auth_token: default_relay_auth_token(),
            enable_public_fallback: true,
            allow_insecure_tls: false,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceConfig {
    pub device_id: String,
    pub device_name: String,
    pub cert_pem: String,
    pub key_pem: String,
    #[serde(default)]
    pub iroh_secret_hex: String,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub wan_config: WanConfig,
    #[serde(default)]
    pub trusted_peers: HashMap<String, TrustedPeer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustedPeer {
    pub device_id: String,
    pub device_name: String,
    #[serde(default)]
    pub cert_fingerprint: String,
    #[serde(default)]
    pub endpoint_id: String,
    #[serde(default)]
    pub device_code: String,
    #[serde(default)]
    pub last_relay_url: String,
    #[serde(default)]
    pub last_ticket: String,
    #[serde(default)]
    pub last_connected_ms: u64,
}

#[derive(Debug, Clone)]
pub struct DeviceIdentity {
    pub device_id: String,
    pub device_name: String,
    pub cert_der: Vec<u8>,
    pub key_der: Vec<u8>,
    pub cert_fingerprint: String,
    pub iroh_secret: SecretKey,
    pub device_code: String,
    pub wan_config: WanConfig,
    pub config_path: PathBuf,
    pub trusted_peers: HashMap<String, TrustedPeer>,
}

static GLOBAL_CONFIG_DIR: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();
static GLOBAL_CACHE_DIR: OnceLock<RwLock<Option<PathBuf>>> = OnceLock::new();

/// Sets process-wide default config and cache directories (primarily for mobile sandboxes such as
/// iOS/Android where `dirs::config_dir()` and `std::env::temp_dir()` are unavailable or unwritable).
pub fn set_global_app_dirs(config_dir: Option<PathBuf>, cache_dir: Option<PathBuf>) {
    let cfg_lock = GLOBAL_CONFIG_DIR.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = cfg_lock.write() {
        *guard = config_dir.filter(|p| !p.as_os_str().is_empty());
    }
    let cache_lock = GLOBAL_CACHE_DIR.get_or_init(|| RwLock::new(None));
    if let Ok(mut guard) = cache_lock.write() {
        *guard = cache_dir.filter(|p| !p.as_os_str().is_empty());
    }
}

/// Returns the configured cache directory override, falling back to `std::env::temp_dir()`.
pub fn default_cache_dir() -> PathBuf {
    if let Some(lock) = GLOBAL_CACHE_DIR.get() {
        if let Ok(guard) = lock.read() {
            if let Some(dir) = guard.as_ref() {
                if !dir.as_os_str().is_empty() {
                    return dir.clone();
                }
            }
        }
    }
    std::env::temp_dir()
}

impl DeviceIdentity {
    pub fn default_config_dir() -> PathBuf {
        if let Some(lock) = GLOBAL_CONFIG_DIR.get() {
            if let Ok(guard) = lock.read() {
                if let Some(dir) = guard.as_ref() {
                    if !dir.as_os_str().is_empty() {
                        return dir.clone();
                    }
                }
            }
        }
        if let Ok(custom) = std::env::var("OPENUU_CONFIG_DIR") {
            if !custom.trim().is_empty() {
                return PathBuf::from(custom);
            }
        }
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("openuu")
    }

    /// Returns the hex/base32 `EndpointId` (Ed25519 public key) used by `iroh`.
    pub fn endpoint_id_str(&self) -> String {
        self.iroh_secret.public().to_string()
    }

    /// Formats the 9-digit device code as `123 456 789` for human display.
    pub fn formatted_device_code(&self) -> String {
        format_device_code(&self.device_code)
    }

    /// Sign an arbitrary message with this device's Ed25519 `iroh::SecretKey`, returning hex signature.
    pub fn sign_hex(&self, message: &[u8]) -> String {
        let sig = self.iroh_secret.sign(message);
        hex::encode(sig.to_bytes())
    }

    /// Load existing device identity from disk (transparently upgrading legacy configs) or generate a new one.
    pub fn load_or_create(config_dir: Option<&Path>, device_name: Option<String>) -> Result<Self> {
        let dir = config_dir
            .map(PathBuf::from)
            .unwrap_or_else(Self::default_config_dir);
        fs::create_dir_all(&dir)?;
        let config_path = dir.join("identity.json");

        if config_path.exists() {
            let raw = fs::read_to_string(&config_path)?;
            let mut cfg: DeviceConfig = serde_json::from_str(&raw)
                .map_err(|e| OpenUUError::Crypto(format!("invalid identity.json: {e}")))?;
            let cert_der = pem_to_der(&cfg.cert_pem)?;
            let key_der = pem_to_der(&cfg.key_pem)?;
            let cert_fingerprint = sha256_hex(&cert_der);

            let mut needs_save = false;
            let iroh_secret = match decode_secret_hex(&cfg.iroh_secret_hex) {
                Some(sk) => sk,
                None => {
                    let sk = generate_iroh_secret();
                    cfg.iroh_secret_hex = hex::encode(sk.to_bytes());
                    needs_save = true;
                    sk
                }
            };
            let normalized_code = normalize_device_code(&cfg.device_code);
            let device_code = if normalized_code.len() == 9 {
                normalized_code
            } else {
                let derived = derive_device_code(iroh_secret.public().as_bytes());
                cfg.device_code = derived.clone();
                needs_save = true;
                derived
            };

            if cfg.wan_config.coord_url.trim().is_empty() {
                cfg.wan_config.coord_url = DEFAULT_COORD_URL.to_string();
                needs_save = true;
            }
            if cfg.wan_config.relay_url.trim().is_empty()
                && cfg.wan_config.coord_url.trim() == DEFAULT_COORD_URL
            {
                cfg.wan_config.relay_url = DEFAULT_RELAY_URL.to_string();
                needs_save = true;
            }
            if cfg.wan_config.relay_auth_token.trim().is_empty()
                || (cfg.wan_config.relay_url.trim() == DEFAULT_RELAY_URL
                    && cfg.wan_config.relay_auth_token.starts_with("ouu_"))
            {
                let default_tok = default_relay_auth_token();
                if !default_tok.is_empty() {
                    cfg.wan_config.relay_auth_token = default_tok;
                    needs_save = true;
                }
            }

            if needs_save {
                if let Ok(serialized) = serde_json::to_string_pretty(&cfg) {
                    let _ = fs::write(&config_path, serialized);
                }
            }

            return Ok(Self {
                device_id: cfg.device_id,
                device_name: cfg.device_name,
                cert_der,
                key_der,
                cert_fingerprint,
                iroh_secret,
                device_code,
                wan_config: cfg.wan_config,
                config_path,
                trusted_peers: cfg.trusted_peers,
            });
        }

        let device_id = Uuid::new_v4().to_string();
        let name = device_name.unwrap_or_else(default_hostname);
        let (cert_pem, key_pem, cert_der, key_der) = generate_self_signed(&device_id)?;
        let cert_fingerprint = sha256_hex(&cert_der);
        let iroh_secret = generate_iroh_secret();
        let device_code = derive_device_code(iroh_secret.public().as_bytes());
        let wan_config = WanConfig::default();

        let cfg = DeviceConfig {
            device_id: device_id.clone(),
            device_name: name.clone(),
            cert_pem,
            key_pem,
            iroh_secret_hex: hex::encode(iroh_secret.to_bytes()),
            device_code: device_code.clone(),
            wan_config: wan_config.clone(),
            trusted_peers: HashMap::new(),
        };
        let serialized = serde_json::to_string_pretty(&cfg)
            .map_err(|e| OpenUUError::Crypto(e.to_string()))?;
        fs::write(&config_path, serialized)?;

        Ok(Self {
            device_id,
            device_name: name,
            cert_der,
            key_der,
            cert_fingerprint,
            iroh_secret,
            device_code,
            wan_config,
            config_path,
            trusted_peers: HashMap::new(),
        })
    }

    /// Create an ephemeral in-memory identity (useful for tests).
    pub fn ephemeral(device_name: &str) -> Result<Self> {
        let device_id = Uuid::new_v4().to_string();
        let (_cert_pem, _key_pem, cert_der, key_der) = generate_self_signed(&device_id)?;
        let cert_fingerprint = sha256_hex(&cert_der);
        let iroh_secret = generate_iroh_secret();
        let device_code = derive_device_code(iroh_secret.public().as_bytes());
        Ok(Self {
            device_id,
            device_name: device_name.to_string(),
            cert_der,
            key_der,
            cert_fingerprint,
            iroh_secret,
            device_code,
            wan_config: WanConfig::default(),
            config_path: PathBuf::new(),
            trusted_peers: HashMap::new(),
        })
    }

    pub fn rustls_cert_and_key(&self) -> (Vec<CertificateDer<'static>>, PrivateKeyDer<'static>) {
        let cert = CertificateDer::from(self.cert_der.clone());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key_der.clone()));
        (vec![cert], key)
    }

    /// Cryptographically verify whether a peer is trusted by matching BOTH `device_id` AND its
    /// authenticated TLS certificate fingerprint or `iroh::EndpointId`.
    pub fn is_trusted_authenticated(&self, device_id: &str, verified_peer_key: &str) -> bool {
        if verified_peer_key.is_empty() {
            return false;
        }
        let Some(tp) = self.trusted_peers.get(device_id) else {
            return false;
        };
        (!tp.endpoint_id.is_empty() && tp.endpoint_id == verified_peer_key)
            || (!tp.cert_fingerprint.is_empty() && tp.cert_fingerprint == verified_peer_key)
    }

    pub fn find_trusted_by_code_or_id(&self, query: &str) -> Option<&TrustedPeer> {
        let norm_code = normalize_device_code(query);
        self.trusted_peers.values().find(|tp| {
            tp.device_id == query
                || (!tp.endpoint_id.is_empty() && tp.endpoint_id == query)
                || (norm_code.len() == 9 && tp.device_code == norm_code)
        })
    }

    pub fn trust_peer(&mut self, mut peer: TrustedPeer) -> Result<()> {
        if peer.last_connected_ms == 0 {
            peer.last_connected_ms = now_epoch_ms();
        }
        if let Some(existing) = self.trusted_peers.get(&peer.device_id) {
            if peer.cert_fingerprint.is_empty() {
                peer.cert_fingerprint = existing.cert_fingerprint.clone();
            }
            if peer.endpoint_id.is_empty() {
                peer.endpoint_id = existing.endpoint_id.clone();
            }
            if peer.device_code.is_empty() {
                peer.device_code = existing.device_code.clone();
            }
            if peer.last_relay_url.is_empty() {
                peer.last_relay_url = existing.last_relay_url.clone();
            }
            if peer.last_ticket.is_empty() {
                peer.last_ticket = existing.last_ticket.clone();
            }
        }
        self.trusted_peers.insert(peer.device_id.clone(), peer);
        self.persist_to_disk()
    }

    pub fn remove_trusted_peer(&mut self, device_id: &str) -> Result<bool> {
        let removed_mem = self.trusted_peers.remove(device_id).is_some();
        let mut removed_disk = false;
        if !self.config_path.as_os_str().is_empty() && self.config_path.exists() {
            let raw = fs::read_to_string(&self.config_path)?;
            let mut cfg: DeviceConfig = serde_json::from_str(&raw)
                .map_err(|e| OpenUUError::Crypto(e.to_string()))?;
            removed_disk = cfg.trusted_peers.remove(device_id).is_some();
            for (k, v) in &self.trusted_peers {
                cfg.trusted_peers.insert(k.clone(), v.clone());
            }
            self.trusted_peers = cfg.trusted_peers.clone();
            let serialized = serde_json::to_string_pretty(&cfg)
                .map_err(|e| OpenUUError::Crypto(e.to_string()))?;
            fs::write(&self.config_path, serialized)?;
        }
        Ok(removed_mem || removed_disk)
    }

    pub fn set_device_code(&mut self, new_code: String) -> Result<()> {
        let norm = normalize_device_code(&new_code);
        if norm.len() == 9 && norm != self.device_code {
            self.device_code = norm;
            self.persist_to_disk()?;
        }
        Ok(())
    }

    pub fn set_wan_config(&mut self, wan_config: WanConfig) -> Result<()> {
        self.wan_config = wan_config;
        self.persist_to_disk()
    }

    fn persist_to_disk(&mut self) -> Result<()> {
        if !self.config_path.as_os_str().is_empty() && self.config_path.exists() {
            let raw = fs::read_to_string(&self.config_path)?;
            let mut cfg: DeviceConfig = serde_json::from_str(&raw)
                .map_err(|e| OpenUUError::Crypto(e.to_string()))?;
            cfg.iroh_secret_hex = hex::encode(self.iroh_secret.to_bytes());
            cfg.device_code = self.device_code.clone();
            cfg.wan_config = self.wan_config.clone();
            // Merge rather than overwrite `trusted_peers` so concurrent runtimes never wipe paired peers!
            for (k, v) in &self.trusted_peers {
                let should_replace = cfg
                    .trusted_peers
                    .get(k)
                    .map(|old| v.last_connected_ms >= old.last_connected_ms)
                    .unwrap_or(true);
                if should_replace {
                    cfg.trusted_peers.insert(k.clone(), v.clone());
                }
            }
            self.trusted_peers = cfg.trusted_peers.clone();
            let serialized = serde_json::to_string_pretty(&cfg)
                .map_err(|e| OpenUUError::Crypto(e.to_string()))?;
            fs::write(&self.config_path, serialized)?;
        }
        Ok(())
    }
}

pub fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

pub fn generate_pairing_pin() -> String {
    let mut rng = rand::thread_rng();
    format!("{:06}", rng.gen_range(0..1_000_000))
}

/// Generates an 8-character unambiguous alphanumeric password suitable for WAN remote access.
pub fn generate_strong_access_code() -> String {
    const CHARSET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    let mut rng = rand::thread_rng();
    (0..8)
        .map(|_| CHARSET[rng.gen_range(0..CHARSET.len())] as char)
        .collect()
}

/// Deterministically derives a 9-digit numeric device code (`100000000`..=`999999999`) from a 32-byte Ed25519 public key.
pub fn derive_device_code(pubkey_bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(b"openuu-device-code-v1:");
    hasher.update(pubkey_bytes);
    let digest = hasher.finalize();
    let num = u64::from_be_bytes([
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
    ]);
    let code = 100_000_000 + (num % 900_000_000);
    format!("{code:09}")
}

/// Strips spaces and dashes from a user-entered 9-digit device code (`"839 201 475"` -> `"839201475"`).
pub fn normalize_device_code(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_digit() || c == ' ' || c == '-')
    {
        return String::new();
    }
    trimmed.chars().filter(|c| c.is_ascii_digit()).collect()
}

pub fn format_device_code(code: &str) -> String {
    let digits = normalize_device_code(code);
    if digits.len() == 9 {
        format!("{} {} {}", &digits[0..3], &digits[3..6], &digits[6..9])
    } else {
        code.to_string()
    }
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn generate_iroh_secret() -> SecretKey {
    let mut rng = rand::thread_rng();
    let mut seed = [0u8; 32];
    rng.fill(&mut seed);
    SecretKey::from_bytes(&seed)
}

fn decode_secret_hex(hex_str: &str) -> Option<SecretKey> {
    let bytes = hex::decode(hex_str.trim()).ok()?;
    let arr: [u8; 32] = bytes.try_into().ok()?;
    Some(SecretKey::from_bytes(&arr))
}

fn generate_self_signed(device_id: &str) -> Result<(String, String, Vec<u8>, Vec<u8>)> {
    let key_pair = KeyPair::generate_for(&rcgen::PKCS_ED25519)
        .map_err(|e| OpenUUError::Crypto(format!("keygen failed: {e}")))?;
    let mut params = CertificateParams::new(vec![
        "openuu.local".to_string(),
        format!("{device_id}.openuu.local"),
        "localhost".to_string(),
    ])
    .map_err(|e| OpenUUError::Crypto(format!("cert params failed: {e}")))?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, format!("OpenUU-{device_id}"));

    let cert = params
        .self_signed(&key_pair)
        .map_err(|e| OpenUUError::Crypto(format!("self-sign failed: {e}")))?;

    let cert_der = cert.der().to_vec();
    let key_der = key_pair.serialize_der();
    Ok((cert.pem(), key_pair.serialize_pem(), cert_der, key_der))
}

fn pem_to_der(pem: &str) -> Result<Vec<u8>> {
    let b64: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .map(str::trim)
        .collect::<Vec<_>>()
        .join("");
    BASE64_STD
        .decode(b64)
        .map_err(|e| OpenUUError::Crypto(format!("invalid PEM base64: {e}")))
}

fn default_hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| "OpenUU-Mac".to_string())
}

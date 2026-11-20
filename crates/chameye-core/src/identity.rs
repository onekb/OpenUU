use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use rand::Rng;
use rcgen::{CertificateParams, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use crate::error::{ChameyeError, Result};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceConfig {
    pub device_id: String,
    pub device_name: String,
    pub cert_pem: String,
    pub key_pem: String,
    #[serde(default)]
    pub trusted_peers: HashMap<String, TrustedPeer>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TrustedPeer {
    pub device_id: String,
    pub device_name: String,
    pub cert_fingerprint: String,
}

#[derive(Debug, Clone)]
pub struct DeviceIdentity {
    pub device_id: String,
    pub device_name: String,
    pub cert_der: Vec<u8>,
    pub key_der: Vec<u8>,
    pub cert_fingerprint: String,
    pub config_path: PathBuf,
    pub trusted_peers: HashMap<String, TrustedPeer>,
}

impl DeviceIdentity {
    pub fn default_config_dir() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("chameye")
    }

    /// Load existing device identity from disk or generate a new Ed25519 identity.
    pub fn load_or_create(config_dir: Option<&Path>, device_name: Option<String>) -> Result<Self> {
        let dir = config_dir
            .map(PathBuf::from)
            .unwrap_or_else(Self::default_config_dir);
        fs::create_dir_all(&dir)?;
        let config_path = dir.join("identity.json");

        if config_path.exists() {
            let raw = fs::read_to_string(&config_path)?;
            let cfg: DeviceConfig = serde_json::from_str(&raw)
                .map_err(|e| ChameyeError::Crypto(format!("invalid identity.json: {e}")))?;
            let cert_der = pem_to_der(&cfg.cert_pem)?;
            let key_der = pem_to_der(&cfg.key_pem)?;
            let cert_fingerprint = sha256_hex(&cert_der);
            return Ok(Self {
                device_id: cfg.device_id,
                device_name: cfg.device_name,
                cert_der,
                key_der,
                cert_fingerprint,
                config_path,
                trusted_peers: cfg.trusted_peers,
            });
        }

        let device_id = Uuid::new_v4().to_string();
        let name = device_name.unwrap_or_else(default_hostname);
        let (cert_pem, key_pem, cert_der, key_der) = generate_self_signed(&device_id)?;
        let cert_fingerprint = sha256_hex(&cert_der);

        let cfg = DeviceConfig {
            device_id: device_id.clone(),
            device_name: name.clone(),
            cert_pem,
            key_pem,
            trusted_peers: HashMap::new(),
        };
        let serialized = serde_json::to_string_pretty(&cfg)
            .map_err(|e| ChameyeError::Crypto(e.to_string()))?;
        fs::write(&config_path, serialized)?;

        Ok(Self {
            device_id,
            device_name: name,
            cert_der,
            key_der,
            cert_fingerprint,
            config_path,
            trusted_peers: HashMap::new(),
        })
    }

    /// Create an ephemeral in-memory identity (useful for tests).
    pub fn ephemeral(device_name: &str) -> Result<Self> {
        let device_id = Uuid::new_v4().to_string();
        let (_cert_pem, _key_pem, cert_der, key_der) = generate_self_signed(&device_id)?;
        let cert_fingerprint = sha256_hex(&cert_der);
        Ok(Self {
            device_id,
            device_name: device_name.to_string(),
            cert_der,
            key_der,
            cert_fingerprint,
            config_path: PathBuf::new(),
            trusted_peers: HashMap::new(),
        })
    }

    pub fn rustls_cert_and_key(&self) -> (Vec<CertificateDer<'static>>, PrivateKeyDer<'static>) {
        let cert = CertificateDer::from(self.cert_der.clone());
        let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(self.key_der.clone()));
        (vec![cert], key)
    }

    pub fn is_trusted(&self, device_id: &str) -> bool {
        self.trusted_peers.contains_key(device_id)
    }

    pub fn trust_peer(&mut self, peer: TrustedPeer) -> Result<()> {
        self.trusted_peers.insert(peer.device_id.clone(), peer);
        if self.config_path.exists() {
            let raw = fs::read_to_string(&self.config_path)?;
            let mut cfg: DeviceConfig = serde_json::from_str(&raw)
                .map_err(|e| ChameyeError::Crypto(e.to_string()))?;
            cfg.trusted_peers = self.trusted_peers.clone();
            let serialized = serde_json::to_string_pretty(&cfg)
                .map_err(|e| ChameyeError::Crypto(e.to_string()))?;
            fs::write(&self.config_path, serialized)?;
        }
        Ok(())
    }
}

pub fn generate_pairing_pin() -> String {
    let mut rng = rand::thread_rng();
    format!("{:06}", rng.gen_range(0..1_000_000))
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn generate_self_signed(device_id: &str) -> Result<(String, String, Vec<u8>, Vec<u8>)> {
    let key_pair = KeyPair::generate_for(&rcgen::PKCS_ED25519)
        .map_err(|e| ChameyeError::Crypto(format!("keygen failed: {e}")))?;
    let mut params = CertificateParams::new(vec![
        "chameye.local".to_string(),
        format!("{device_id}.chameye.local"),
        "localhost".to_string(),
    ])
    .map_err(|e| ChameyeError::Crypto(format!("cert params failed: {e}")))?;
    params
        .distinguished_name
        .push(rcgen::DnType::CommonName, format!("Chameye-{device_id}"));

    let cert = params
        .self_signed(&key_pair)
        .map_err(|e| ChameyeError::Crypto(format!("self-sign failed: {e}")))?;

    let cert_der = cert.der().to_vec();
    let key_der = key_pair.serialize_der();
    Ok((cert.pem(), key_pair.serialize_pem(), cert_der, key_der))
}

fn pem_to_der(pem: &str) -> Result<Vec<u8>> {
    let b64: String = pem
        .lines()
        .filter(|l| !l.starts_with("-----"))
        .collect::<Vec<_>>()
        .join("");
    base64_decode(&b64).ok_or_else(|| ChameyeError::Crypto("invalid PEM base64".into()))
}

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut rev = [255u8; 256];
    for (i, &c) in TABLE.iter().enumerate() {
        rev[c as usize] = i as u8;
    }
    let clean: Vec<u8> = input.bytes().filter(|b| !b.is_ascii_whitespace()).collect();
    if clean.len() % 4 != 0 {
        return None;
    }
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks_exact(4) {
        let a = rev[chunk[0] as usize];
        let b = rev[chunk[1] as usize];
        if a == 255 || b == 255 {
            return None;
        }
        out.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = rev[chunk[2] as usize];
            if c == 255 {
                return None;
            }
            out.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = rev[chunk[3] as usize];
                if d == 255 {
                    return None;
                }
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

fn default_hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("COMPUTERNAME"))
        .unwrap_or_else(|_| "Chameye-Mac".to_string())
}

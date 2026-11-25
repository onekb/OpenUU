use std::fs;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use libadb::keys::rsa::rand_core::OsRng;
use libadb::keys::KeyName;
use libadb::pairing::{self, PairingError};
use libadb::shell::v1 as shell_v1;
use libadb::transport::tls::MaybeTls;
use libadb::{
    AdbKey, Connection, ConnectionConfig, Feature, HostBanner, TlsClientConfig, TlsIdentity,
    TokioTcp,
};
use serde::Serialize;
use tokio::net::TcpStream;

use crate::identity::DeviceIdentity;
use crate::transport::init_crypto;

static ADB_KEY_LOCK: OnceLock<Mutex<Option<String>>> = OnceLock::new();

#[derive(Serialize)]
pub struct AdbPairResultJson {
    pub ok: bool,
    pub guid: String,
    pub error: String,
}

#[derive(Serialize)]
pub struct AdbShellResultJson {
    pub ok: bool,
    pub output: String,
    pub error: String,
}

fn adb_key_path() -> PathBuf {
    DeviceIdentity::default_config_dir().join("adb_host_key.pem")
}

fn load_or_create_adb_key() -> Result<AdbKey, String> {
    let key_name = KeyName::new("openuu@local").map_err(|e| format!("invalid key name: {e:?}"))?;
    let lock = ADB_KEY_LOCK.get_or_init(|| Mutex::new(None));
    let mut cached_pem = lock.lock().map_err(|_| "adb key mutex poisoned".to_string())?;

    if let Some(pem) = cached_pem.as_deref() {
        if let Ok(k) = AdbKey::from_pkcs8_pem(pem, &mut OsRng, key_name) {
            return Ok(k);
        }
    }

    let path = adb_key_path();
    if let Ok(existing_pem) = fs::read_to_string(&path) {
        if let Ok(k) = AdbKey::from_pkcs8_pem(&existing_pem, &mut OsRng, key_name) {
            *cached_pem = Some(existing_pem);
            return Ok(k);
        }
    }

    let generated = AdbKey::generate(&mut OsRng, key_name)
        .map_err(|e| format!("RSA-2048 密钥生成失败: {e}"))?;
    let pem_zeroizing = generated
        .to_pkcs8_pem()
        .map_err(|e| format!("导出 PKCS#8 密钥失败: {e}"))?;
    let pem_str = pem_zeroizing.as_str().to_string();

    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let _ = fs::write(&path, pem_str.as_bytes());
    *cached_pem = Some(pem_str);
    Ok(generated)
}

pub async fn pair_wireless_adb(host: &str, pairing_port: u16, code: &str) -> AdbPairResultJson {
    init_crypto();
    let clean_host = if host.trim().is_empty() {
        "127.0.0.1"
    } else {
        host.trim()
    };
    let clean_code = code.trim();
    if clean_code.is_empty() || pairing_port == 0 {
        return AdbPairResultJson {
            ok: false,
            guid: String::new(),
            error: "配对端口或 6 位配对码为空".to_string(),
        };
    }

    let key = match load_or_create_adb_key() {
        Ok(k) => k,
        Err(e) => {
            return AdbPairResultJson {
                ok: false,
                guid: String::new(),
                error: e,
            }
        }
    };

    let identity = match TlsIdentity::from_key(&key, &mut OsRng) {
        Ok(id) => id,
        Err(e) => {
            return AdbPairResultJson {
                ok: false,
                guid: String::new(),
                error: format!("构建 ADB TLS 证书失败: {e}"),
            }
        }
    };

    let tls_cfg = match TlsClientConfig::adb(&identity) {
        Ok(c) => c,
        Err(e) => {
            return AdbPairResultJson {
                ok: false,
                guid: String::new(),
                error: format!("初始化 ADB TLS 配置失败: {e}"),
            }
        }
    };

    let addr = format!("{clean_host}:{pairing_port}");
    let tcp = match tokio::time::timeout(Duration::from_secs(6), TcpStream::connect(&addr)).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => {
            return AdbPairResultJson {
                ok: false,
                guid: String::new(),
                error: format!("无法连接无线调试配对端口 ({addr}): {e}"),
            }
        }
        Err(_) => {
            return AdbPairResultJson {
                ok: false,
                guid: String::new(),
                error: format!("连接无线调试配对端口超时 ({addr})"),
            }
        }
    };
    let _ = tcp.set_nodelay(true);

    let mut transport = MaybeTls::plain(TokioTcp::new(tcp));
    match tokio::time::timeout(
        Duration::from_secs(10),
        pairing::pair(&mut transport, &tls_cfg, &key, clean_code, &mut OsRng),
    )
    .await
    {
        Ok(Ok(paired)) => AdbPairResultJson {
            ok: true,
            guid: paired.guid,
            error: String::new(),
        },
        Ok(Err(PairingError::WrongCode)) => AdbPairResultJson {
            ok: false,
            guid: String::new(),
            error: "6 位配对码不匹配，请确认数字后重试".to_string(),
        },
        Ok(Err(e)) => AdbPairResultJson {
            ok: false,
            guid: String::new(),
            error: format!("无线调试配对失败: {e}"),
        },
        Err(_) => AdbPairResultJson {
            ok: false,
            guid: String::new(),
            error: "无线调试配对握手超时".to_string(),
        },
    }
}

pub async fn exec_wireless_adb_shell(
    host: &str,
    connect_port: u16,
    command: &str,
) -> AdbShellResultJson {
    init_crypto();
    let clean_host = if host.trim().is_empty() {
        "127.0.0.1"
    } else {
        host.trim()
    };
    if connect_port == 0 || command.trim().is_empty() {
        return AdbShellResultJson {
            ok: false,
            output: String::new(),
            error: "无线调试连接端口或命令为空".to_string(),
        };
    }

    let mut key = match load_or_create_adb_key() {
        Ok(k) => k,
        Err(e) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: e,
            }
        }
    };

    let identity = match TlsIdentity::from_key(&key, &mut OsRng) {
        Ok(id) => id,
        Err(e) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: format!("构建 ADB TLS 证书失败: {e}"),
            }
        }
    };

    let tls_cfg = match TlsClientConfig::adb(&identity) {
        Ok(c) => c,
        Err(e) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: format!("初始化 ADB TLS 配置失败: {e}"),
            }
        }
    };

    let addr = format!("{clean_host}:{connect_port}");
    let tcp = match tokio::time::timeout(Duration::from_secs(5), TcpStream::connect(&addr)).await {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: format!("无法连接无线调试端口 ({addr}): {e}"),
            }
        }
        Err(_) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: format!("连接无线调试端口超时 ({addr})"),
            }
        }
    };
    let _ = tcp.set_nodelay(true);

    let transport = MaybeTls::plain(TokioTcp::new(tcp));
    let mut conn = match tokio::time::timeout(
        Duration::from_secs(8),
        Connection::connect_tls(
            transport,
            &mut key,
            HostBanner::Features(&[Feature::ShellV2]),
            ConnectionConfig::new(),
            &tls_cfg,
        ),
    )
    .await
    {
        Ok(Ok(c)) => c,
        Ok(Err(e)) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: format!("无线调试鉴权失败（若尚未配对，请先进行配对码配对）: {e}"),
            }
        }
        Err(_) => {
            return AdbShellResultJson {
                ok: false,
                output: String::new(),
                error: "无线调试 TLS 握手超时".to_string(),
            }
        }
    };

    let mut rx_buf = vec![0u8; 64 * 1024];
    match tokio::time::timeout(
        Duration::from_secs(10),
        shell_v1::exec(&mut conn, command, &mut rx_buf),
    )
    .await
    {
        Ok(Ok(n)) => {
            let text = String::from_utf8_lossy(&rx_buf[..n]).trim().to_string();
            AdbShellResultJson {
                ok: true,
                output: text,
                error: String::new(),
            }
        }
        Ok(Err(e)) => AdbShellResultJson {
            ok: false,
            output: String::new(),
            error: format!("执行 ADB Shell 命令失败: {e}"),
        },
        Err(_) => AdbShellResultJson {
            ok: false,
            output: String::new(),
            error: "执行 ADB Shell 命令超时".to_string(),
        },
    }
}

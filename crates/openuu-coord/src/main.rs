use std::collections::HashMap;
use std::env;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use axum::extract::{Path, State};
use axum::http::{HeaderMap, StatusCode};
use axum::routing::{get, post};
use axum::{Json, Router};
use ring::signature::{UnparsedPublicKey, ED25519};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tokio::sync::RwLock;
use tracing::{info, warn};

const MAX_TICKET_LEN: usize = 8192;
const MAX_CLOCK_SKEW_MS: u64 = 10 * 60 * 1000; // 10 minutes
const ONLINE_TTL_MS: u64 = 12 * 60 * 1000; // 12 minutes (heartbeat every 5m + instant IP-change push)
const STALE_EVICT_MS: u64 = 30 * 24 * 3600 * 1000; // 30 days
const MAX_BATCH_ITEMS: usize = 32;

const MAX_RESOLVE_FAILURES: u32 = 5;
const FAIL_WINDOW_MS: u64 = 10 * 60 * 1000;
const LOCKOUT_MS: u64 = 10 * 60 * 1000;

const UNIFIED_ERR_MSG: &str = "设备代码不存在或访问密码错误";
const RATE_LIMIT_MSG: &str = "尝试次数过多，请稍后再试";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct StoredDeviceRecord {
    device_code: String,
    device_id: String,
    device_name: String,
    endpoint_id: String,
    pubkey_hex: String,
    #[serde(default)]
    pin_proof_hex: String,
    ticket: String,
    updated_at_ms: u64,
}

#[derive(Default, Serialize, Deserialize)]
struct PersistedStore {
    by_code: HashMap<String, StoredDeviceRecord>,
    by_pubkey: HashMap<String, String>,
}

#[derive(Default, Clone)]
struct RateLimitEntry {
    fail_count: u32,
    window_start_ms: u64,
    locked_until_ms: u64,
}

struct AppState {
    store: RwLock<PersistedStore>,
    rate_limits: RwLock<HashMap<String, RateLimitEntry>>,
    data_path: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordRegisterReq {
    device_code: String,
    device_id: String,
    device_name: String,
    endpoint_id: String,
    pubkey_hex: String,
    #[serde(default)]
    pin_proof_hex: String,
    ticket: String,
    timestamp_ms: u64,
    signature_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordRegisterResp {
    ok: bool,
    assigned_code: String,
    message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
struct CoordResolveResp {
    found: bool,
    device_code: String,
    device_id: String,
    device_name: String,
    endpoint_id: String,
    ticket: String,
    updated_at_ms: u64,
    online: bool,
    #[serde(default)]
    error: String,
    #[serde(default)]
    message: String,
}

fn unified_auth_error() -> (StatusCode, Json<CoordResolveResp>) {
    (
        StatusCode::UNAUTHORIZED,
        Json(CoordResolveResp {
            found: false,
            device_code: String::new(),
            device_id: String::new(),
            device_name: String::new(),
            endpoint_id: String::new(),
            ticket: String::new(),
            updated_at_ms: 0,
            online: false,
            error: "invalid_code_or_pin".into(),
            message: UNIFIED_ERR_MSG.into(),
        }),
    )
}

fn rate_limited_error() -> (StatusCode, Json<CoordResolveResp>) {
    (
        StatusCode::TOO_MANY_REQUESTS,
        Json(CoordResolveResp {
            found: false,
            device_code: String::new(),
            device_id: String::new(),
            device_name: String::new(),
            endpoint_id: String::new(),
            ticket: String::new(),
            updated_at_ms: 0,
            online: false,
            error: "rate_limited".into(),
            message: RATE_LIMIT_MSG.into(),
        }),
    )
}

fn now_epoch_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn normalize_code(raw: &str) -> String {
    let trimmed = raw.trim();
    if !trimmed
        .chars()
        .all(|c| c.is_ascii_digit() || c == ' ' || c == '-')
    {
        return String::new();
    }
    trimmed.chars().filter(|c| c.is_ascii_digit()).collect()
}

fn normalize_hex64(raw: &str) -> String {
    let clean = raw.trim().to_ascii_lowercase();
    if clean.len() == 64 && clean.chars().all(|c| c.is_ascii_hexdigit()) {
        clean
    } else {
        String::new()
    }
}

fn constant_time_eq(a: &str, b: &str) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.as_bytes().iter().zip(b.as_bytes().iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

fn client_ip_key(headers: &HeaderMap) -> String {
    headers
        .get("cf-connecting-ip")
        .or_else(|| headers.get("x-forwarded-for"))
        .and_then(|v| v.to_str().ok())
        .map(|s| s.split(',').next().unwrap_or("local").trim().to_string())
        .unwrap_or_else(|| "local".to_string())
}

async fn is_ip_locked(state: &AppState, ip_key: &str, now: u64) -> bool {
    let rl = state.rate_limits.read().await;
    rl.get(ip_key)
        .map(|e| e.locked_until_ms > now)
        .unwrap_or(false)
}

async fn record_ip_failure(state: &AppState, ip_key: &str, delta: u32, now: u64) -> bool {
    if delta == 0 {
        return false;
    }
    let mut rl = state.rate_limits.write().await;
    let entry = rl.entry(ip_key.to_string()).or_default();
    if now.saturating_sub(entry.window_start_ms) > FAIL_WINDOW_MS {
        entry.fail_count = 0;
        entry.window_start_ms = now;
        entry.locked_until_ms = 0;
    }
    entry.fail_count = entry.fail_count.saturating_add(delta);
    if entry.fail_count >= MAX_RESOLVE_FAILURES {
        entry.locked_until_ms = now + LOCKOUT_MS;
        true
    } else {
        false
    }
}

async fn clear_ip_failure(state: &AppState, ip_key: &str) {
    state.rate_limits.write().await.remove(ip_key);
}

fn derive_device_code(pubkey_bytes: &[u8]) -> u64 {
    let mut hasher = Sha256::new();
    hasher.update(b"openuu-device-code-v1:");
    hasher.update(pubkey_bytes);
    let digest = hasher.finalize();
    let num = u64::from_be_bytes([
        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
    ]);
    100_000_000 + (num % 900_000_000)
}

fn build_signing_message_v1(
    device_code: &str,
    endpoint_id: &str,
    ticket: &str,
    timestamp_ms: u64,
) -> Vec<u8> {
    format!("openuu-coord-v1:{device_code}:{endpoint_id}:{ticket}:{timestamp_ms}").into_bytes()
}

fn build_signing_message_v2(
    device_code: &str,
    endpoint_id: &str,
    ticket: &str,
    timestamp_ms: u64,
    pin_proof_hex: &str,
) -> Vec<u8> {
    format!("openuu-coord-v2:{device_code}:{endpoint_id}:{ticket}:{timestamp_ms}:{pin_proof_hex}")
        .into_bytes()
}

async fn health_handler() -> Json<serde_json::Value> {
    Json(serde_json::json!({
        "status": "ok",
        "service": "openuu-coord",
    }))
}

async fn register_handler(
    State(state): State<Arc<AppState>>,
    Json(req): Json<CoordRegisterReq>,
) -> (StatusCode, Json<CoordRegisterResp>) {
    let norm_code = normalize_code(&req.device_code);
    if norm_code.len() != 9 {
        return (
            StatusCode::BAD_REQUEST,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "device_code must be 9 digits".into(),
            }),
        );
    }
    if req.ticket.is_empty() || req.ticket.len() > MAX_TICKET_LEN {
        return (
            StatusCode::BAD_REQUEST,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "invalid ticket length".into(),
            }),
        );
    }

    let now = now_epoch_ms();
    if now.abs_diff(req.timestamp_ms) > MAX_CLOCK_SKEW_MS {
        return (
            StatusCode::UNAUTHORIZED,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "timestamp out of 10-minute window".into(),
            }),
        );
    }

    let Ok(pubkey_bytes) = hex::decode(req.pubkey_hex.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "invalid pubkey_hex".into(),
            }),
        );
    };
    if pubkey_bytes.len() != 32 {
        return (
            StatusCode::BAD_REQUEST,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "Ed25519 pubkey must be 32 bytes".into(),
            }),
        );
    }
    let Ok(sig_bytes) = hex::decode(req.signature_hex.trim()) else {
        return (
            StatusCode::BAD_REQUEST,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "invalid signature_hex".into(),
            }),
        );
    };

    let pin_proof_hex = normalize_hex64(&req.pin_proof_hex);
    let verifier = UnparsedPublicKey::new(&ED25519, &pubkey_bytes);
    let msg_v2 = build_signing_message_v2(
        &norm_code,
        &req.endpoint_id,
        &req.ticket,
        req.timestamp_ms,
        &pin_proof_hex,
    );
    let msg_v1 =
        build_signing_message_v1(&norm_code, &req.endpoint_id, &req.ticket, req.timestamp_ms);

    let sig_ok = (!pin_proof_hex.is_empty() && verifier.verify(&msg_v2, &sig_bytes).is_ok())
        || verifier.verify(&msg_v1, &sig_bytes).is_ok();
    if !sig_ok {
        warn!("Rejected invalid Ed25519 signature for code={norm_code}");
        return (
            StatusCode::UNAUTHORIZED,
            Json(CoordRegisterResp {
                ok: false,
                assigned_code: String::new(),
                message: "Ed25519 signature verification failed".into(),
            }),
        );
    }

    let canonical_pk = hex::encode(&pubkey_bytes);
    let base_code_num = derive_device_code(&pubkey_bytes);

    let (assigned_code, snapshot_json) = {
        let mut store = state.store.write().await;
        let preferred_code = store
            .by_pubkey
            .get(&canonical_pk)
            .cloned()
            .unwrap_or_else(|| format!("{base_code_num:09}"));

        let mut chosen_code = None;
        let candidates = std::iter::once(preferred_code).chain((0..64u64).map(|offset| {
            let num = 100_000_000 + ((base_code_num - 100_000_000 + offset) % 900_000_000);
            format!("{num:09}")
        }));

        for cand in candidates {
            match store.by_code.get(&cand) {
                None => {
                    chosen_code = Some(cand);
                    break;
                }
                Some(existing)
                    if existing.pubkey_hex == canonical_pk
                        || now.saturating_sub(existing.updated_at_ms) > STALE_EVICT_MS =>
                {
                    chosen_code = Some(cand);
                    break;
                }
                Some(_) => continue,
            }
        }

        let Some(final_code) = chosen_code else {
            return (
                StatusCode::CONFLICT,
                Json(CoordRegisterResp {
                    ok: false,
                    assigned_code: String::new(),
                    message: "unable to allocate collision-free 9-digit code".into(),
                }),
            );
        };

        let record = StoredDeviceRecord {
            device_code: final_code.clone(),
            device_id: req.device_id,
            device_name: req.device_name,
            endpoint_id: req.endpoint_id,
            pubkey_hex: canonical_pk.clone(),
            pin_proof_hex,
            ticket: req.ticket,
            updated_at_ms: now,
        };
        store.by_code.insert(final_code.clone(), record);
        store.by_pubkey.insert(canonical_pk, final_code.clone());

        let snap = if state.data_path.is_some() {
            serde_json::to_vec(&*store).ok()
        } else {
            None
        };
        (final_code, snap)
    };

    if let (Some(path), Some(bytes)) = (&state.data_path, snapshot_json) {
        if let Some(parent) = path.parent() {
            let _ = tokio::fs::create_dir_all(parent).await;
        }
        let tmp_path = path.with_extension("json.tmp");
        if tokio::fs::write(&tmp_path, bytes).await.is_ok() {
            let _ = tokio::fs::rename(&tmp_path, path).await;
        }
    }

    (
        StatusCode::OK,
        Json(CoordRegisterResp {
            ok: true,
            assigned_code,
            message: "registered".into(),
        }),
    )
}

async fn resolve_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(raw_code): Path<String>,
) -> (StatusCode, Json<CoordResolveResp>) {
    let now = now_epoch_ms();
    let ip_key = client_ip_key(&headers);
    if is_ip_locked(&state, &ip_key, now).await {
        return rate_limited_error();
    }

    let code = normalize_code(&raw_code);
    let provided_proof = headers
        .get("x-openuu-pin-proof")
        .and_then(|v| v.to_str().ok())
        .map(normalize_hex64)
        .unwrap_or_default();

    if code.len() != 9 || provided_proof.is_empty() {
        let locked = record_ip_failure(&state, &ip_key, 1, now).await;
        return if locked {
            rate_limited_error()
        } else {
            unified_auth_error()
        };
    }

    let matched = {
        let store = state.store.read().await;
        store.by_code.get(&code).cloned()
    };

    if let Some(rec) = matched {
        let online = now.saturating_sub(rec.updated_at_ms) <= ONLINE_TTL_MS;
        let proof_ok = constant_time_eq(&normalize_hex64(&rec.pin_proof_hex), &provided_proof);
        if online && proof_ok {
            clear_ip_failure(&state, &ip_key).await;
            return (
                StatusCode::OK,
                Json(CoordResolveResp {
                    found: true,
                    device_code: rec.device_code,
                    device_id: rec.device_id,
                    device_name: rec.device_name,
                    endpoint_id: rec.endpoint_id,
                    ticket: rec.ticket,
                    updated_at_ms: rec.updated_at_ms,
                    online: true,
                    error: String::new(),
                    message: String::new(),
                }),
            );
        }
    }

    // Exact same response whether code does not exist, host is offline, or PIN proof is wrong!
    let locked = record_ip_failure(&state, &ip_key, 1, now).await;
    if locked {
        rate_limited_error()
    } else {
        unified_auth_error()
    }
}

async fn resolve_endpoint_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(raw_ep): Path<String>,
) -> (StatusCode, Json<CoordResolveResp>) {
    let now = now_epoch_ms();
    let ip_key = client_ip_key(&headers);
    if is_ip_locked(&state, &ip_key, now).await {
        return rate_limited_error();
    }

    let ep_id = normalize_hex64(&raw_ep);
    if ep_id.is_empty() {
        return unified_auth_error();
    }

    let store = state.store.read().await;
    let found_rec = store
        .by_code
        .values()
        .find(|r| r.endpoint_id.eq_ignore_ascii_case(&ep_id));
    if let Some(rec) = found_rec {
        if now.saturating_sub(rec.updated_at_ms) <= ONLINE_TTL_MS {
            return (
                StatusCode::OK,
                Json(CoordResolveResp {
                    found: true,
                    device_code: rec.device_code.clone(),
                    device_id: rec.device_id.clone(),
                    device_name: rec.device_name.clone(),
                    endpoint_id: rec.endpoint_id.clone(),
                    ticket: rec.ticket.clone(),
                    updated_at_ms: rec.updated_at_ms,
                    online: true,
                    error: String::new(),
                    message: String::new(),
                }),
            );
        }
    }
    unified_auth_error()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BatchProbeQueryItem {
    id: String,
    #[serde(default)]
    endpoint_id: String,
    #[serde(default)]
    device_code: String,
    #[serde(default)]
    pin_proof_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordResolveBatchReq {
    #[serde(default)]
    queries: Vec<BatchProbeQueryItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct BatchProbeResultItem {
    id: String,
    found: bool,
    online: bool,
    device_name: String,
    device_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CoordResolveBatchResp {
    items: Vec<BatchProbeResultItem>,
}

async fn resolve_batch_handler(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(req): Json<CoordResolveBatchReq>,
) -> Result<Json<CoordResolveBatchResp>, (StatusCode, Json<CoordResolveResp>)> {
    let now = now_epoch_ms();
    let ip_key = client_ip_key(&headers);
    if is_ip_locked(&state, &ip_key, now).await {
        return Err(rate_limited_error());
    }

    let mut auth_failures = 0u32;
    let mut items = Vec::new();
    {
        let store = state.store.read().await;
        for q in req.queries.into_iter().take(MAX_BATCH_ITEMS) {
            let ep = normalize_hex64(&q.endpoint_id);
            let code = normalize_code(&q.device_code);
            let proof = normalize_hex64(&q.pin_proof_hex);

            if !ep.is_empty() {
                if let Some(rec) = store
                    .by_code
                    .values()
                    .find(|r| r.endpoint_id.eq_ignore_ascii_case(&ep))
                {
                    let online = now.saturating_sub(rec.updated_at_ms) <= ONLINE_TTL_MS;
                    items.push(BatchProbeResultItem {
                        id: q.id,
                        found: online,
                        online,
                        device_name: if online {
                            rec.device_name.clone()
                        } else {
                            String::new()
                        },
                        device_id: if online {
                            rec.device_id.clone()
                        } else {
                            String::new()
                        },
                    });
                    continue;
                }
            } else if code.len() == 9 && !proof.is_empty() {
                if let Some(rec) = store.by_code.get(&code) {
                    if constant_time_eq(&normalize_hex64(&rec.pin_proof_hex), &proof) {
                        let online = now.saturating_sub(rec.updated_at_ms) <= ONLINE_TTL_MS;
                        items.push(BatchProbeResultItem {
                            id: q.id,
                            found: online,
                            online,
                            device_name: if online {
                                rec.device_name.clone()
                            } else {
                                String::new()
                            },
                            device_id: if online {
                                rec.device_id.clone()
                            } else {
                                String::new()
                            },
                        });
                        continue;
                    }
                    auth_failures += 1;
                }
            }

            items.push(BatchProbeResultItem {
                id: q.id,
                found: false,
                online: false,
                device_name: String::new(),
                device_id: String::new(),
            });
        }
    }

    if auth_failures > 0 {
        let locked = record_ip_failure(&state, &ip_key, auth_failures, now).await;
        if locked {
            return Err(rate_limited_error());
        }
    }

    Ok(Json(CoordResolveBatchResp { items }))
}

fn build_router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health_handler))
        .route("/v1/register", post(register_handler))
        .route("/v1/resolve-batch", post(resolve_batch_handler))
        .route("/v1/resolve-endpoint/{ep}", get(resolve_endpoint_handler))
        .route("/v1/resolve/{code}", get(resolve_handler))
        .with_state(state)
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt()
        .with_env_filter(
            env::var("RUST_LOG").unwrap_or_else(|_| "info,openuu_coord=debug".to_string()),
        )
        .init();

    let bind_str = env::var("OPENUU_COORD_BIND").unwrap_or_else(|_| "0.0.0.0:8787".to_string());
    let data_file =
        env::var("OPENUU_COORD_DATA").unwrap_or_else(|_| "./data/devices.json".to_string());
    let data_path = PathBuf::from(&data_file);

    let initial_store = if data_path.exists() {
        let raw = tokio::fs::read(&data_path).await?;
        serde_json::from_slice::<PersistedStore>(&raw).unwrap_or_default()
    } else {
        PersistedStore::default()
    };

    info!(
        "Loaded {} device records from {}",
        initial_store.by_code.len(),
        data_path.display()
    );

    let state = Arc::new(AppState {
        store: RwLock::new(initial_store),
        rate_limits: RwLock::new(HashMap::new()),
        data_path: Some(data_path),
    });

    let app = build_router(state);
    let addr: SocketAddr = bind_str.parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    info!("OpenUU Coordination Server listening on http://{addr}");
    axum::serve(listener, app).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::rand::SystemRandom;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn test_pin_proof(code: &str, pin: &str) -> String {
        let mut h = Sha256::new();
        h.update(format!("openuu-pin-proof-v1:{code}:{pin}").as_bytes());
        hex::encode(h.finalize())
    }

    #[tokio::test]
    async fn anti_enumeration_identical_response_and_rate_limit() {
        let state = Arc::new(AppState {
            store: RwLock::new(PersistedStore::default()),
            rate_limits: RwLock::new(HashMap::new()),
            data_path: None,
        });

        let rng = SystemRandom::new();
        let pkcs8_a = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
        let kp_a = Ed25519KeyPair::from_pkcs8(pkcs8_a.as_ref()).unwrap();
        let pub_a = kp_a.public_key().as_ref();
        let code_a = format!("{:09}", derive_device_code(pub_a));
        let ts = now_epoch_ms();
        let ticket_a = "openuu://eyJ2IjoxfQ";
        let ep_a = hex::encode(pub_a);
        let pin_proof = test_pin_proof(&code_a, "889900");
        let msg = build_signing_message_v2(&code_a, &ep_a, ticket_a, ts, &pin_proof);
        let sig_a = hex::encode(kp_a.sign(&msg).as_ref());

        // 1. Valid registration succeeds
        let (status, Json(resp)) = register_handler(
            State(Arc::clone(&state)),
            Json(CoordRegisterReq {
                device_code: code_a.clone(),
                device_id: "dev-a".into(),
                device_name: "Studio-Mac".into(),
                endpoint_id: ep_a.clone(),
                pubkey_hex: hex::encode(pub_a),
                pin_proof_hex: pin_proof.clone(),
                ticket: ticket_a.into(),
                timestamp_ms: ts,
                signature_hex: sig_a,
            }),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert!(resp.ok);

        // 2. Non-existent code AND existing code with wrong PIN MUST return byte-for-byte identical 401 response!
        let mut wrong_pin_headers = HeaderMap::new();
        wrong_pin_headers.insert(
            "x-openuu-pin-proof",
            test_pin_proof(&code_a, "000000").parse().unwrap(),
        );
        let (st_wrong_pin, Json(body_wrong_pin)) = resolve_handler(
            State(Arc::clone(&state)),
            wrong_pin_headers,
            Path(code_a.clone()),
        )
        .await;

        let fake_code = if code_a == "123456789" {
            "987654321"
        } else {
            "123456789"
        };
        let mut fake_code_headers = HeaderMap::new();
        fake_code_headers.insert(
            "x-openuu-pin-proof",
            test_pin_proof(fake_code, "000000").parse().unwrap(),
        );
        let (st_missing_code, Json(body_missing_code)) = resolve_handler(
            State(Arc::clone(&state)),
            fake_code_headers,
            Path(fake_code.to_string()),
        )
        .await;

        assert_eq!(st_wrong_pin, StatusCode::UNAUTHORIZED);
        assert_eq!(st_missing_code, StatusCode::UNAUTHORIZED);
        assert_eq!(body_wrong_pin, body_missing_code);
        assert_eq!(body_wrong_pin.message, UNIFIED_ERR_MSG);
        assert!(body_wrong_pin.ticket.is_empty());

        // 3. Valid PIN proof succeeds and resets failure count
        let mut ok_headers = HeaderMap::new();
        ok_headers.insert("x-openuu-pin-proof", pin_proof.parse().unwrap());
        let (st_ok, Json(body_ok)) =
            resolve_handler(State(Arc::clone(&state)), ok_headers, Path(code_a.clone())).await;
        assert_eq!(st_ok, StatusCode::OK);
        assert!(body_ok.found);
        assert_eq!(body_ok.ticket, ticket_a);

        // 4. 5 consecutive brute-force failures trigger 429 lockout
        for i in 1..=5 {
            let mut bad_h = HeaderMap::new();
            bad_h.insert(
                "x-openuu-pin-proof",
                test_pin_proof(&code_a, &format!("bad{i}")).parse().unwrap(),
            );
            let (st, _) =
                resolve_handler(State(Arc::clone(&state)), bad_h, Path(code_a.clone())).await;
            if i < 5 {
                assert_eq!(st, StatusCode::UNAUTHORIZED);
            } else {
                assert_eq!(st, StatusCode::TOO_MANY_REQUESTS);
            }
        }
    }
}

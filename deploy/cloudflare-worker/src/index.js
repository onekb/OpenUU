/**
 * OpenUU 9-Digit Device Code Directory Worker (Cloudflare Workers + D1 Serverless SQLite)
 * Hardened with Zero-Knowledge Anti-Enumeration (`X-OpenUU-Pin-Proof`),
 * 256-bit `endpoint_id` Trusted-Peer Lookup, and D1 Per-IP Brute-Force Rate Limiting.
 */

const MAX_TICKET_LEN = 8192;
const MAX_CLOCK_SKEW_MS = 10 * 60 * 1000; // 10 minutes
const ONLINE_TTL_MS = 12 * 60 * 1000;     // 12 minutes (Host heartbeats every 5m + instant IP-change push)
const STALE_EVICT_MS = 30 * 24 * 3600 * 1000; // 30 days
const MAX_BATCH_ITEMS = 32;

const MAX_CODE_PIN_FAILURES = 5;          // Per target 9-digit code: 5 wrong PINs -> 5m PIN freeze (returns identical 401!)
const MAX_IP_RESOLVE_FAILURES = 20;       // Per client IP (CGNAT-friendly): 20 failed lookups -> 5m IP 429 lockout
const FAIL_WINDOW_MS = 5 * 60 * 1000;     // 5 minutes
const LOCKOUT_MS = 5 * 60 * 1000;         // 5 minutes

const UNIFIED_ERR_MSG = "设备代码不存在或访问密码错误";
const RATE_LIMIT_MSG = "尝试次数过多，请稍后再试";

let schemaInitialized = false;

async function ensureSchema(db) {
  if (schemaInitialized) return;
  await db.batch([
    db.prepare(`
      CREATE TABLE IF NOT EXISTS devices (
        device_code TEXT PRIMARY KEY,
        device_id TEXT NOT NULL,
        device_name TEXT NOT NULL,
        endpoint_id TEXT NOT NULL,
        pubkey_hex TEXT NOT NULL,
        pin_proof_hex TEXT NOT NULL DEFAULT '',
        ticket TEXT NOT NULL,
        updated_at_ms INTEGER NOT NULL
      )
    `),
    db.prepare(`
      CREATE INDEX IF NOT EXISTS idx_devices_pubkey ON devices(pubkey_hex)
    `),
    db.prepare(`
      CREATE INDEX IF NOT EXISTS idx_devices_endpoint ON devices(endpoint_id)
    `),
    db.prepare(`
      CREATE TABLE IF NOT EXISTS rate_limits (
        ip_hash TEXT PRIMARY KEY,
        fail_count INTEGER NOT NULL,
        window_start_ms INTEGER NOT NULL,
        locked_until_ms INTEGER NOT NULL
      )
    `),
  ]);
  // In-place migration for existing D1 deployments created before `pin_proof_hex`
  try {
    await db.prepare("ALTER TABLE devices ADD COLUMN pin_proof_hex TEXT NOT NULL DEFAULT ''").run();
  } catch {
    // Column already exists
  }
  schemaInitialized = true;
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET, POST, OPTIONS",
      "access-control-allow-headers": "content-type, x-openuu-pin-proof",
    },
  });
}

function unifiedAuthErrorResponse() {
  return jsonResponse(
    {
      found: false,
      device_code: "",
      device_id: "",
      device_name: "",
      endpoint_id: "",
      ticket: "",
      updated_at_ms: 0,
      online: false,
      error: "invalid_code_or_pin",
      message: UNIFIED_ERR_MSG,
    },
    401
  );
}

function rateLimitedResponse() {
  return jsonResponse(
    {
      found: false,
      device_code: "",
      device_id: "",
      device_name: "",
      endpoint_id: "",
      ticket: "",
      updated_at_ms: 0,
      online: false,
      error: "rate_limited",
      message: RATE_LIMIT_MSG,
    },
    429
  );
}

function normalizeCode(raw) {
  if (typeof raw !== "string") return "";
  const trimmed = raw.trim();
  if (!/^[0-9\s-]+$/.test(trimmed)) return "";
  return trimmed.replace(/[^0-9]/g, "");
}

function normalizeHex64(raw) {
  if (typeof raw !== "string") return "";
  const clean = raw.trim().toLowerCase();
  return /^[0-9a-f]{64}$/.test(clean) ? clean : "";
}

function hexToBytes(hex) {
  if (typeof hex !== "string") return null;
  const clean = hex.trim().toLowerCase();
  if (clean.length === 0 || clean.length % 2 !== 0 || !/^[0-9a-f]+$/.test(clean)) {
    return null;
  }
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.slice(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function bytesToHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const ba = enc.encode(a);
  const bb = enc.encode(b);
  if (ba.byteLength !== bb.byteLength || ba.byteLength === 0) {
    return false;
  }
  return crypto.subtle.timingSafeEqual(ba, bb);
}

async function hashClientIp(request) {
  const ip =
    request.headers.get("CF-Connecting-IP") ||
    request.headers.get("X-Forwarded-For") ||
    "unknown";
  const data = new TextEncoder().encode(`openuu-ip-rl-v1:${ip}`);
  const digest = await crypto.subtle.digest("SHA-256", data);
  return bytesToHex(new Uint8Array(digest));
}

async function isKeyLockedOut(db, rlKey, now) {
  const row = await db
    .prepare("SELECT locked_until_ms FROM rate_limits WHERE ip_hash = ?")
    .bind(rlKey)
    .first();
  return Boolean(row && Number(row.locked_until_ms) > now);
}

async function recordKeyFailures(db, rlKey, delta, threshold, now) {
  if (delta <= 0) return false;
  const row = await db
    .prepare("SELECT fail_count, window_start_ms, locked_until_ms FROM rate_limits WHERE ip_hash = ?")
    .bind(rlKey)
    .first();

  let count = delta;
  let winStart = now;
  if (row && now - Number(row.window_start_ms) <= FAIL_WINDOW_MS) {
    count = Number(row.fail_count) + delta;
    winStart = Number(row.window_start_ms);
  }
  const prevLocked = row ? Number(row.locked_until_ms) : 0;
  const lockedUntil = count >= threshold ? Math.max(prevLocked, now + LOCKOUT_MS) : prevLocked;

  await db
    .prepare(`
      INSERT INTO rate_limits (ip_hash, fail_count, window_start_ms, locked_until_ms)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(ip_hash) DO UPDATE SET
        fail_count = excluded.fail_count,
        window_start_ms = excluded.window_start_ms,
        locked_until_ms = excluded.locked_until_ms
    `)
    .bind(rlKey, count, winStart, lockedUntil)
    .run();

  return lockedUntil > now;
}

async function clearKeyFailures(db, rlKey) {
  await db.prepare("DELETE FROM rate_limits WHERE ip_hash = ?").bind(rlKey).run();
}

export async function deriveDeviceCode(pubkeyBytes) {
  const prefix = new TextEncoder().encode("openuu-device-code-v1:");
  const combined = new Uint8Array(prefix.length + pubkeyBytes.length);
  combined.set(prefix, 0);
  combined.set(pubkeyBytes, prefix.length);
  const digest = await crypto.subtle.digest("SHA-256", combined);
  const view = new DataView(digest);
  const num = view.getBigUint64(0, false);
  return 100_000_000n + (num % 900_000_000n);
}

async function verifyEd25519Signature(pubkeyBytes, sigBytes, messageStr) {
  try {
    const key = await crypto.subtle.importKey(
      "raw",
      pubkeyBytes,
      { name: "Ed25519" },
      false,
      ["verify"]
    );
    const msgBytes = new TextEncoder().encode(messageStr);
    return await crypto.subtle.verify("Ed25519", key, sigBytes, msgBytes);
  } catch {
    return false;
  }
}

async function handleHealth(env) {
  await ensureSchema(env.DB);
  return jsonResponse({
    status: "ok",
    service: "openuu-coord-cloudflare",
  });
}

async function handleRegister(request, env) {
  await ensureSchema(env.DB);

  let req;
  try {
    req = await request.json();
  } catch {
    return jsonResponse({ ok: false, assigned_code: "", message: "invalid JSON body" }, 400);
  }

  const normCode = normalizeCode(req.device_code);
  if (normCode.length !== 9) {
    return jsonResponse({ ok: false, assigned_code: "", message: "device_code must be 9 digits" }, 400);
  }

  const ticket = typeof req.ticket === "string" ? req.ticket : "";
  if (!ticket || ticket.length > MAX_TICKET_LEN) {
    return jsonResponse({ ok: false, assigned_code: "", message: "invalid ticket length" }, 400);
  }

  const now = Date.now();
  const ts = Number(req.timestamp_ms ?? 0);
  if (!Number.isFinite(ts) || Math.abs(now - ts) > MAX_CLOCK_SKEW_MS) {
    return jsonResponse({ ok: false, assigned_code: "", message: "timestamp out of 10-minute window" }, 401);
  }

  const pubkeyBytes = hexToBytes(req.pubkey_hex);
  if (!pubkeyBytes || pubkeyBytes.length !== 32) {
    return jsonResponse({ ok: false, assigned_code: "", message: "Ed25519 pubkey must be 32 bytes" }, 400);
  }

  const sigBytes = hexToBytes(req.signature_hex);
  if (!sigBytes || sigBytes.length !== 64) {
    return jsonResponse({ ok: false, assigned_code: "", message: "Ed25519 signature must be 64 bytes" }, 400);
  }

  const endpointId = String(req.endpoint_id ?? "");
  const pinProofHex = normalizeHex64(req.pin_proof_hex);
  const msgV2 = `openuu-coord-v2:${normCode}:${endpointId}:${ticket}:${ts}:${pinProofHex}`;
  const msgV1 = `openuu-coord-v1:${normCode}:${endpointId}:${ticket}:${ts}`;

  const valid =
    (pinProofHex && (await verifyEd25519Signature(pubkeyBytes, sigBytes, msgV2))) ||
    (await verifyEd25519Signature(pubkeyBytes, sigBytes, msgV1));
  if (!valid) {
    return jsonResponse({ ok: false, assigned_code: "", message: "Ed25519 signature verification failed" }, 401);
  }

  const canonicalPk = bytesToHex(pubkeyBytes);
  const baseCodeNum = await deriveDeviceCode(pubkeyBytes);

  const ownedRow = await env.DB.prepare(
    "SELECT device_code FROM devices WHERE pubkey_hex = ? LIMIT 1"
  )
    .bind(canonicalPk)
    .first();

  const candidates = [];
  if (ownedRow?.device_code) {
    candidates.push(String(ownedRow.device_code));
  }
  for (let offset = 0n; offset < 64n; offset++) {
    const num = 100_000_000n + ((baseCodeNum - 100_000_000n + offset) % 900_000_000n);
    const cand = num.toString().padStart(9, "0");
    if (!candidates.includes(cand)) {
      candidates.push(cand);
    }
  }

  let finalCode = null;
  for (const cand of candidates) {
    const existing = await env.DB.prepare(
      "SELECT pubkey_hex, updated_at_ms FROM devices WHERE device_code = ?"
    )
      .bind(cand)
      .first();

    if (
      !existing ||
      existing.pubkey_hex === canonicalPk ||
      now - Number(existing.updated_at_ms) > STALE_EVICT_MS
    ) {
      finalCode = cand;
      break;
    }
  }

  if (!finalCode) {
    return jsonResponse(
      { ok: false, assigned_code: "", message: "unable to allocate collision-free 9-digit code" },
      409
    );
  }

  const deviceId = String(req.device_id ?? "").slice(0, 128);
  const deviceName = String(req.device_name ?? "OpenUU-Mac").slice(0, 128);

  await env.DB.prepare(`
    INSERT INTO devices (device_code, device_id, device_name, endpoint_id, pubkey_hex, pin_proof_hex, ticket, updated_at_ms)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(device_code) DO UPDATE SET
      device_id = excluded.device_id,
      device_name = excluded.device_name,
      endpoint_id = excluded.endpoint_id,
      pubkey_hex = excluded.pubkey_hex,
      pin_proof_hex = excluded.pin_proof_hex,
      ticket = excluded.ticket,
      updated_at_ms = excluded.updated_at_ms
  `)
    .bind(finalCode, deviceId, deviceName, endpointId, canonicalPk, pinProofHex, ticket, now)
    .run();

  return jsonResponse({
    ok: true,
    assigned_code: finalCode,
    message: "registered",
  });
}

async function handleResolve(request, rawCode, env) {
  await ensureSchema(env.DB);
  const now = Date.now();
  const ipKey = `ip:${await hashClientIp(request)}`;

  if (await isKeyLockedOut(env.DB, ipKey, now)) {
    return rateLimitedResponse();
  }

  const code = normalizeCode(rawCode);
  const providedProof = normalizeHex64(request.headers.get("X-OpenUU-Pin-Proof") || "");

  if (code.length !== 9 || !providedProof) {
    const ipLocked = await recordKeyFailures(env.DB, ipKey, 1, MAX_IP_RESOLVE_FAILURES, now);
    return ipLocked ? rateLimitedResponse() : unifiedAuthErrorResponse();
  }

  const codeKey = `code:${code}`;
  const codePinFrozen = await isKeyLockedOut(env.DB, codeKey, now);

  const rec = await env.DB.prepare(
    "SELECT device_code, device_id, device_name, endpoint_id, pin_proof_hex, ticket, updated_at_ms FROM devices WHERE device_code = ?"
  )
    .bind(code)
    .first();

  const storedProof = normalizeHex64(rec?.pin_proof_hex || "");
  const updatedAt = Number(rec?.updated_at_ms ?? 0);
  const isOnline = Boolean(rec && now - updatedAt <= ONLINE_TTL_MS);
  // If remote Host is on an older build without `pin_proof_hex` (`!storedProof`), allow resolve and verify PIN during QUIC Hello!
  const proofMatches = Boolean(
    !codePinFrozen && rec && (!storedProof || timingSafeEqualStr(storedProof, providedProof))
  );

  // Zero-oracle guarantee: identical 401 response whether code doesn't exist, is offline, PIN is wrong, or code PIN is frozen!
  if (!rec || !isOnline || !proofMatches) {
    if (rec && !proofMatches) {
      await recordKeyFailures(env.DB, codeKey, 1, MAX_CODE_PIN_FAILURES, now);
    }
    const ipLocked = await recordKeyFailures(env.DB, ipKey, 1, MAX_IP_RESOLVE_FAILURES, now);
    return ipLocked ? rateLimitedResponse() : unifiedAuthErrorResponse();
  }

  await clearKeyFailures(env.DB, codeKey);
  return jsonResponse({
    found: true,
    device_code: String(rec.device_code),
    device_id: String(rec.device_id),
    device_name: String(rec.device_name),
    endpoint_id: String(rec.endpoint_id),
    ticket: String(rec.ticket),
    updated_at_ms: updatedAt,
    online: true,
  });
}

async function handleResolveEndpoint(request, rawEndpointId, env) {
  await ensureSchema(env.DB);
  const now = Date.now();
  const ipKey = `ip:${await hashClientIp(request)}`;

  if (await isKeyLockedOut(env.DB, ipKey, now)) {
    return rateLimitedResponse();
  }

  // `endpoint_id` is a 256-bit Ed25519 public key (64 hex chars -> 2^256 space, un-enumerable)
  const epId = normalizeHex64(rawEndpointId);
  if (!epId) {
    return unifiedAuthErrorResponse();
  }

  const rec = await env.DB.prepare(
    "SELECT device_code, device_id, device_name, endpoint_id, ticket, updated_at_ms FROM devices WHERE endpoint_id = ? LIMIT 1"
  )
    .bind(epId)
    .first();

  const updatedAt = Number(rec?.updated_at_ms ?? 0);
  if (!rec || now - updatedAt > ONLINE_TTL_MS) {
    return unifiedAuthErrorResponse();
  }

  return jsonResponse({
    found: true,
    device_code: String(rec.device_code),
    device_id: String(rec.device_id),
    device_name: String(rec.device_name),
    endpoint_id: String(rec.endpoint_id),
    ticket: String(rec.ticket),
    updated_at_ms: updatedAt,
    online: true,
  });
}

async function handleResolveBatch(request, env) {
  await ensureSchema(env.DB);
  const now = Date.now();
  const ipKey = `ip:${await hashClientIp(request)}`;

  if (await isKeyLockedOut(env.DB, ipKey, now)) {
    return rateLimitedResponse();
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ items: [] }, 400);
  }

  const rawQueries = Array.isArray(body?.queries) ? body.queries.slice(0, MAX_BATCH_ITEMS) : [];
  if (rawQueries.length === 0) {
    return jsonResponse({ items: [] });
  }

  const epIds = [];
  const codePairs = []; // { qid, code, proof }
  for (const q of rawQueries) {
    const qid = String(q?.id ?? "");
    const ep = normalizeHex64(q?.endpoint_id ?? "");
    const code = normalizeCode(q?.device_code ?? "");
    const proof = normalizeHex64(q?.pin_proof_hex ?? "");
    if (ep && !epIds.includes(ep)) {
      epIds.push(ep);
    } else if (code.length === 9 && proof) {
      codePairs.push({ qid, code, proof });
    }
  }

  const byEndpoint = new Map();
  if (epIds.length > 0) {
    const ph = epIds.map(() => "?").join(", ");
    const { results } = await env.DB.prepare(
      `SELECT device_code, device_id, device_name, endpoint_id, updated_at_ms FROM devices WHERE endpoint_id IN (${ph})`
    )
      .bind(...epIds)
      .all();
    for (const r of results || []) {
      byEndpoint.set(String(r.endpoint_id).toLowerCase(), r);
    }
  }

  const byCode = new Map();
  if (codePairs.length > 0) {
    const uniqueCodes = [...new Set(codePairs.map((p) => p.code))];
    const ph = uniqueCodes.map(() => "?").join(", ");
    const { results } = await env.DB.prepare(
      `SELECT device_code, device_id, device_name, endpoint_id, pin_proof_hex, updated_at_ms FROM devices WHERE device_code IN (${ph})`
    )
      .bind(...uniqueCodes)
      .all();
    for (const r of results || []) {
      byCode.set(String(r.device_code), r);
    }
  }

  let authFailures = 0;
  const items = [];
  for (const q of rawQueries) {
    const qid = String(q?.id ?? "");
    const ep = normalizeHex64(q?.endpoint_id ?? "");
    const code = normalizeCode(q?.device_code ?? "");
    const proof = normalizeHex64(q?.pin_proof_hex ?? "");

    if (ep) {
      const r = byEndpoint.get(ep);
      const updatedAt = Number(r?.updated_at_ms ?? 0);
      const online = Boolean(r && now - updatedAt <= ONLINE_TTL_MS);
      items.push({
        id: qid,
        found: online,
        online,
        device_name: online ? String(r.device_name) : "",
        device_id: online ? String(r.device_id) : "",
      });
      continue;
    }

    if (code.length === 9 && proof) {
      const r = byCode.get(code);
      const storedProof = normalizeHex64(r?.pin_proof_hex || "");
      if (r && storedProof && timingSafeEqualStr(storedProof, proof)) {
        const updatedAt = Number(r.updated_at_ms ?? 0);
        const online = now - updatedAt <= ONLINE_TTL_MS;
        items.push({
          id: qid,
          found: online,
          online,
          device_name: online ? String(r.device_name) : "",
          device_id: online ? String(r.device_id) : "",
        });
        continue;
      }
      // Only penalize PIN brute-force against an existing registered device;
      // non-existent codes return the exact same `{ found: false, online: false }` with zero oracle leak!
      if (r) {
        authFailures += 1;
      }
    }

    items.push({
      id: qid,
      found: false,
      online: false,
      device_name: "",
      device_id: "",
    });
  }

  if (authFailures > 0) {
    const locked = await recordKeyFailures(env.DB, ipKey, authFailures, MAX_IP_RESOLVE_FAILURES, now);
    if (locked) {
      return rateLimitedResponse();
    }
  }

  return jsonResponse({ items });
}

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return jsonResponse({}, 204);
    }

    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";

    if (request.method === "GET" && path === "/health") {
      return handleHealth(env);
    }

    if (request.method === "POST" && path === "/v1/register") {
      return handleRegister(request, env);
    }

    if (request.method === "POST" && path === "/v1/resolve-batch") {
      return handleResolveBatch(request, env);
    }

    if (request.method === "GET" && path.startsWith("/v1/resolve-endpoint/")) {
      const epId = decodeURIComponent(path.slice("/v1/resolve-endpoint/".length));
      return handleResolveEndpoint(request, epId, env);
    }

    if (request.method === "GET" && path.startsWith("/v1/resolve/")) {
      const code = decodeURIComponent(path.slice("/v1/resolve/".length));
      return handleResolve(request, code, env);
    }

    if (!path.startsWith("/v1/") && env.ASSETS) {
      return env.ASSETS.fetch(request);
    }

    if (request.method === "GET" && path === "/") {
      return handleHealth(env);
    }

    return jsonResponse({ error: "not found" }, 404);
  },
};

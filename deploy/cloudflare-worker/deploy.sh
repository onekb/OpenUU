#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export PATH="$HOME/.nvm/versions/node/v24.22.1/bin:$PATH"
WRANGLER="./node_modules/.bin/wrangler"

if [ ! -x "$WRANGLER" ]; then
  echo "==> Installing Wrangler..."
  npm install
fi

echo "==> 1/4 Checking Cloudflare Wrangler authentication..."
if "$WRANGLER" whoami 2>&1 | grep -q "not authenticated"; then
  echo "==> Opening browser for Wrangler OAuth login (please click 'Allow' in browser)..."
  "$WRANGLER" login
fi

echo "==> 2/4 Ensuring D1 database exists..."
DB_JSON="$("$WRANGLER" d1 list --json)"
DB_ID="$(node -e '
  const fs = require("fs");
  const list = JSON.parse(process.argv[1] || "[]");
  const toml = fs.readFileSync("wrangler.toml", "utf8");
  const curIdMatch = toml.match(/database_id\s*=\s*"([^"]+)"/);
  const curId = curIdMatch ? curIdMatch[1] : "";
  const byId = curId && list.find(d => d.uuid === curId);
  const byName = list.find(d => d.name === "openuu-coord-db" || d.name === "chameye-coord-db");
  const found = byId || byName;
  if (found && found.uuid) process.stdout.write(found.uuid);
' "$DB_JSON")"

if [ -z "$DB_ID" ]; then
  echo "==> Creating D1 database 'openuu-coord-db' (location: apac)..."
  CREATE_OUT="$("$WRANGLER" d1 create openuu-coord-db --location apac)"
  echo "$CREATE_OUT"
  DB_JSON="$("$WRANGLER" d1 list --json)"
  DB_ID="$(node -e '
    const list = JSON.parse(process.argv[1] || "[]");
    const found = list.find(d => d.name === "openuu-coord-db");
    if (found && found.uuid) process.stdout.write(found.uuid);
  ' "$DB_JSON")"
fi

if [ -z "$DB_ID" ]; then
  echo "ERROR: Could not obtain database_id for openuu-coord-db" >&2
  exit 1
fi

echo "==> Found D1 database_id: $DB_ID"
node -e '
  const fs = require("fs");
  let toml = fs.readFileSync("wrangler.toml", "utf8");
  toml = toml.replace(/database_id\s*=\s*"[^"]*"/, `database_id = "${process.argv[1]}"`);
  fs.writeFileSync("wrangler.toml", toml);
' "$DB_ID"

echo "==> 3/4 Deploying Worker & binding custom domain https://openuu.1kb.ren ..."
"$WRANGLER" deploy

echo "==> 4/4 Verifying https://openuu.1kb.ren/health ..."
sleep 2
curl -fsSL "https://openuu.1kb.ren/health" || echo "(DNS/TLS certificate provisioning may take 15~30s, retry curl https://openuu.1kb.ren/health shortly)"
echo ""
echo "==> Done! https://openuu.1kb.ren is deployed."

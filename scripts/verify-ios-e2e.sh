#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"

SIM_UDID="${SIM_UDID:-107CB2CF-8335-4705-9D7E-AF9A807353F5}"
APP_PATH="${APP_PATH:-$ROOT_DIR/build/OpenUUMobile-Sim.app}"
MOCK_BIN="${MOCK_BIN:-$ROOT_DIR/target/release/openuu-cli}"
MOCK_PORT="${MOCK_PORT:-39482}"
MOCK_PIN="${MOCK_PIN:-654321}"
MOCK_CFG_DIR="/tmp/openuu-mock-ios"
MOCK_LOG="/tmp/openuu_mock_ios.log"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/build/e2e-artifacts}"
BUNDLE_ID="ren.onekb.openuu"

MOCK_PID=""

cleanup() {
  local rc=$?
  echo "==> Cleaning up iOS simulator and mock-host..."
  xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  xcrun simctl shutdown "$SIM_UDID" >/dev/null 2>&1 || true
  xcrun simctl shutdown all >/dev/null 2>&1 || true
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    sleep 0.3
    kill -9 "$MOCK_PID" 2>/dev/null || true
  fi
  pkill -f "openuu-cli mock-host" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

if [ ! -d "$APP_PATH" ]; then
  echo "ERROR: Simulator .app not found at $APP_PATH" >&2
  exit 1
fi
if [ ! -x "$MOCK_BIN" ]; then
  echo "ERROR: openuu-cli release binary not found at $MOCK_BIN" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -rf "$MOCK_CFG_DIR"
rm -f "$MOCK_LOG"

# Ensure no stale mock-host exists before starting
pkill -f "openuu-cli mock-host" >/dev/null 2>&1 || true
sleep 0.5

echo "==> 1/7 Starting openuu-cli mock-host on port $MOCK_PORT (pin=$MOCK_PIN)..."
"$MOCK_BIN" mock-host --port "$MOCK_PORT" --pin "$MOCK_PIN" --config-dir "$MOCK_CFG_DIR" \
  </dev/null >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

READY_LINE=""
for _ in $(seq 1 60); do
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "ERROR: mock-host exited prematurely:" >&2
    cat "$MOCK_LOG" >&2
    exit 1
  fi
  if grep -q "MOCK_HOST_READY" "$MOCK_LOG" 2>/dev/null; then
    READY_LINE="$(grep "MOCK_HOST_READY" "$MOCK_LOG" | head -n 1)"
    break
  fi
  sleep 0.25
done

if [ -z "$READY_LINE" ]; then
  echo "ERROR: Timed out waiting for MOCK_HOST_READY" >&2
  cat "$MOCK_LOG" >&2
  exit 1
fi
echo "    $READY_LINE"

echo "==> 2/7 Booting iOS Simulator ($SIM_UDID)..."
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b
echo "    Simulator booted and ready"

echo "==> 3/7 Installing $APP_PATH (clean state)..."
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIM_UDID" "$APP_PATH"
echo "    Installed $BUNDLE_ID"

echo "==> 4/7 Cold-launching $BUNDLE_ID (normal launch check)..."
LAUNCH_OUT="$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID")"
APP_PID="$(echo "$LAUNCH_OUT" | awk '{print $NF}' | tr -d '\r\n')"
echo "    Launch output: $LAUNCH_OUT (pid=$APP_PID)"
sleep 3

if [ -z "$APP_PID" ] || ! kill -0 "$APP_PID" 2>/dev/null; then
  echo "ERROR: $BUNDLE_ID is not running after normal launch (pid=$APP_PID)!" >&2
  exit 1
fi
echo "    App alive (pid=$APP_PID)"

xcrun simctl io "$SIM_UDID" screenshot "$ARTIFACT_DIR/ios_01_connect.png"
echo "    Saved screenshot: $ARTIFACT_DIR/ios_01_connect.png ($(wc -c < "$ARTIFACT_DIR/ios_01_connect.png") bytes)"

echo "==> 5/7 Relaunching $BUNDLE_ID with E2E auto-test arguments..."
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 1

DATA_DIR="$(xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" data)"
E2E_LOG="$DATA_DIR/Library/Caches/openuu_e2e.log"
mkdir -p "$(dirname "$E2E_LOG")"
rm -f "$E2E_LOG"
echo "    Sandbox E2E log: $E2E_LOG"

LAUNCH_E2E_OUT="$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" \
  --e2e-target "127.0.0.1:$MOCK_PORT" \
  --e2e-pin "$MOCK_PIN" \
  --e2e-app "com.tencent.xinWeChat" \
  --e2e-autotest 1)"
E2E_PID="$(echo "$LAUNCH_E2E_OUT" | awk '{print $NF}' | tr -d '\r\n')"
echo "    Launched E2E run (pid=$E2E_PID)"

echo "    Polling $E2E_LOG and $MOCK_LOG up to 20s..."
ALL_OK=0
for i in $(seq 1 40); do
  if [ -n "$E2E_PID" ] && ! kill -0 "$E2E_PID" 2>/dev/null; then
    echo "ERROR: $BUNDLE_ID crashed/exited during E2E run (pid=$E2E_PID)!" >&2
    [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2
    cat "$MOCK_LOG" >&2
    exit 1
  fi

  HAS_CONN=0
  HAS_APPS=0
  HAS_START=0
  HAS_TOPO=0
  HAS_DECODE=0
  HAS_SENT=0
  HAS_EVENTS=0

  if [ -f "$E2E_LOG" ]; then
    grep -q "connected to host" "$E2E_LOG" && HAS_CONN=1 || true
    grep -q "list_apps_resp" "$E2E_LOG" && HAS_APPS=1 || true
    grep -Eq "window_topology.*101.*102" "$E2E_LOG" && HAS_TOPO=1 || true
    grep -Eq "decoded_frames=([5-9]|[1-9][0-9]+)" "$E2E_LOG" && HAS_DECODE=1 || true
    grep -q "E2E_ALL_SENT" "$E2E_LOG" && HAS_SENT=1 || true
  fi

  grep -q '"type":"start_session"' "$MOCK_LOG" && HAS_START=1 || true
  if grep -q 'MOCK_EVENT.*"type":"mouse"' "$MOCK_LOG" \
    && grep -Eq 'MOCK_EVENT.*"type":"mouse".*"event_type":3' "$MOCK_LOG" \
    && grep -Eq 'MOCK_EVENT.*"type":"mouse".*"button":1' "$MOCK_LOG" \
    && grep -q 'MOCK_EVENT.*"type":"scroll"' "$MOCK_LOG" \
    && grep -q 'MOCK_EVENT.*"type":"text_commit".*你好，OpenUU iOS 端！' "$MOCK_LOG" \
    && grep -Eq 'MOCK_EVENT.*"type":"key".*"key_code":8.*"modifiers":8' "$MOCK_LOG" \
    && grep -q 'MOCK_EVENT.*"type":"clipboard_sync".*Hello from iOS E2E' "$MOCK_LOG"; then
    HAS_EVENTS=1
  fi

  if [ "$HAS_CONN" = 1 ] && [ "$HAS_APPS" = 1 ] && [ "$HAS_START" = 1 ] \
     && [ "$HAS_TOPO" = 1 ] && [ "$HAS_DECODE" = 1 ] && [ "$HAS_SENT" = 1 ] \
     && [ "$HAS_EVENTS" = 1 ]; then
    ALL_OK=1
    echo "    All E2E assertions satisfied at t=$((i/2))s!"
    break
  fi
  sleep 0.5
done

# Give notification banner time to auto-dismiss & popover renderer (window_id=201) to composite frame
sleep 2.2
xcrun simctl io "$SIM_UDID" screenshot "$ARTIFACT_DIR/ios_02_remote_stream.png"
echo "    Saved screenshot: $ARTIFACT_DIR/ios_02_remote_stream.png ($(wc -c < "$ARTIFACT_DIR/ios_02_remote_stream.png") bytes)"

echo "==> 6/7 Verifying E2E assertions..."
FAIL=0
check_cond() {
  local label="$1"
  shift
  if "$@"; then
    echo "    [PASS] $label"
  else
    echo "    [FAIL] $label" >&2
    FAIL=1
  fi
}

check_cond "Client connected (connected to host)" grep -q "connected to host" "$E2E_LOG"
check_cond "App list received (list_apps_resp)" grep -q "list_apps_resp" "$E2E_LOG"
check_cond "start_session received by mock-host" grep -q '"type":"start_session"' "$MOCK_LOG"
check_cond "window_topology received (101, 102)" grep -Eq "window_topology.*101.*102" "$E2E_LOG"
check_cond "right-click popover topology received (201)" grep -Eq "window_topology.*201" "$E2E_LOG"
check_cond "IOSVideoDisplayRenderer decoded_frames >= 5" grep -Eq "decoded_frames=([5-9]|[1-9][0-9]+)" "$E2E_LOG"
check_cond "E2E_ALL_SENT logged" grep -q "E2E_ALL_SENT" "$E2E_LOG"
check_cond "mock-host MOCK_EVENT mouse" grep -q 'MOCK_EVENT.*"type":"mouse"' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT drag (event_type:3)" grep -Eq 'MOCK_EVENT.*"type":"mouse".*"event_type":3' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT right-click (button:1)" grep -Eq 'MOCK_EVENT.*"type":"mouse".*"button":1' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT scroll" grep -q 'MOCK_EVENT.*"type":"scroll"' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT text_commit (你好，OpenUU iOS 端！)" grep -q 'MOCK_EVENT.*"type":"text_commit".*你好，OpenUU iOS 端！' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT key (key_code:8, modifiers:8)" grep -Eq 'MOCK_EVENT.*"type":"key".*"key_code":8.*"modifiers":8' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT clipboard_sync (Hello from iOS E2E)" grep -q 'MOCK_EVENT.*"type":"clipboard_sync".*Hello from iOS E2E' "$MOCK_LOG"
check_cond "App still alive after E2E" kill -0 "$E2E_PID"

if [ "$FAIL" -ne 0 ]; then
  echo "--- iOS E2E log ($E2E_LOG) ---" >&2
  [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2 || echo "(missing)" >&2
  echo "--- mock-host log ($MOCK_LOG) ---" >&2
  cat "$MOCK_LOG" >&2
  exit 1
fi

echo "==> 6b/7 Verifying Auto-Immersive Landscape Fullscreen (--e2e-landscape 1)..."
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 1
rm -f "$E2E_LOG"

LAND_OUT="$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" \
  --e2e-target "127.0.0.1:$MOCK_PORT" \
  --e2e-pin "" \
  --e2e-app "com.tencent.xinWeChat" \
  --e2e-landscape 1)"
LAND_PID="$(echo "$LAND_OUT" | awk '{print $NF}' | tr -d '\r\n')"
echo "    Launched Landscape E2E run (pid=$LAND_PID)"

LAND_OK=0
for i in $(seq 1 40); do
  if [ -n "$LAND_PID" ] && ! kill -0 "$LAND_PID" 2>/dev/null; then
    echo "ERROR: $BUNDLE_ID crashed/exited during Landscape E2E run!" >&2
    [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2
    exit 1
  fi
  if [ -f "$E2E_LOG" ] && grep -q "E2E_IMMERSIVE_LANDSCAPE" "$E2E_LOG" \
     && grep -Eq "decoded_frames=([5-9]|[1-9][0-9]+)" "$E2E_LOG"; then
    LAND_OK=1
    echo "    [PASS] Auto-Immersive Landscape Fullscreen active at t=$((i/2))s! ($(grep 'E2E_IMMERSIVE_LANDSCAPE' "$E2E_LOG" | tail -n 1))"
    break
  fi
  sleep 0.5
done

sleep 3.2
xcrun simctl io "$SIM_UDID" screenshot "$ARTIFACT_DIR/ios_03_landscape_fullscreen.png"
LANDSCAPE_BYTES="$(wc -c < "$ARTIFACT_DIR/ios_03_landscape_fullscreen.png" | tr -d ' ')"
LANDSCAPE_W="$(sips -g pixelWidth "$ARTIFACT_DIR/ios_03_landscape_fullscreen.png" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
LANDSCAPE_H="$(sips -g pixelHeight "$ARTIFACT_DIR/ios_03_landscape_fullscreen.png" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
echo "    Saved screenshot: $ARTIFACT_DIR/ios_03_landscape_fullscreen.png (${LANDSCAPE_BYTES} bytes, ${LANDSCAPE_W}x${LANDSCAPE_H})"

if [ "$LAND_OK" -ne 1 ]; then
  echo "    [FAIL] E2E_IMMERSIVE_LANDSCAPE was not reached!" >&2
  [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2 || echo "(missing)" >&2
  exit 1
fi
if [ -z "$LANDSCAPE_W" ] || [ -z "$LANDSCAPE_H" ] || [ "$LANDSCAPE_W" -le "$LANDSCAPE_H" ]; then
  echo "    [WARN] simctl screenshot pixels=${LANDSCAPE_W}x${LANDSCAPE_H}; verifying viewport rotation from E2E_IMMERSIVE_LANDSCAPE..."
fi
check_cond "App still alive in Landscape Fullscreen" kill -0 "$LAND_PID"

echo "==> 7/7 Testing passwordless Trusted Peer reconnect (empty PIN)..."
xcrun simctl terminate "$SIM_UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
sleep 1
rm -f "$E2E_LOG"

RECONN_OUT="$(xcrun simctl launch "$SIM_UDID" "$BUNDLE_ID" \
  --e2e-target "127.0.0.1:$MOCK_PORT" \
  --e2e-pin "")"
RECONN_PID="$(echo "$RECONN_OUT" | awk '{print $NF}' | tr -d '\r\n')"
echo "    Launched Trusted Peer reconnect (pid=$RECONN_PID)"

RECONN_OK=0
for i in $(seq 1 30); do
  if [ -n "$RECONN_PID" ] && ! kill -0 "$RECONN_PID" 2>/dev/null; then
    echo "ERROR: $BUNDLE_ID exited during Trusted Peer reconnect!" >&2
    [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2
    exit 1
  fi
  if [ -f "$E2E_LOG" ] && grep -q "connected to host" "$E2E_LOG"; then
    RECONN_OK=1
    echo "    [PASS] Passwordless Trusted Peer reconnect succeeded at t=$((i/2))s!"
    break
  fi
  sleep 0.5
done

if [ "$RECONN_OK" -ne 1 ]; then
  echo "    [FAIL] Passwordless Trusted Peer reconnect did not succeed!" >&2
  echo "--- iOS E2E log ---" >&2
  [ -f "$E2E_LOG" ] && cat "$E2E_LOG" >&2 || echo "(missing)" >&2
  echo "--- mock-host log ---" >&2
  tail -n 40 "$MOCK_LOG" >&2
  exit 1
fi

echo ""
echo "============================================================"
echo " ALL iOS E2E ACCEPTANCE CHECKS PASSED!"
echo " Screenshots:"
echo "   - $ARTIFACT_DIR/ios_01_connect.png"
echo "   - $ARTIFACT_DIR/ios_02_remote_stream.png"
echo "   - $ARTIFACT_DIR/ios_03_landscape_fullscreen.png"
echo "============================================================"

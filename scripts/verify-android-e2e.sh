#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:/opt/homebrew/bin:$PATH"

AVD_NAME="${AVD_NAME:-openuu_test_api35}"
APK_PATH="${APK_PATH:-$ROOT_DIR/build/OpenUU-Android.apk}"
MOCK_BIN="${MOCK_BIN:-$ROOT_DIR/target/release/openuu-cli}"
MOCK_PORT="${MOCK_PORT:-39481}"
MOCK_PIN="${MOCK_PIN:-123456}"
MOCK_CFG_DIR="/tmp/openuu-mock-android"
MOCK_LOG="/tmp/openuu_mock_android.log"
EMU_LOG="/tmp/openuu_emulator.log"
LOGCAT_DUMP="/tmp/openuu_android_logcat.log"
LOGCAT_RECONNECT="/tmp/openuu_android_reconnect.log"
ARTIFACT_DIR="${ARTIFACT_DIR:-$ROOT_DIR/build/e2e-artifacts}"
PKG="ren.onekb.openuu"
ACTIVITY="$PKG/.MainActivity"

MOCK_PID=""
EMU_PID=""
EMU_SERIAL=""

cleanup() {
  local rc=$?
  echo "==> Cleaning up emulator and mock-host..."
  if [ -n "$EMU_SERIAL" ]; then
    adb -s "$EMU_SERIAL" emu kill >/dev/null 2>&1 || true
  else
    adb emu kill >/dev/null 2>&1 || true
  fi
  if [ -n "$EMU_PID" ]; then
    for _ in $(seq 1 10); do
      if ! kill -0 "$EMU_PID" 2>/dev/null; then
        break
      fi
      sleep 0.5
    done
    kill -9 "$EMU_PID" 2>/dev/null || true
  fi
  pkill -f "qemu-system-.*$AVD_NAME" >/dev/null 2>&1 || true
  if [ -n "$MOCK_PID" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    sleep 0.3
    kill -9 "$MOCK_PID" 2>/dev/null || true
  fi
  pkill -f "openuu-cli mock-host" >/dev/null 2>&1 || true
  adb kill-server >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT INT TERM

if [ ! -f "$APK_PATH" ]; then
  echo "ERROR: APK not found at $APK_PATH" >&2
  exit 1
fi
if [ ! -x "$MOCK_BIN" ]; then
  echo "ERROR: openuu-cli release binary not found at $MOCK_BIN" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
rm -rf "$MOCK_CFG_DIR"
rm -f "$MOCK_LOG" "$EMU_LOG" "$LOGCAT_DUMP" "$LOGCAT_RECONNECT"

# Ensure no stale processes exist before starting
pkill -f "openuu-cli mock-host" >/dev/null 2>&1 || true
adb emu kill >/dev/null 2>&1 || true
sleep 1

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
MOCK_TICKET="$(echo "$READY_LINE" | sed -n 's/.*ticket=\([^[:space:]]*\).*/\1/p')"
echo "    Parsed MOCK_TICKET=${MOCK_TICKET:0:48}..."

echo "==> 2/7 Booting Android emulator ($AVD_NAME) headless..."
"$ANDROID_HOME/emulator/emulator" \
  -avd "$AVD_NAME" \
  -no-window \
  -no-audio \
  -no-boot-anim \
  -no-snapshot \
  -gpu swiftshader_indirect \
  </dev/null >"$EMU_LOG" 2>&1 &
EMU_PID=$!

adb start-server >/dev/null 2>&1 || true

# Wait for emulator device to show up
for _ in $(seq 1 120); do
  if ! kill -0 "$EMU_PID" 2>/dev/null; then
    echo "ERROR: Emulator exited prematurely:" >&2
    tail -n 60 "$EMU_LOG" >&2
    exit 1
  fi
  EMU_SERIAL="$(adb devices | awk '/^emulator-[0-9]+[[:space:]]+device$/ {print $1; exit}')"
  if [ -n "$EMU_SERIAL" ]; then
    break
  fi
  sleep 1
done

if [ -z "$EMU_SERIAL" ]; then
  echo "ERROR: Timed out waiting for emulator adb device" >&2
  adb devices >&2
  tail -n 60 "$EMU_LOG" >&2
  exit 1
fi
echo "    Emulator attached: $EMU_SERIAL"

# Wait for sys.boot_completed == 1
BOOT_OK=0
for _ in $(seq 1 180); do
  BOOT_VAL="$(adb -s "$EMU_SERIAL" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')"
  if [ "$BOOT_VAL" = "1" ]; then
    BOOT_OK=1
    break
  fi
  sleep 1
done
if [ "$BOOT_OK" -ne 1 ]; then
  echo "ERROR: Timed out waiting for sys.boot_completed == 1" >&2
  exit 1
fi
echo "    Android booted (sys.boot_completed=1)"
sleep 2

# Unlock screen and dismiss any system/ANR dialogs
adb -s "$EMU_SERIAL" shell wm dismiss-keyguard >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell input keyevent 82 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put global window_animation_scale 0 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put global transition_animation_scale 0 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put global animator_duration_scale 0 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null 2>&1 || true

echo "==> 3/7 Installing APK: $APK_PATH ..."
adb -s "$EMU_SERIAL" install -r -g "$APK_PATH"
adb -s "$EMU_SERIAL" shell pm clear "$PKG" >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

echo "==> 4/7 Cold-launching $ACTIVITY (normal launch check)..."
adb -s "$EMU_SERIAL" logcat -c
adb -s "$EMU_SERIAL" shell am start -W -n "$ACTIVITY"
sleep 3

APP_PID="$(adb -s "$EMU_SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n' || true)"
if [ -z "$APP_PID" ]; then
  echo "ERROR: $PKG is not running after normal launch!" >&2
  adb -s "$EMU_SERIAL" logcat -d | tail -n 120 >&2
  exit 1
fi
echo "    App alive (pid=$APP_PID)"

if adb -s "$EMU_SERIAL" logcat -d | grep -q "FATAL EXCEPTION"; then
  echo "ERROR: FATAL EXCEPTION detected after normal launch!" >&2
  adb -s "$EMU_SERIAL" logcat -d | grep -A 30 "FATAL EXCEPTION" >&2
  exit 1
fi

adb -s "$EMU_SERIAL" exec-out screencap -p > "$ARTIFACT_DIR/android_01_connect.png"
echo "    Saved screenshot: $ARTIFACT_DIR/android_01_connect.png ($(wc -c < "$ARTIFACT_DIR/android_01_connect.png") bytes)"

# Determine reachable target from emulator to Mac Host
TARGET="10.0.2.2:$MOCK_PORT"
echo "==> 5/7 Launching E2E auto-test intent (target=$TARGET, pin=$MOCK_PIN, app=com.tencent.xinWeChat)..."
adb -s "$EMU_SERIAL" logcat -c
adb -s "$EMU_SERIAL" shell am start -W -n "$ACTIVITY" \
  --es e2e_target "$TARGET" \
  --es e2e_pin "$MOCK_PIN" \
  --es e2e_app "com.tencent.xinWeChat" \
  --ez e2e_autotest true

echo "    Waiting up to 20s for full E2E pipeline & MediaCodec decode..."
ALL_OK=0
for i in $(seq 1 40); do
  adb -s "$EMU_SERIAL" logcat -d > "$LOGCAT_DUMP" 2>/dev/null || true

  if grep -q "FATAL EXCEPTION" "$LOGCAT_DUMP"; then
    echo "ERROR: FATAL EXCEPTION during E2E test!" >&2
    grep -A 40 "FATAL EXCEPTION" "$LOGCAT_DUMP" >&2
    exit 1
  fi

  HAS_CONN=0
  HAS_APPS=0
  HAS_START=0
  HAS_TOPO=0
  HAS_DECODE=0
  HAS_SENT=0
  HAS_EVENTS=0

  grep -Eq "connected to host|OpenUUE2E.*CONNECTED" "$LOGCAT_DUMP" && HAS_CONN=1 || true
  grep -Eq "list_apps_resp|LIST_APPS_RECEIVED" "$LOGCAT_DUMP" && HAS_APPS=1 || true
  grep -q '"type":"start_session"' "$MOCK_LOG" && HAS_START=1 || true
  grep -Eq "window_topology.*101.*102" "$LOGCAT_DUMP" && HAS_TOPO=1 || true
  grep -Eq "decoded_frames=([5-9]|[1-9][0-9]+)" "$LOGCAT_DUMP" && HAS_DECODE=1 || true
  grep -q "E2E_ALL_SENT" "$LOGCAT_DUMP" && HAS_SENT=1 || true

  if grep -q '"type":"mouse"' "$MOCK_LOG" \
    && grep -q '"event_type":3' "$MOCK_LOG" \
    && grep -q '"button":1' "$MOCK_LOG" \
    && grep -q '"type":"scroll"' "$MOCK_LOG" \
    && grep -q '你好，OpenUU 安卓端！' "$MOCK_LOG" \
    && grep -q '"key_code":8' "$MOCK_LOG" \
    && grep -q '"modifiers":8' "$MOCK_LOG" \
    && grep -q 'Hello from Android E2E' "$MOCK_LOG"; then
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

# Capture streaming screenshot regardless of whether assertions passed (helpful for debugging)
sleep 1
adb -s "$EMU_SERIAL" exec-out screencap -p > "$ARTIFACT_DIR/android_02_remote_stream.png"
echo "    Saved screenshot: $ARTIFACT_DIR/android_02_remote_stream.png ($(wc -c < "$ARTIFACT_DIR/android_02_remote_stream.png") bytes)"

adb -s "$EMU_SERIAL" logcat -d > "$LOGCAT_DUMP" 2>/dev/null || true

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

check_cond "Client connected (connected to host)" grep -q "connected to host" "$LOGCAT_DUMP"
check_cond "App list received (list_apps_resp)" grep -q "list_apps_resp" "$LOGCAT_DUMP"
check_cond "start_session received by mock-host" grep -q '"type":"start_session"' "$MOCK_LOG"
check_cond "window_topology received (101, 102)" grep -Eq "window_topology.*101.*102" "$LOGCAT_DUMP"
check_cond "MediaCodec decoded_frames >= 5" grep -Eq "decoded_frames=([5-9]|[1-9][0-9]+)" "$LOGCAT_DUMP"
check_cond "E2E_ALL_SENT logged" grep -q "E2E_ALL_SENT" "$LOGCAT_DUMP"
check_cond "mock-host MOCK_EVENT mouse" grep -q 'MOCK_EVENT.*"type":"mouse"' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT drag (event_type:3)" grep -Eq 'MOCK_EVENT.*"type":"mouse".*"event_type":3' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT right-click (button:1)" grep -Eq 'MOCK_EVENT.*"type":"mouse".*"button":1' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT scroll" grep -q 'MOCK_EVENT.*"type":"scroll"' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT text_commit (你好，OpenUU 安卓端！)" grep -q 'MOCK_EVENT.*"type":"text_commit".*你好，OpenUU 安卓端！' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT key (key_code:8, modifiers:8)" grep -Eq 'MOCK_EVENT.*"type":"key".*"key_code":8.*"modifiers":8' "$MOCK_LOG"
check_cond "mock-host MOCK_EVENT clipboard_sync (Hello from Android E2E)" grep -q 'MOCK_EVENT.*"type":"clipboard_sync".*Hello from Android E2E' "$MOCK_LOG"
check_cond "Zero FATAL EXCEPTION in logcat" bash -c "! grep -q 'FATAL EXCEPTION' '$LOGCAT_DUMP'"

if [ "$FAIL" -ne 0 ]; then
  echo "--- OpenUU logcat excerpt ---" >&2
  grep -E "OpenUU|MediaCodec|ACodec|CCodec|AndroidRuntime|DEBUG" "$LOGCAT_DUMP" | tail -n 100 >&2
  echo "--- mock-host log ---" >&2
  cat "$MOCK_LOG" >&2
  exit 1
fi

echo "==> 6b/7 Rotating emulator to Landscape & verifying Auto-Immersive Fullscreen..."
adb -s "$EMU_SERIAL" shell settings put secure immersive_mode_confirmations confirmed >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell settings put system user_rotation 1 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell cmd window user-rotation lock 1 >/dev/null 2>&1 || true
sleep 4.5
adb -s "$EMU_SERIAL" exec-out screencap -p > "$ARTIFACT_DIR/android_03_landscape_fullscreen.png"
LANDSCAPE_BYTES="$(wc -c < "$ARTIFACT_DIR/android_03_landscape_fullscreen.png" | tr -d ' ')"
LANDSCAPE_W="$(sips -g pixelWidth "$ARTIFACT_DIR/android_03_landscape_fullscreen.png" 2>/dev/null | awk '/pixelWidth:/ {print $2}')"
LANDSCAPE_H="$(sips -g pixelHeight "$ARTIFACT_DIR/android_03_landscape_fullscreen.png" 2>/dev/null | awk '/pixelHeight:/ {print $2}')"
echo "    Saved screenshot: $ARTIFACT_DIR/android_03_landscape_fullscreen.png (${LANDSCAPE_BYTES} bytes, ${LANDSCAPE_W}x${LANDSCAPE_H})"

if [ -z "$LANDSCAPE_W" ] || [ -z "$LANDSCAPE_H" ] || [ "$LANDSCAPE_W" -le "$LANDSCAPE_H" ]; then
  echo "    [FAIL] Landscape screenshot is not in landscape orientation (${LANDSCAPE_W}x${LANDSCAPE_H})!" >&2
  exit 1
fi
echo "    [PASS] Landscape screenshot verified (${LANDSCAPE_W}x${LANDSCAPE_H}, width > height)"

if adb -s "$EMU_SERIAL" logcat -d | grep -q "FATAL EXCEPTION"; then
  echo "    [FAIL] FATAL EXCEPTION detected after rotating to landscape fullscreen!" >&2
  adb -s "$EMU_SERIAL" logcat -d | grep -A 30 "FATAL EXCEPTION" >&2
  exit 1
fi
echo "    [PASS] Zero FATAL EXCEPTION during landscape auto-immersive fullscreen"

# Restore portrait rotation cleanly
adb -s "$EMU_SERIAL" shell settings put system user_rotation 0 >/dev/null 2>&1 || true
adb -s "$EMU_SERIAL" shell cmd window user-rotation lock 0 >/dev/null 2>&1 || true
sleep 1

echo "==> 7/7 Testing passwordless Trusted Peer reconnect (empty PIN)..."
adb -s "$EMU_SERIAL" shell am force-stop "$PKG"
sleep 1
adb -s "$EMU_SERIAL" logcat -c
adb -s "$EMU_SERIAL" shell "am start -W -n '$ACTIVITY' --es e2e_target '$TARGET' --es e2e_pin ''"

RECONN_OK=0
for i in $(seq 1 30); do
  adb -s "$EMU_SERIAL" logcat -d > "$LOGCAT_RECONNECT" 2>/dev/null || true
  if grep -q "FATAL EXCEPTION" "$LOGCAT_RECONNECT"; then
    echo "ERROR: FATAL EXCEPTION during Trusted Peer reconnect!" >&2
    grep -A 30 "FATAL EXCEPTION" "$LOGCAT_RECONNECT" >&2
    exit 1
  fi
  if grep -q "connected to host" "$LOGCAT_RECONNECT"; then
    RECONN_OK=1
    echo "    [PASS] Passwordless Trusted Peer reconnect succeeded at t=$((i/2))s!"
    break
  fi
  sleep 0.5
done

if [ "$RECONN_OK" -ne 1 ]; then
  echo "    [FAIL] Passwordless Trusted Peer reconnect did not succeed!" >&2
  grep -E "OpenUU|AndroidRuntime" "$LOGCAT_RECONNECT" | tail -n 80 >&2
  tail -n 40 "$MOCK_LOG" >&2
  exit 1
fi

echo "==> 7b/7 Testing Iroh WAN ticket connect (rustls-platform-verifier + zero SIGABRT)..."
LOGCAT_WAN="/tmp/openuu_android_wan.log"
rm -f "$LOGCAT_WAN"
if [ -n "$MOCK_TICKET" ]; then
  adb -s "$EMU_SERIAL" shell am force-stop "$PKG"
  sleep 1
  adb -s "$EMU_SERIAL" logcat -c
  adb -s "$EMU_SERIAL" shell "am start -W -n '$ACTIVITY' --es e2e_target '$MOCK_TICKET' --es e2e_pin '$MOCK_PIN'"
  WAN_EXERCISED=0
  for i in $(seq 1 20); do
    adb -s "$EMU_SERIAL" logcat -d > "$LOGCAT_WAN" 2>/dev/null || true
    if grep -Eq "FATAL EXCEPTION|Fatal signal|SIGABRT|Expect rustls-platform-verifier" "$LOGCAT_WAN"; then
      echo "    [FAIL] Native crash / panic detected during Iroh WAN ticket connect!" >&2
      grep -E -A 25 "FATAL EXCEPTION|Fatal signal|SIGABRT|rustls-platform-verifier" "$LOGCAT_WAN" | tail -n 80 >&2
      exit 1
    fi
    if grep -q "openuu_init_android_tls returned 0" "$LOGCAT_WAN" \
       && grep -Eq "正在建立跨网加密连接|connected to host" "$LOGCAT_WAN"; then
      WAN_EXERCISED=1
      # Let iroh + rustls-platform-verifier complete TLS/relay handshake attempt for 2s to ensure zero delayed SIGABRT
      sleep 2
      adb -s "$EMU_SERIAL" logcat -d > "$LOGCAT_WAN" 2>/dev/null || true
      break
    fi
    sleep 0.5
  done

  if grep -Eq "FATAL EXCEPTION|Fatal signal|SIGABRT|Expect rustls-platform-verifier" "$LOGCAT_WAN"; then
    echo "    [FAIL] Delayed native crash / panic during Iroh WAN ticket connect!" >&2
    grep -E -A 25 "FATAL EXCEPTION|Fatal signal|SIGABRT|rustls-platform-verifier" "$LOGCAT_WAN" | tail -n 80 >&2
    exit 1
  fi
  WAN_PID="$(adb -s "$EMU_SERIAL" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n' || true)"
  if [ "$WAN_EXERCISED" -ne 1 ] || [ -z "$WAN_PID" ]; then
    echo "    [FAIL] Iroh WAN ticket connect check failed (exercised=$WAN_EXERCISED pid=$WAN_PID)" >&2
    grep -E "OpenUU|rustls|AndroidRuntime|DEBUG" "$LOGCAT_WAN" | tail -n 80 >&2
    exit 1
  fi
  echo "    [PASS] openuu_init_android_tls=0 + Iroh/rustls-platform-verifier exercised with ZERO crash (pid=$WAN_PID)"
else
  echo "    [WARN] MOCK_TICKET empty; skipping ticket check"
fi

echo ""
echo "============================================================"
echo " ALL ANDROID E2E ACCEPTANCE CHECKS PASSED!"
echo " Screenshots:"
echo "   - $ARTIFACT_DIR/android_01_connect.png"
echo "   - $ARTIFACT_DIR/android_02_remote_stream.png"
echo "   - $ARTIFACT_DIR/android_03_landscape_fullscreen.png"
echo "============================================================"

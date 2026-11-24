#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "0.7.2")"
APP_BUILD="702"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PATH"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/openuu-clang-cache}"

if [ -f "$ROOT_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env.local"
  set +a
fi

echo "==> 1/3 Building openuu-core (Rust release staticlib)..."
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p openuu-core --release --offline

echo "==> 2/3 Building OpenUUApp (macOS Swift release)..."
swift build \
  --disable-sandbox \
  --cache-path /tmp/openuu-spm-cache \
  --package-path "$ROOT_DIR/apps/macos" \
  -c release

BIN_PATH="$(swift build --disable-sandbox --cache-path /tmp/openuu-spm-cache --package-path "$ROOT_DIR/apps/macos" -c release --show-bin-path)/OpenUUApp"
APP_DIR="$ROOT_DIR/build/OpenUU.app"

echo "==> 3/3 Packaging standalone $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/zh-Hant.lproj" "$APP_DIR/Contents/Resources/en.lproj"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/OpenUU"
if [ -f "$ROOT_DIR/apps/macos/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/apps/macos/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" << 'EOF'
"CFBundleDisplayName" = "OpenUU";
"CFBundleName" = "OpenUU";
"NSLocalNetworkUsageDescription" = "OpenUU 需要在局域网内自动发现并连接你的另一台 Mac。";
"NSScreenCaptureUsageDescription" = "OpenUU 需要屏幕录制权限以实时捕获你选择的单个应用窗口。";
"NSAudioCaptureUsageDescription" = "OpenUU 需要系统音频采集权限，以便在远控时将应用声音传到控制端并自动静音被控电脑外放。";
EOF

cat > "$APP_DIR/Contents/Resources/zh-Hant.lproj/InfoPlist.strings" << 'EOF'
"CFBundleDisplayName" = "OpenUU";
"CFBundleName" = "OpenUU";
"NSLocalNetworkUsageDescription" = "OpenUU 需要在區域網路內自動發現並連接你的另一台 Mac。";
"NSScreenCaptureUsageDescription" = "OpenUU 需要螢幕錄製權限以即時擷取你選擇的單個應用程式視窗。";
"NSAudioCaptureUsageDescription" = "OpenUU 需要系統音訊擷取權限，以便在遠端控制時將應用程式聲音傳至控制端並自動靜音被控電腦喇叭。";
EOF

cat > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings" << 'EOF'
"CFBundleDisplayName" = "OpenUU";
"CFBundleName" = "OpenUU";
"NSLocalNetworkUsageDescription" = "OpenUU needs local network access to discover and connect to your other Mac.";
"NSScreenCaptureUsageDescription" = "OpenUU needs Screen Recording permission to stream the application windows you select.";
"NSAudioCaptureUsageDescription" = "OpenUU needs System Audio Recording permission to stream remote app audio and mute the host speaker while connected.";
EOF

cat > "$APP_DIR/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>zh-Hans</string>
        <string>zh-Hant</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>OpenUU</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundleIdentifier</key>
    <string>ren.onekb.openuu</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>OpenUU</string>
    <key>CFBundleDisplayName</key>
    <string>OpenUU</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${APP_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>OpenUU needs local network access to discover and connect to your other Mac.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_openuu._udp</string>
    </array>
    <key>NSScreenCaptureUsageDescription</key>
    <string>OpenUU needs Screen Recording permission to stream the application windows you select.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>OpenUU needs System Audio Recording permission to stream remote app audio and mute the host speaker while connected.</string>
</dict>
</plist>
EOF

SIGN_ID="${OPENUU_CODESIGN_IDENTITY:-}"
if [ -z "$SIGN_ID" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  SIGN_ID="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(printf '%s\n' "$IDENTITIES" | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)"
  fi
  if [ -z "$SIGN_ID" ] && printf '%s\n' "$IDENTITIES" | grep -q "OpenUU Local Signer"; then
    SIGN_ID="OpenUU Local Signer"
  fi
fi

if [ -n "$SIGN_ID" ]; then
  echo "==> Signing with persistent certificate: $SIGN_ID"
  codesign --force --deep --sign "$SIGN_ID" "$APP_DIR"
else
  echo "==> WARNING: No persistent code-signing certificate found; falling back to ad-hoc signing (TCC permissions will reset on rebuild)."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Done! Standalone app created at:"
echo "    $APP_DIR"
echo "    Double-click it in Finder, drag to /Applications, or copy to your other Mac."

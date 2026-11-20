#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PATH"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/chameye-clang-cache}"

echo "==> 1/3 Building chameye-core (Rust release staticlib)..."
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p chameye-core --release --offline

echo "==> 2/3 Building ChameyeApp (macOS Swift release)..."
swift build \
  --disable-sandbox \
  --cache-path /tmp/chameye-spm-cache \
  --package-path "$ROOT_DIR/apps/macos" \
  -c release

BIN_PATH="$(swift build --disable-sandbox --cache-path /tmp/chameye-spm-cache --package-path "$ROOT_DIR/apps/macos" -c release --show-bin-path)/ChameyeApp"
APP_DIR="$ROOT_DIR/build/Chameye.app"

echo "==> 3/3 Packaging standalone $APP_DIR ..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources/zh-Hans.lproj" "$APP_DIR/Contents/Resources/en.lproj"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Chameye"
if [ -f "$ROOT_DIR/apps/macos/Resources/AppIcon.icns" ]; then
  cp "$ROOT_DIR/apps/macos/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Resources/zh-Hans.lproj/InfoPlist.strings" << 'EOF'
"CFBundleDisplayName" = "一眸";
"CFBundleName" = "一眸";
EOF

cat > "$APP_DIR/Contents/Resources/en.lproj/InfoPlist.strings" << 'EOF'
"CFBundleDisplayName" = "Chameye";
"CFBundleName" = "Chameye";
EOF

cat > "$APP_DIR/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>Chameye</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSHasLocalizedDisplayName</key>
    <true/>
    <key>CFBundleIdentifier</key>
    <string>com.chameye.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Chameye</string>
    <key>CFBundleDisplayName</key>
    <string>Chameye</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Chameye 需要在局域网内自动发现并连接你的另一台 Mac。</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_chameye._udp</string>
    </array>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Chameye 需要屏幕录制权限以实时捕获你选择的单个应用窗口。</string>
</dict>
</plist>
EOF

SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Chameye Local Signer"; then
  SIGN_ID="Chameye Local Signer"
  echo "==> Signing with persistent certificate: $SIGN_ID"
fi
codesign --force --deep --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Done! Standalone app created at:"
echo "    $APP_DIR"
echo "    Double-click it in Finder, drag to /Applications, or copy to your other Mac."

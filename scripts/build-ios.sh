#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PATH"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/openuu-clang-cache}"

if [ -f "$ROOT_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env.local"
  set +a
fi

SIM_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --sim-only)
      SIM_ONLY=true
      ;;
    *)
      echo "Unknown argument: $arg (supported: --sim-only)" >&2
      exit 1
      ;;
  esac
done

export IPHONEOS_DEPLOYMENT_TARGET=17.0

IOS_DIR="$ROOT_DIR/apps/ios"
FRAMEWORKS_DIR="$IOS_DIR/Frameworks"
XCFW_PATH="$FRAMEWORKS_DIR/OpenUUCore.xcframework"
HEADERS_STAGE="/tmp/openuu-ios-headers"
DERIVED_DATA="/tmp/openuu-ios-derived"

echo "==> 1/5 Building openuu-core (Rust release staticlib) for iOS..."
echo "    -> target aarch64-apple-ios-sim"
cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p openuu-core --release --target aarch64-apple-ios-sim

SIM_LIB="$ROOT_DIR/target/aarch64-apple-ios-sim/release/libopenuu_core.a"
if [ ! -f "$SIM_LIB" ]; then
  echo "ERROR: Missing simulator staticlib at $SIM_LIB" >&2
  exit 1
fi

DEV_LIB="$ROOT_DIR/target/aarch64-apple-ios/release/libopenuu_core.a"
if [ "$SIM_ONLY" = false ]; then
  echo "    -> target aarch64-apple-ios"
  cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p openuu-core --release --target aarch64-apple-ios
  if [ ! -f "$DEV_LIB" ]; then
    echo "ERROR: Missing device staticlib at $DEV_LIB" >&2
    exit 1
  fi
fi

echo "==> 2/5 Staging headers and creating OpenUUCore.xcframework..."
rm -rf "$HEADERS_STAGE" "$XCFW_PATH"
mkdir -p "$HEADERS_STAGE" "$FRAMEWORKS_DIR"
cp "$ROOT_DIR/crates/openuu-core/include/openuu_core.h" "$HEADERS_STAGE/openuu_core.h"
cat > "$HEADERS_STAGE/module.modulemap" << 'EOF'
module COpenUUCore {
    header "openuu_core.h"
    export *
}
EOF

XCFW_ARGS=(
  -create-xcframework
  -library "$SIM_LIB"
  -headers "$HEADERS_STAGE"
)
if [ "$SIM_ONLY" = false ] || [ -f "$DEV_LIB" ]; then
  XCFW_ARGS+=(
    -library "$DEV_LIB"
    -headers "$HEADERS_STAGE"
  )
fi
XCFW_ARGS+=(-output "$XCFW_PATH")
xcodebuild "${XCFW_ARGS[@]}"

echo "==> 3/5 Syncing official brand icons and generating OpenUUMobile.xcodeproj..."
if [ -f "$ROOT_DIR/scripts/sync-brand-icons.swift" ]; then
  swift "$ROOT_DIR/scripts/sync-brand-icons.swift"
fi

python3 "$IOS_DIR/generate_xcodeproj.py"

mkdir -p "$ROOT_DIR/build"

echo "==> 4/5 Building OpenUUMobile for iOS Simulator (arm64)..."
xcodebuild \
  -project "$IOS_DIR/OpenUUMobile.xcodeproj" \
  -scheme OpenUUMobile \
  -configuration Release \
  -sdk iphonesimulator \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build

SIM_APP_SRC="$DERIVED_DATA/Build/Products/Release-iphonesimulator/OpenUUMobile.app"
SIM_APP_DST="$ROOT_DIR/build/OpenUUMobile-Sim.app"
if [ ! -d "$SIM_APP_SRC" ]; then
  echo "ERROR: Expected Simulator .app not found at $SIM_APP_SRC" >&2
  exit 1
fi
rm -rf "$SIM_APP_DST"
cp -R "$SIM_APP_SRC" "$SIM_APP_DST"
echo "    -> Simulator app ready: $SIM_APP_DST"

if [ "$SIM_ONLY" = false ]; then
  echo "==> 5/5 Building OpenUUMobile for iOS Device (arm64)..."
  xcodebuild \
    -project "$IOS_DIR/OpenUUMobile.xcodeproj" \
    -scheme OpenUUMobile \
    -configuration Release \
    -sdk iphoneos \
    -derivedDataPath "$DERIVED_DATA" \
    ARCHS=arm64 \
    CODE_SIGNING_ALLOWED=NO \
    build

  DEV_APP_SRC="$DERIVED_DATA/Build/Products/Release-iphoneos/OpenUUMobile.app"
  DEV_APP_DST="$ROOT_DIR/build/OpenUUMobile-iOS.app"
  if [ ! -d "$DEV_APP_SRC" ]; then
    echo "ERROR: Expected Device .app not found at $DEV_APP_SRC" >&2
    exit 1
  fi
  rm -rf "$DEV_APP_DST"
  cp -R "$DEV_APP_SRC" "$DEV_APP_DST"
  echo "    -> Device app ready: $DEV_APP_DST"
else
  echo "==> 5/5 Skipped Device build (--sim-only)"
fi

echo "==> Done! Build outputs:"
ls -ld "$ROOT_DIR/build/OpenUUMobile-"*.app

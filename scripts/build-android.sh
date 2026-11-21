#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$HOME/.rustup/toolchains/stable-aarch64-apple-darwin/bin:$HOME/.cargo/bin:$PATH"
export JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export ANDROID_SDK_ROOT="$ANDROID_HOME"

NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"
NDK_DIR="$ANDROID_HOME/ndk/$NDK_VERSION"
TOOLCHAIN_BIN="$NDK_DIR/toolchains/llvm/prebuilt/darwin-x86_64/bin"
GRADLE_BIN="${GRADLE_BIN:-$HOME/.gradle/wrapper/dists/gradle-8.14-all/c2qonpi39x1mddn7hk5gh9iqj/gradle-8.14/bin/gradle}"

if [ -f "$ROOT_DIR/.env.local" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env.local"
  set +a
fi

ALL_ABIS=false
for arg in "$@"; do
  case "$arg" in
    --all-abis)
      ALL_ABIS=true
      ;;
  esac
done

if [ -n "${ANDROID_ABIS:-}" ]; then
  IFS=',' read -r -a ABIS <<< "$ANDROID_ABIS"
elif [ "$ALL_ABIS" = true ]; then
  ABIS=("arm64-v8a" "x86_64")
else
  ABIS=("arm64-v8a" "x86_64")
fi

if [ ! -d "$TOOLCHAIN_BIN" ]; then
  echo "ERROR: Android NDK toolchain not found at $TOOLCHAIN_BIN" >&2
  exit 1
fi

if [ ! -x "$GRADLE_BIN" ]; then
  if command -v gradle >/dev/null 2>&1; then
    GRADLE_BIN="$(command -v gradle)"
  else
    echo "ERROR: Gradle binary not found at $GRADLE_BIN" >&2
    exit 1
  fi
fi

# Configure NDK clang / llvm-ar for Cargo & cc-rs / ring (API 26)
export CC_aarch64_linux_android="$TOOLCHAIN_BIN/aarch64-linux-android26-clang"
export CXX_aarch64_linux_android="$TOOLCHAIN_BIN/aarch64-linux-android26-clang++"
export AR_aarch64_linux_android="$TOOLCHAIN_BIN/llvm-ar"
export RANLIB_aarch64_linux_android="$TOOLCHAIN_BIN/llvm-ranlib"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$TOOLCHAIN_BIN/aarch64-linux-android26-clang"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$TOOLCHAIN_BIN/llvm-ar"

export CC_x86_64_linux_android="$TOOLCHAIN_BIN/x86_64-linux-android26-clang"
export CXX_x86_64_linux_android="$TOOLCHAIN_BIN/x86_64-linux-android26-clang++"
export AR_x86_64_linux_android="$TOOLCHAIN_BIN/llvm-ar"
export RANLIB_x86_64_linux_android="$TOOLCHAIN_BIN/llvm-ranlib"
export CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER="$TOOLCHAIN_BIN/x86_64-linux-android26-clang"
export CARGO_TARGET_X86_64_LINUX_ANDROID_AR="$TOOLCHAIN_BIN/llvm-ar"

export PATH="$TOOLCHAIN_BIN:$PATH"

JNI_STATIC_ROOT="$ROOT_DIR/apps/android/app/src/main/jniLibs-static"
mkdir -p "$JNI_STATIC_ROOT"

ABI_CSV=""
echo "==> 1/3 Building openuu-core (Rust release staticlib) for ABIs: ${ABIS[*]} ..."
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a)
      TRIPLE="aarch64-linux-android"
      ;;
    x86_64)
      TRIPLE="x86_64-linux-android"
      ;;
    *)
      echo "ERROR: Unsupported Android ABI: $abi (supported: arm64-v8a, x86_64)" >&2
      exit 1
      ;;
  esac

  echo "    -> cargo build -p openuu-core --release --target $TRIPLE"
  cargo build --manifest-path "$ROOT_DIR/Cargo.toml" -p openuu-core --release --target "$TRIPLE"

  SRC_LIB="$ROOT_DIR/target/$TRIPLE/release/libopenuu_core.a"
  if [ ! -f "$SRC_LIB" ]; then
    echo "ERROR: Expected staticlib not found: $SRC_LIB" >&2
    exit 1
  fi

  mkdir -p "$JNI_STATIC_ROOT/$abi"
  cp "$SRC_LIB" "$JNI_STATIC_ROOT/$abi/libopenuu_core.a"
  echo "    -> Copied $SRC_LIB -> $JNI_STATIC_ROOT/$abi/libopenuu_core.a"

  if [ -z "$ABI_CSV" ]; then
    ABI_CSV="$abi"
  else
    ABI_CSV="$ABI_CSV,$abi"
  fi
done

echo "==> 2/3 Building Android APK via Gradle (ABIs: $ABI_CSV)..."
cat > "$ROOT_DIR/apps/android/local.properties" << EOF
sdk.dir=$ANDROID_HOME
EOF

"$GRADLE_BIN" \
  --no-daemon \
  -p "$ROOT_DIR/apps/android" \
  -PopenuuAbis="$ABI_CSV" \
  assembleDebug

APK_SRC="$ROOT_DIR/apps/android/app/build/outputs/apk/debug/app-debug.apk"
APK_DST="$ROOT_DIR/build/OpenUU-Android.apk"
if [ ! -f "$APK_SRC" ]; then
  echo "ERROR: Expected APK not found at $APK_SRC" >&2
  exit 1
fi

echo "==> 3/3 Copying APK to $APK_DST ..."
mkdir -p "$ROOT_DIR/build"
cp "$APK_SRC" "$APK_DST"
ls -lh "$APK_DST"
echo "==> Done! Android APK ready at $APK_DST"

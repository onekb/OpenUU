#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
REL_DIR="$ROOT_DIR/build/release-v${VERSION}"

for required in \
  "$ROOT_DIR/build/OpenUU.app" \
  "$ROOT_DIR/build/OpenUU-Android.apk" \
  "$ROOT_DIR/build/OpenUUMobile-iOS.app"
do
  if [ ! -e "$required" ]; then
    echo "ERROR: Missing build output: $required" >&2
    echo "Run build-macos.sh, ANDROID_ABIS=arm64-v8a build-android.sh, and build-ios.sh first." >&2
    exit 1
  fi
done

rm -rf "$REL_DIR"
mkdir -p "$REL_DIR"

echo "==> 1/4 Packaging OpenUU-v${VERSION}-macOS-arm64.dmg ..."
DMG_STAGE="$(mktemp -d "/tmp/openuu-dmg-stage.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
ditto "$ROOT_DIR/build/OpenUU.app" "$DMG_STAGE/OpenUU.app"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
  -volname "OpenUU v${VERSION}" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  "$REL_DIR/OpenUU-v${VERSION}-macOS-arm64.dmg"

echo "==> 2/4 Copying OpenUU-v${VERSION}-Android-arm64.apk ..."
cp "$ROOT_DIR/build/OpenUU-Android.apk" "$REL_DIR/OpenUU-v${VERSION}-Android-arm64.apk"

echo "==> 3/4 Packaging OpenUU-v${VERSION}-iOS-unsigned.ipa ..."
IPA_STAGE="$(mktemp -d "/tmp/openuu-ipa-stage.XXXXXX")"
mkdir -p "$IPA_STAGE/Payload"
ditto "$ROOT_DIR/build/OpenUUMobile-iOS.app" "$IPA_STAGE/Payload/OpenUUMobile.app"
(
  cd "$IPA_STAGE"
  ditto -c -k --sequesterRsrc --keepParent "Payload" "$REL_DIR/OpenUU-v${VERSION}-iOS-unsigned.ipa"
)
rm -rf "$IPA_STAGE"

if [ -f "$ROOT_DIR/build/OpenUU-Windows-x64.zip" ]; then
  echo "==> Including OpenUU-v${VERSION}-Windows-x64.zip ..."
  cp "$ROOT_DIR/build/OpenUU-Windows-x64.zip" "$REL_DIR/OpenUU-v${VERSION}-Windows-x64.zip"
fi

echo "==> 4/4 Generating SHA256SUMS.txt ..."
(
  cd "$REL_DIR"
  shasum -a 256 OpenUU-v${VERSION}-* > SHA256SUMS.txt
  cat SHA256SUMS.txt
)

ls -lh "$REL_DIR"
echo "==> Release artifacts ready in $REL_DIR"

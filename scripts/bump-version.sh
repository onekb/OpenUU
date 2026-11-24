#!/usr/bin/env bash
# Synchronizes OpenUU's semantic version & integer build number across Cargo, macOS, Windows, Android, iOS, and Web.
# Usage: ./scripts/bump-version.sh <semver> [build_number]
# Example: ./scripts/bump-version.sh 0.7.0 7

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"

NEW_VER="${1:-}"
if [ -z "$NEW_VER" ]; then
  if [ -f "$VERSION_FILE" ]; then
    NEW_VER="$(tr -d '[:space:]' < "$VERSION_FILE")"
  else
    echo "Usage: $0 <X.Y.Z> [build_number]" >&2
    exit 1
  fi
fi

# Strip optional leading 'v'
NEW_VER="${NEW_VER#v}"
if ! [[ "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "ERROR: Version '$NEW_VER' must be X.Y.Z (e.g. 0.7.0)" >&2
  exit 1
fi

IFS='.' read -r V_MAJOR V_MINOR V_PATCH <<< "$NEW_VER"
DEFAULT_BUILD=$(( V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH ))
if [ "$V_MAJOR" -eq 0 ] && [ "$V_PATCH" -eq 0 ]; then
  DEFAULT_BUILD="$V_MINOR"
fi
BUILD_NUM="${2:-$DEFAULT_BUILD}"

echo "==> Syncing OpenUU version -> v${NEW_VER} (build ${BUILD_NUM})"
printf '%s\n' "$NEW_VER" > "$VERSION_FILE"

PY_BIN="python3"
if ! command -v "$PY_BIN" >/dev/null 2>&1 || ! "$PY_BIN" -c "import sys" >/dev/null 2>&1; then
  PY_BIN="python"
fi

"$PY_BIN" - "$ROOT_DIR" "$NEW_VER" "$BUILD_NUM" << 'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
ver = sys.argv[2]
build = sys.argv[3]

def replace_in(rel_path: str, replacements: list[tuple[str, str]]) -> None:
    p = root / rel_path
    if not p.exists():
        return
    txt = p.read_text(encoding="utf-8")
    orig = txt
    for pat, repl in replacements:
        txt = re.sub(pat, repl, txt, flags=re.MULTILINE)
    if txt != orig:
        p.write_text(txt, encoding="utf-8")
        print(f"    updated {rel_path}")

# 1. Cargo workspace
replace_in("Cargo.toml", [
    (r'(^\[workspace\.package\][\s\S]*?^version\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])

# 2. macOS script & AppUpdater fallback
replace_in("scripts/build-macos.sh", [
    (r'^APP_VERSION="\$\(tr -d \x27\[:space:\]\x27 < "\$ROOT_DIR/VERSION" 2>/dev/null \|\| echo "[^"]*"\)"', f'APP_VERSION="$(tr -d \'[:space:]\' < "$ROOT_DIR/VERSION" 2>/dev/null || echo "{ver}")"'),
    (r'(<key>CFBundleShortVersionString</key>\s*<string>)[^<]+(</string>)', rf'\g<1>${{APP_VERSION}}\2'),
    (r'(<key>CFBundleVersion</key>\s*<string>)[^<]+(</string>)', rf'\g<1>${{APP_BUILD}}\2'),
    (r'^APP_BUILD="[^"]*"', f'APP_BUILD="{build}"'),
])
replace_in("apps/macos/Sources/OpenUUApp/Shared/AppUpdater.swift", [
    (r'(static\s+let\s+fallback\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])

# 3. Windows csproj, manifest, XAML, AppUpdater, Inno Setup, and scripts
replace_in("apps/windows/OpenUUApp/OpenUUApp.csproj", [
    (r'(<Version>)[0-9]+\.[0-9]+\.[0-9]+(</Version>)', rf'\g<1>{ver}\2'),
])
replace_in("apps/windows/OpenUUApp/app.manifest", [
    (r'(assemblyIdentity\s+version=")[0-9]+\.[0-9]+\.[0-9]+\.0(")', rf'\g<1>{ver}.0\2'),
])
replace_in("apps/windows/OpenUUApp/Shared/AppUpdater.cs", [
    (r'(public\s+const\s+string\s+Fallback\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])
replace_in("apps/windows/OpenUUApp/Views/MainWindow.xaml", [
    (r'(x:Name="SidebarVersionText"\s+Text=")v[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>v{ver}\2'),
    (r'(x:Name="SettingsCurrentVerText"\s+Text="当前客户端版本：)v[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>v{ver}\2'),
])
replace_in("apps/windows/installer/OpenUU.iss", [
    (r'(#define\s+MyAppVersion\s+")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])
replace_in("scripts/build-windows.ps1", [
    (r'(\$appVersion\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
    (r'OpenUU-Windows-v[0-9]+\.[0-9]+\.[0-9]+', f'OpenUU-Windows-v{ver}'),
])
replace_in("scripts/verify-windows-e2e.ps1", [
    (r'OpenUU-Windows-v[0-9]+\.[0-9]+\.[0-9]+', f'OpenUU-Windows-v{ver}'),
])

# 4. Android Gradle & AppUpdater fallback
replace_in("apps/android/app/build.gradle.kts", [
    (r'(versionCode\s*=\s*)[0-9]+', rf'\g<1>{build}'),
    (r'(versionName\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])
replace_in("apps/android/app/src/main/java/ren/onekb/openuu/AppUpdater.kt", [
    (r'(BuildConfig\.VERSION_NAME\.ifBlank\s*\{\s*")[0-9]+\.[0-9]+\.[0-9]+("\s*\})', rf'\g<1>{ver}\2'),
])

# 5. iOS Info.plist, MobileAppUpdater & generate_xcodeproj.py
replace_in("apps/ios/Info.plist", [
    (r'(<key>CFBundleShortVersionString</key>\s*<string>)[0-9]+\.[0-9]+\.[0-9]+(</string>)', rf'\g<1>{ver}\2'),
    (r'(<key>CFBundleVersion</key>\s*<string>)[0-9]+(</string>)', rf'\g<1>{build}\2'),
])
replace_in("apps/ios/Sources/MobileAppUpdater.swift", [
    (r'(static\s+let\s+fallback\s*=\s*")[0-9]+\.[0-9]+\.[0-9]+(")', rf'\g<1>{ver}\2'),
])
])
replace_in("apps/ios/generate_xcodeproj.py", [
    (r'(CURRENT_PROJECT_VERSION\s*=\s*)[0-9]+(;)', rf'\g<1>{build}\2'),
    (r'(MARKETING_VERSION\s*=\s*)[0-9]+\.[0-9]+\.[0-9]+(;)', rf'\g<1>{ver}\2'),
])

# 6. Cloudflare Worker Landing Page fallback version & download links
replace_in("deploy/cloudflare-worker/public/index.html", [
    (r'(<b data-ver>)v[0-9]+\.[0-9]+\.[0-9]+(</b>)', rf'\g<1>v{ver}\2'),
    (r'(<span data-ver>)v[0-9]+\.[0-9]+\.[0-9]+(</span>)', rf'\g<1>v{ver}\2'),
    (r'releases/download/v[0-9]+\.[0-9]+\.[0-9]+/OpenUU-v[0-9]+\.[0-9]+\.[0-9]+-', f'releases/download/v{ver}/OpenUU-v{ver}-'),
])
replace_in("deploy/cloudflare-worker/public/app.js", [
    (r'Fallback to v[0-9]+\.[0-9]+\.[0-9]+ built-in URLs', f'Fallback to v{ver} built-in URLs'),
])
replace_in("deploy/cloudflare-worker/src/index.js", [
    (r'OpenUU-Coord-Worker/[0-9]+\.[0-9]+\.[0-9]+', f'OpenUU-Coord-Worker/{ver}'),
])
PY

if [ -f "$ROOT_DIR/apps/ios/generate_xcodeproj.py" ]; then
  "$PY_BIN" "$ROOT_DIR/apps/ios/generate_xcodeproj.py" >/dev/null
  echo "    regenerated apps/ios/OpenUUMobile.xcodeproj"
fi

echo "==> Version sync complete: v${NEW_VER} (build ${BUILD_NUM})"

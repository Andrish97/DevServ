#!/usr/bin/env bash
set -euo pipefail

# Usage:
#  ./build.sh [--force-update-caddy] [--use-cached-caddy] [--no-port]
#  (GUI przekazuje flagi)

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

APP_NAME="DevSrv"
BUNDLE_ID="local.devsrv" # możesz potem spiąć w Info.plist, tu tylko informacyjnie
SRC_SWIFT="DevSrv.swift"
SRC_PLIST="Info.plist"
ICON_SVG="icon.svg"

OUT_DIR="$HERE/build"
APP_DIR="$OUT_DIR/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
MINVER="12.0"

CACHE_DIR="$HERE/.cache/devsrv"
CADDY_CACHE_DIR="$CACHE_DIR/caddy"
CADDY_UNIVERSAL="$RES/caddy"

FORCE_UPDATE=0
USE_CACHED=1
NO_PORT=0

log(){ echo "@@LOG $*"; }
pct(){ echo "@@PERCENT $1"; }
step_ok(){ echo "@@STEP ok \"$1\""; }
step_err(){ echo "@@STEP err \"$1\""; }

die(){
  step_err "$1"
  log "ERROR: $1"
  log "Tip: uruchom ./build.sh --help albo sprawdź brakujące narzędzia z komunikatu wyżej."
  exit 1
}

need_file(){ [[ -f "$1" ]] || die "Missing file: $1"; }
need_cmd(){
  command -v "$1" >/dev/null 2>&1 || die "Missing tool: $1. Fix: $2"
}

usage() {
  cat <<'USAGE'
DevSrv build helper

Usage:
  ./build.sh [--force-update-caddy] [--use-cached-caddy] [--no-port]
  ./build.sh --help

Options:
  --force-update-caddy   ignore cache and download latest Caddy release again
  --use-cached-caddy     prefer cached Caddy build (default)
  --no-port              keep compatibility flag used by GUI
  --help                 show this help

Examples:
  ./build.sh
  ./build.sh --force-update-caddy
USAGE
}

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-update-caddy) FORCE_UPDATE=1; USE_CACHED=0; shift ;;
    --use-cached-caddy)   USE_CACHED=1; FORCE_UPDATE=0; shift ;;
    --no-port)            NO_PORT=1; shift ;;
    --help|-h)            usage; exit 0 ;;
    *) usage; die "Unknown arg: $1" ;;
  esac
done

pct 2
step_ok "Start"

log "Working dir: $HERE"
if [[ $FORCE_UPDATE -eq 1 ]]; then
  log "Caddy mode: force update (latest release will be downloaded)"
elif [[ $USE_CACHED -eq 1 ]]; then
  log "Caddy mode: use cache when available"
else
  log "Caddy mode: download when cache is missing"
fi

# ---- checks ----
pct 6
need_file "$SRC_SWIFT"
need_file "$SRC_PLIST"
need_file "$ICON_SVG"

need_cmd xcrun  "Install Xcode Command Line Tools: xcode-select --install"
need_cmd swiftc "Install Xcode Command Line Tools: xcode-select --install"
need_cmd lipo   "Install Xcode Command Line Tools: xcode-select --install"
need_cmd sips   "macOS should have it (built-in)."
need_cmd iconutil "macOS should have it (built-in)."
need_cmd curl   "macOS should have it (built-in)."
need_cmd tar    "macOS should have it (built-in)."
need_cmd codesign "macOS should have it (built-in)."

# python3 used for parsing GitHub API (you asked to detect)
if ! command -v python3 >/dev/null 2>&1; then
  die "Missing tool: python3. Fix: brew install python (or install via python.org)."
fi

step_ok "Tooling"
pct 12

# ---- make dirs ----
rm -rf "$OUT_DIR"
mkdir -p "$MACOS" "$RES"
mkdir -p "$CACHE_DIR" "$CADDY_CACHE_DIR"

# ---- icon: svg -> png -> icns ----
pct 18
step_ok "Icon"

TMP_ICON="$OUT_DIR/tmp_icon"
mkdir -p "$TMP_ICON"
BASE_PNG="$TMP_ICON/icon_1024.png"

# Prefer rsvg-convert/inkscape, fallback: error with guidance
if command -v rsvg-convert >/dev/null 2>&1; then
  rsvg-convert -w 1024 -h 1024 "$ICON_SVG" -o "$BASE_PNG"
elif command -v inkscape >/dev/null 2>&1; then
  inkscape "$ICON_SVG" --export-type=png --export-filename="$BASE_PNG" -w 1024 -h 1024 >/dev/null 2>&1
else
  die "Missing SVG converter (rsvg-convert or inkscape). Fix: brew install librsvg"
fi

ICONSET="$TMP_ICON/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

sizes=(16 32 64 128 256 512 1024)
for sz in "${sizes[@]}"; do
  sips -z "$sz" "$sz" "$BASE_PNG" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null
done

cp "$ICONSET/icon_32x32.png"       "$ICONSET/icon_16x16@2x.png"
cp "$ICONSET/icon_64x64.png"       "$ICONSET/icon_32x32@2x.png"
cp "$ICONSET/icon_256x256.png"     "$ICONSET/icon_128x128@2x.png"
cp "$ICONSET/icon_512x512.png"     "$ICONSET/icon_256x256@2x.png"
cp "$ICONSET/icon_1024x1024.png"   "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

# ---- Info.plist ----
pct 24
step_ok "Info.plist"
cp -f "$SRC_PLIST" "$CONTENTS/Info.plist"

# ---- build universal app binary ----
pct 34
step_ok "Compile app"

TMP_BIN="$OUT_DIR/tmp_bin"
mkdir -p "$TMP_BIN"

xcrun --sdk macosx swiftc "$SRC_SWIFT" -O -sdk "$SDK" \
  -target "arm64-apple-macos${MINVER}" -framework Cocoa \
  -o "$TMP_BIN/${APP_NAME}_arm64"

xcrun --sdk macosx swiftc "$SRC_SWIFT" -O -sdk "$SDK" \
  -target "x86_64-apple-macos${MINVER}" -framework Cocoa \
  -o "$TMP_BIN/${APP_NAME}_x86_64"

lipo -create -output "$MACOS/$APP_NAME" \
  "$TMP_BIN/${APP_NAME}_arm64" "$TMP_BIN/${APP_NAME}_x86_64"

chmod +x "$MACOS/$APP_NAME"

# ---- download caddy w cache + universal lipo ----
pct 55
step_ok "Caddy"

# Determine latest release + asset urls
LATEST_JSON="$(curl -fsSL "https://api.github.com/repos/caddyserver/caddy/releases/latest")"

VERSION="$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d.get("tag_name","latest"))' "$LATEST_JSON")"

CACHE_VER_DIR="$CADDY_CACHE_DIR/$VERSION"
AMD_TGZ="$CACHE_VER_DIR/caddy_amd64.tar.gz"
ARM_TGZ="$CACHE_VER_DIR/caddy_arm64.tar.gz"
AMD_BIN="$CACHE_VER_DIR/amd64/caddy"
ARM_BIN="$CACHE_VER_DIR/arm64/caddy"
UNIV_BIN="$CACHE_VER_DIR/caddy_universal"

mkdir -p "$CACHE_VER_DIR"

url_amd="$(python3 -c 'import json,re,sys; d=json.loads(sys.argv[1]);
for a in d.get("assets",[]):
 n=a.get("name","");
 if re.search(r"_darwin_amd64\.tar\.gz$", n):
  print(a.get("browser_download_url",""));
  break' "$LATEST_JSON")"
url_arm="$(python3 -c 'import json,re,sys; d=json.loads(sys.argv[1]);
for a in d.get("assets",[]):
 n=a.get("name","");
 if re.search(r"_darwin_arm64\.tar\.gz$", n):
  print(a.get("browser_download_url",""));
  break' "$LATEST_JSON")"

[[ -n "$url_amd" && -n "$url_arm" ]] || die "Could not resolve Caddy download URLs (GitHub API)."

need_download=0
if [[ $FORCE_UPDATE -eq 1 ]]; then
  need_download=1
elif [[ $USE_CACHED -eq 1 && -f "$UNIV_BIN" ]]; then
  need_download=0
else
  need_download=1
fi

if [[ $need_download -eq 1 ]]; then
  rm -rf "$CACHE_VER_DIR/amd64" "$CACHE_VER_DIR/arm64"
  mkdir -p "$CACHE_VER_DIR/amd64" "$CACHE_VER_DIR/arm64"
  log "Downloading Caddy $VERSION (amd64)…"
  curl -fL "$url_amd" -o "$AMD_TGZ"
  log "Downloading Caddy $VERSION (arm64)…"
  curl -fL "$url_arm" -o "$ARM_TGZ"
  tar -xzf "$AMD_TGZ" -C "$CACHE_VER_DIR/amd64"
  tar -xzf "$ARM_TGZ" -C "$CACHE_VER_DIR/arm64"
  [[ -f "$AMD_BIN" && -f "$ARM_BIN" ]] || die "Caddy archives extracted, but binaries missing."
  chmod +x "$AMD_BIN" "$ARM_BIN"
  lipo -create -output "$UNIV_BIN" "$AMD_BIN" "$ARM_BIN"
  chmod +x "$UNIV_BIN"
else
  log "Using cached Caddy: $UNIV_BIN"
fi

cp -f "$UNIV_BIN" "$CADDY_UNIVERSAL"
chmod +x "$CADDY_UNIVERSAL"

# ---- (placeholder) no-port note ----
# Tu w kolejnym kroku zepniemy to z Twoją logiką:
# - no-port -> potrzebne admin (bind 80/443 lub LaunchDaemon)
# Na razie tylko sygnalizujemy w logu.
pct 78
if [[ $NO_PORT -eq 1 ]]; then
  log "No-port mode enabled: will require admin privileges at runtime (planned)."
else
  log "Port mode: user-space (planned)."
fi
step_ok "Config"

# ---- sign + unquarantine ----
pct 90
step_ok "Signing"
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
if command -v xattr >/dev/null 2>&1; then
  xattr -dr com.apple.quarantine "$APP_DIR" 2>/dev/null || true
fi

pct 100
step_ok "Done"
log "Build finished successfully"
log "App artifact: $APP_DIR"
log "Tip: force fresh Caddy with ./build.sh --force-update-caddy"
echo "@@ARTIFACT_PATH $APP_DIR"
echo "@@DONE"

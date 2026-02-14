#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

LOG_DIR="$HERE/build"
mkdir -p "$LOG_DIR"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/build-$TS.log"

print_menu() {
  cat <<'MENU'
[DevSrv] Wybierz tryb buildu:
  1) Normal build (użyj cache Caddy, jeśli dostępny)
  2) Force Caddy update (pobierz najnowszą wersję od nowa)
  3) Exit
MENU
}

choose_args_interactive() {
  local choice
  while true; do
    print_menu
    read -r -p "[DevSrv] Twój wybór [1-3]: " choice
    case "$choice" in
      1)
        BUILD_ARGS=(--use-cached-caddy)
        echo "[DevSrv] Wybrano: normal build"
        return 0
        ;;
      2)
        BUILD_ARGS=(--force-update-caddy)
        echo "[DevSrv] Wybrano: force update Caddy"
        return 0
        ;;
      3)
        echo "[DevSrv] Przerwano przez użytkownika."
        exit 0
        ;;
      *)
        echo "[DevSrv] Nieprawidłowy wybór. Spróbuj ponownie."
        ;;
    esac
  done
}

BUILD_ARGS=("$@")
if [[ ${#BUILD_ARGS[@]} -eq 0 && -t 0 ]]; then
  choose_args_interactive
fi

echo "[DevSrv] 🚀 Start build..."
echo "[DevSrv] 📝 Log: $LOG_FILE"

touch "$LOG_FILE"
if bash ./build.sh "${BUILD_ARGS[@]}" 2>&1 | tee "$LOG_FILE"; then
  echo "[DevSrv] ✅ Build OK"
  echo "[DevSrv] 📦 App: $HERE/build/DevSrv.app"
else
  echo "[DevSrv] ❌ Build FAILED"
  echo "[DevSrv] 🔎 Check log: $LOG_FILE"
  exit 1
fi

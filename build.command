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

draw_progress() {
  local percent="$1"
  local step="$2"
  local width=34
  local filled=$(( percent * width / 100 ))
  local empty=$(( width - filled ))
  local green=$'\033[32m'
  local cyan=$'\033[36m'
  local reset=$'\033[0m'
  local bar
  local pad

  printf -v bar "%*s" "$filled" ""
  bar="${bar// /█}"
  printf -v pad "%*s" "$empty" ""
  pad="${pad// /░}"

  printf "\r[DevSrv] ${cyan}[%s%s]${reset} ${green}%3d%%%s %s" "$bar" "$pad" "$percent" "$reset" "$step"
}

clear_progress_line() {
  printf "\r\033[2K"
}

process_build_output() {
  local line
  local percent=0
  local step="Start"
  local progress_visible=0

  while IFS= read -r line; do
    if [[ "$line" == @@PERCENT* ]]; then
      percent="${line#@@PERCENT }"
      draw_progress "$percent" "$step"
      progress_visible=1
    elif [[ "$line" == @@STEP* ]]; then
      local desc
      desc="$(printf '%s' "$line" | sed -E 's/^@@STEP [^ ]+ "(.*)"$/\1/')"
      step="$desc"
      draw_progress "$percent" "$step"
      progress_visible=1
    elif [[ "$line" == @@LOG* ]]; then
      if [[ "$progress_visible" -eq 1 ]]; then
        clear_progress_line
      fi
      printf "[DevSrv] %s\n" "${line#@@LOG }"
      draw_progress "$percent" "$step"
      progress_visible=1
    elif [[ "$line" == @@ARTIFACT_PATH* || "$line" == @@DONE ]]; then
      :
    else
      if [[ "$progress_visible" -eq 1 ]]; then
        clear_progress_line
      fi
      printf "%s\n" "$line"
      draw_progress "$percent" "$step"
      progress_visible=1
    fi
  done

  draw_progress 100 "Done"
  printf "\n"
}

BUILD_ARGS=("$@")
if [[ ${#BUILD_ARGS[@]} -eq 0 && -t 0 ]]; then
  choose_args_interactive
fi

echo "[DevSrv] 🚀 Start build..."
echo "[DevSrv] 📝 Log: $LOG_FILE"

touch "$LOG_FILE"
if bash ./build.sh "${BUILD_ARGS[@]}" 2>&1 | tee "$LOG_FILE" | process_build_output; then
  echo "[DevSrv] ✅ Build OK"
  echo "[DevSrv] 📦 App: $HERE/build/DevSrv.app"
else
  echo "[DevSrv] ❌ Build FAILED"
  echo "[DevSrv] 🔎 Check log: $LOG_FILE"
  exit 1
fi

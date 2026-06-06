#!/usr/bin/env bash
#
# Cross-platform end-to-end validation for capture-helper.
#
#   bash scripts/e2e/validate.sh            # Linux: self-contained Xvfb sandbox; macOS: TextEdit window
#   E2E_USE_DISPLAY=real bash scripts/e2e/validate.sh   # Linux: use the current $DISPLAY instead of Xvfb
#   CAPTURE_HELPER=/usr/local/bin/capture-helper bash scripts/e2e/validate.sh   # validate an installed binary
#
# It builds the native backend if missing, provisions a capturable window, runs
# scripts/e2e/harness.js (doctor/list/resolve/snapshot/record/stream --framed), and
# exits non-zero if any check fails.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS="$ROOT/scripts/e2e/harness.js"

log() { printf '\033[36m[e2e]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[e2e] %s\033[0m\n' "$*" >&2; exit 1; }

command -v node >/dev/null 2>&1 || die "node not found on PATH"

run_linux() {
  if [ -z "${CAPTURE_HELPER:-}" ] && [ ! -x "$ROOT/native/x11-grabber" ]; then
    log "building x11-grabber (postinstall)"
    node "$ROOT/scripts/postinstall.js" || true
    [ -x "$ROOT/native/x11-grabber" ] || die "x11-grabber not built — run: bash scripts/setup-linux-node.sh"
  fi

  if [ "${E2E_USE_DISPLAY:-}" = "real" ]; then
    [ -n "${DISPLAY:-}" ] || die "E2E_USE_DISPLAY=real but \$DISPLAY is unset"
    log "validating against current DISPLAY=$DISPLAY"
    node "$HARNESS"; exit $?
  fi

  for b in Xvfb openbox xclock xeyes; do
    command -v "$b" >/dev/null 2>&1 || die "sandbox needs '$b' — install: sudo apt install -y xvfb x11-apps openbox"
  done

  local n=99
  while [ -e "/tmp/.X${n}-lock" ]; do n=$((n + 1)); done
  local disp=":$n"
  log "starting Xvfb sandbox on $disp"
  Xvfb "$disp" -screen 0 1280x720x24 >/tmp/e2e-xvfb.log 2>&1 & local xvfb=$!
  sleep 2
  DISPLAY="$disp" openbox >/tmp/e2e-openbox.log 2>&1 & local wm=$!
  sleep 1
  DISPLAY="$disp" xclock -update 1 -geometry 640x480+20+20 >/dev/null 2>&1 & local a1=$!
  DISPLAY="$disp" xeyes -geometry 320x240+700+20 >/dev/null 2>&1 & local a2=$!
  sleep 2

  cleanup() { kill "$a1" "$a2" "$wm" "$xvfb" 2>/dev/null; }
  trap cleanup EXIT

  DISPLAY="$disp" node "$HARNESS"
  local rc=$?
  cleanup; trap - EXIT
  exit $rc
}

run_macos() {
  if [ -z "${CAPTURE_HELPER:-}" ] && [ ! -x "$ROOT/native/capture-helper" ] && [ ! -x "$ROOT/.build/release/capture-helper" ]; then
    command -v swift >/dev/null 2>&1 || die "no native binary and swift toolchain not found"
    log "building native capture-helper (swift build -c release)"
    ( cd "$ROOT" && swift build -c release ) || die "swift build failed"
  fi

  log "opening a TextEdit window to capture (grant Screen Recording to your terminal if prompted)"
  osascript -e 'tell application "TextEdit" to activate' \
            -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
  sleep 2

  E2E_TARGET_APP="TextEdit" E2E_TARGET_NAME="Untitled" node "$HARNESS"
  exit $?
}

case "$(uname -s)" in
  Linux)  run_linux ;;
  Darwin) run_macos ;;
  *)      die "unsupported OS: $(uname -s)" ;;
esac

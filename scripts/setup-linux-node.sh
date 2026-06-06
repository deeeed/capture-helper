#!/usr/bin/env bash
#
# Prepare a Linux node for capture-helper (X11 per-window capture).
# Idempotent: installs build/runtime deps, compiles the grabber, and reports
# whether a usable Xorg desktop session is available.
#
# Usage: bash scripts/setup-linux-node.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> capture-helper Linux setup"

# 1. Dependencies
PKGS="gcc ffmpeg libx11-dev libxcomposite-dev libxdamage-dev libxfixes-dev libxext-dev"
echo "--> installing: $PKGS"
if command -v apt-get >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS
else
  echo "!! non-apt distro: install equivalents of: $PKGS" >&2
fi

# 2. Compile the grabber
echo "--> compiling x11-grabber"
mkdir -p "$ROOT/native"
gcc -O2 -o "$ROOT/native/x11-grabber" "$ROOT/src/linux/x11-grabber.c" -lX11 -lXcomposite -lXext
echo "    built $ROOT/native/x11-grabber"

# 3. Session diagnostics
echo "--> session check"
# `|| true`: under `set -euo pipefail`, a no-match grep here must not abort the script.
SESS_TYPE="$(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}' | while read -r s; do
  loginctl show-session "$s" -p Type -p Class -p Active 2>/dev/null | tr '\n' ' '; echo
done | grep 'Class=user' | grep 'Active=yes' | grep -oE 'Type=[a-z]+' | head -1 | cut -d= -f2 || true)"

case "${SESS_TYPE:-none}" in
  x11)     echo "    OK: active Xorg user session detected" ;;
  wayland) echo "    WARN: active session is Wayland — per-window capture needs Xorg." ;
           echo "          Log into 'Ubuntu on Xorg' (or set WaylandEnable=false in /etc/gdm3/custom.conf)." ;;
  *)       echo "    WARN: no active graphical user session found." ;
           echo "          A logged-in Xorg desktop is required (GDM autologin + Xorg session)." ;;
esac

echo "==> done. Verify with: DISPLAY=:0 node bin/capture-helper.js doctor --json"

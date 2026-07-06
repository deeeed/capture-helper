#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <path-to-binary>" >&2
  exit 2
fi

bin="$1"
if [ ! -f "$bin" ]; then
  echo "binary not found: $bin" >&2
  exit 1
fi

identity="${CAPTURE_HELPER_CODESIGN_IDENTITY:--}"
extra=()
if [ -n "${CAPTURE_HELPER_CODESIGN_KEYCHAIN:-}" ]; then
  extra+=(--keychain "$CAPTURE_HELPER_CODESIGN_KEYCHAIN")
fi

codesign --force --options runtime --timestamp=none "${extra[@]}" -s "$identity" "$bin"
codesign -dv --verbose=2 "$bin" >&2
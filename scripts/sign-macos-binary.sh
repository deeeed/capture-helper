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
if [ -n "${CAPTURE_HELPER_CODESIGN_KEYCHAIN:-}" ]; then
  codesign --force --options runtime --timestamp=none \
    --keychain "$CAPTURE_HELPER_CODESIGN_KEYCHAIN" \
    -s "$identity" "$bin"
else
  codesign --force --options runtime --timestamp=none -s "$identity" "$bin"
fi
codesign -dv --verbose=2 "$bin" >&2
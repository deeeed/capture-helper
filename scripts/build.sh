#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64

release_bin=""
for candidate in \
  .build/apple/Products/Release/capture-helper \
  .build/release/capture-helper; do
  if [ -f "$candidate" ]; then
    release_bin="$candidate"
    break
  fi
done

if [ -z "$release_bin" ]; then
  echo "release binary not found after swift build" >&2
  exit 1
fi

mkdir -p native
cp "$release_bin" native/capture-helper
chmod +x native/capture-helper
bash scripts/sign-macos-binary.sh native/capture-helper
shasum -a 256 native/capture-helper | awk '{print $1}' > native/capture-helper.sha256
echo "Built: $(pwd)/native/capture-helper ($(lipo -info native/capture-helper))"
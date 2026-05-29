#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p native
cp .build/release/capture-helper native/capture-helper
echo "Built: $(pwd)/native/capture-helper"

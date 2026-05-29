# Farmslot integration notes

This repository is the intended standalone home for the helper currently living under Farmslot's `tools/capture-helper/`.

Recommended Farmslot integration path:

1. Build or install this project independently.
2. Point Farmslot at it with `CAPTURE_HELPER_PATH`.
3. Keep slot/resource/simulator resolution inside Farmslot gateway code.
4. Prefer `capture-helper list --json` + `--window-id` over title-only matching when the gateway can resolve a stable window id.
5. Record the helper version/path in recipe evidence artifacts.

Example:

```bash
cd ~/dev/@siteed/capture-helper
npm run build:native

cd ~/dev/farmslot
CAPTURE_HELPER_PATH=$HOME/dev/@siteed/capture-helper/native/capture-helper \
  bash scripts/record-window.sh --pid 12345 --output /tmp/evidence.mp4
```

Use `resolve` to debug Farmslot resource-to-window mapping before opening a stream:

```bash
~/dev/@siteed/capture-helper/native/capture-helper resolve \
  --app-name Simulator \
  --window-name mm-1
```

Use `snapshot` when a recipe needs a lightweight still image instead of video:

```bash
~/dev/@siteed/capture-helper/native/capture-helper snapshot \
  --window-id 12345 \
  --output /tmp/evidence.png
```

Standalone MP4 recording is also available:

```bash
~/dev/@siteed/capture-helper/native/capture-helper list --json
~/dev/@siteed/capture-helper/native/capture-helper record \
  --window-id 12345 \
  --duration 5 \
  --output /tmp/evidence.mp4
```

Do not move Farmslot-specific concepts into this project. If this project needs a new selector, keep it generic, for example `--window-id`, richer `list` metadata, or `doctor` diagnostics.

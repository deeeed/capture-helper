# Farmslot integration notes

This repository is the intended standalone home for the helper currently living under Farmslot's `tools/capture-helper/`.

Recommended Farmslot integration path:

1. Build or install this project independently.
2. Point Farmslot at it with `CAPTURE_HELPER_PATH`.
3. Keep any slot/resource/simulator resolution inside Farmslot gateway code.
4. Record the helper binary version/path in evidence artifacts when recipes capture video.

Example:

```bash
cd ~/dev/@siteed/capture-helper
npm run build:native

cd ~/dev/farmslot
CAPTURE_HELPER_PATH=$HOME/dev/@siteed/capture-helper/native/capture-helper \
  bash scripts/record-window.sh --pid 12345 --output /tmp/evidence.mp4
```

Do not move Farmslot-specific concepts into this project. If this project needs a new selector, keep it generic, for example `--window-id`, richer `--list-windows` metadata, or a structured `doctor` command.

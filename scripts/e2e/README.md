# End-to-end validation

Self-contained checks that exercise the real `capture-helper` CLI on the current
platform and assert real outputs (valid PNG, non-empty MP4 with frames, framed H.264
with a keyframe). Run them after a checkout to confirm capture actually works.

```bash
npm run e2e
# or
bash scripts/e2e/validate.sh
```

What it does per platform:

- **Linux** — builds the X11 grabber if missing, then spins up a throwaway `Xvfb`
  sandbox with test windows (`xclock`, `xeyes`), runs the harness against it, and tears
  it down. No real desktop or root needed. Requires `xvfb x11-apps openbox`
  (`sudo apt install -y xvfb x11-apps openbox`).
  To validate against the real logged-in desktop instead: `E2E_USE_DISPLAY=real npm run e2e`.
- **macOS** — builds the Swift binary if missing, opens a TextEdit window, and runs the
  harness against it. Grant **Screen Recording** to your terminal/IDE first (the harness
  will otherwise report a `doctor` failure).

Validate an already-installed binary instead of the repo build:

```bash
CAPTURE_HELPER=/usr/local/bin/capture-helper npm run e2e
```

The harness (`harness.js`) runs `version`, `doctor`, `list`, `resolve`, `snapshot`,
`record`, and `stream --framed`, printing PASS/FAIL per check and exiting non-zero on any
failure. Override the target window with `E2E_TARGET_APP` + `E2E_TARGET_NAME`, or
`E2E_TARGET_NAME` alone; otherwise it auto-picks the largest capturable window.

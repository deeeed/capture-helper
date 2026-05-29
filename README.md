# @siteed/capture-helper

Generic macOS window capture helper for agents, automation tools, and evidence pipelines.

`capture-helper` is a small Swift CLI built on ScreenCaptureKit. It discovers macOS windows, captures exact window targets, streams H.264 Annex B bytes, and records MP4 evidence through `ffmpeg`.

## Status

Early standalone extraction from Farmslot's internal `tools/capture-helper`.

The CLI is intentionally generic. Product-specific concepts such as Farmslot slots, iOS simulator aliases, MetaMask runners, or recipe semantics belong in the caller.

## Requirements

- macOS 13.0+
- Xcode command-line tools / Swift toolchain
- Screen Recording permission for the terminal or parent app
- Optional: `ffmpeg` for `record` mode

## Install / build

From source:

```bash
swift build -c release
# or
npm run build:native
```

The npm build script copies the release binary to:

```text
native/capture-helper
```

When installed as an npm package, `postinstall` attempts to build the native Swift binary if the packaged binary is missing or unusable. Set `SITEED_CAPTURE_HELPER_SKIP_POSTINSTALL=1` to skip that step.

## Commands

```bash
# Version / provenance
capture-helper version
capture-helper --version

# Environment readiness and permissions diagnostics
capture-helper doctor --json

# List windows as a machine-readable JSON object
capture-helper list --json

# Legacy JSON-lines listing
capture-helper --list-windows
capture-helper list --json-lines

# Capture a specific target as raw H.264 Annex B
capture-helper capture --window-id 12345 > /tmp/capture.h264
capture-helper capture --pid 12345 > /tmp/capture.h264
capture-helper capture --app-name Simulator --window-name "mm-1" > /tmp/capture.h264

# Legacy capture syntax remains supported
capture-helper --window-name "Simulator" > /tmp/capture.h264

# Framed multi-window stream with stdin control
capture-helper stream --framed --window-id 12345 > /tmp/windows.h264

# Record MP4 evidence with ffmpeg
capture-helper record --window-id 12345 --duration 5 --output evidence.mp4
```

## Resolve and snapshot

`resolve` lets agents debug target selection before starting video capture:

```bash
capture-helper resolve --app-name "Google Chrome" --window-name "MetaMask"
```

It returns the selected window, selector type, and all candidates considered for that selector.

`snapshot` captures a one-frame PNG using the same target selectors:

```bash
capture-helper snapshot --window-id 12345 --output screenshot.png
```

## Target selectors

Prefer selectors in this order:

1. `--window-id` from `capture-helper list --json` for exact capture.
2. `--pid` when the caller owns the process tree and wants the largest suitable window.
3. `--app-name` + `--window-name` for human-friendly fallback matching.
4. `--window-name` alone only for ad hoc use.

## npm wrapper

This package exposes a Node wrapper so JavaScript-based agents can call the native binary through a normal `bin` entry:

```bash
node bin/capture-helper.js doctor --json
```

The wrapper resolves the binary in this order:

1. `SITEED_CAPTURE_HELPER_BIN`
2. `native/capture-helper`
3. `.build/release/capture-helper`
4. `/opt/homebrew/bin/capture-helper`
5. `/usr/local/bin/capture-helper`

## Output contract

- raw capture stdout: H.264 Annex B byte stream
  - 4-byte start codes: `00 00 00 01`
  - SPS/PPS emitted before keyframes
  - baseline profile, no B-frames
- `list` / `doctor` / `version`: JSON on stdout by default
- streaming/capture diagnostics: JSON lines on stderr
- command failures: JSON error lines on stderr with stable `code` values such as `target_required` and `window_not_found`
- signal handling: `SIGINT`/`SIGTERM` perform cleanup for direct capture; `record --duration` stops automatically

See [docs/protocol.md](docs/protocol.md) for the framed stream and event contract.

## Permissions

Grant Screen Recording permission to the terminal app, IDE, or agent host that launches the helper:

**System Settings → Privacy & Security → Screen Recording**

After granting permission, restart the launching app. Use this to check readiness:

```bash
capture-helper doctor --json
```

## Integration principle

Keep this tool generic:

- good: window IDs, PIDs, app names, window titles, capture formats, diagnostics
- bad: Farmslot slots, project resources, simulator naming conventions, MetaMask-specific selectors

Higher-level tools should resolve their domain objects to a concrete macOS window target, then call `capture-helper`.

## Development

```bash
swift build -c release
swift test # includes subprocess CLI/error-shape tests
npm run build:native
npm run doctor
npm pack --dry-run
```

## Release

See [docs/release.md](docs/release.md).

## License

MIT

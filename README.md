# @siteed/capture-helper

Generic window capture helper for agents, automation tools, and evidence pipelines — macOS (ScreenCaptureKit) and Linux/X11 (XComposite + ffmpeg).

On macOS, `capture-helper` is a small Swift CLI built on ScreenCaptureKit: it discovers windows, captures exact window targets, streams H.264 Annex B bytes, and records MP4 evidence with a native AVFoundation writer (no ffmpeg). On Linux it reproduces the same CLI/protocol over X11 using an XComposite grabber plus ffmpeg — see [Linux support](#linux-support).

## Status

Early standalone extraction from Farmslot's internal `tools/capture-helper`.

The CLI is intentionally generic. Product-specific concepts such as Farmslot slots, iOS simulator aliases, MetaMask runners, or recipe semantics belong in the caller.

## Requirements

- macOS 13.0+ (Apple Silicon or Intel)
- Screen Recording permission for the terminal or parent app
- Optional: `ffmpeg` for external workflows that still want it; macOS `record` and `record --framed` session snapshots are native.
- Swift/Xcode is only required when building from source — the published npm package and Homebrew formula ship a prebuilt universal binary.

## Linux support

On Linux the same CLI/protocol is implemented by a Node backend that drives a small
C grabber (XComposite per-window capture) and `ffmpeg` for H.264 encoding. The
`capture-helper` command auto-dispatches to it on Linux; commands, flags, the framed
stream protocol, and JSON events are identical to macOS (see [docs/protocol.md](docs/protocol.md)).

Requirements:

- **X11 (Xorg) session.** GNOME-on-Wayland per-window capture is portal-gated and
  not automatable — log into an Xorg session (e.g. "Ubuntu on Xorg", or set
  `WaylandEnable=false` in `/etc/gdm3/custom.conf`). A graphical desktop must be
  logged in (the GDM greeter has no app windows; use autologin for headless nodes).
- **Captured apps must be X11 clients** (Wayland-native surfaces are invisible to the
  X path). Force X11 where needed: `GDK_BACKEND=x11`, `QT_QPA_PLATFORM=xcb`,
  Electron `--ozone-platform=x11`.
- **Build/runtime deps** (`ffmpeg` is required on Linux):

  ```bash
  sudo apt install -y gcc ffmpeg libx11-dev libxcomposite-dev libxdamage-dev libxfixes-dev libxext-dev
  # or run the helper:
  bash scripts/setup-linux-node.sh
  ```

Hardware H.264 encoding is opt-in via `--encoder h264_nvenc` (or
`CAPTURE_HELPER_ENCODER=h264_nvenc`); the default `libx264` works everywhere.
Verify readiness with `capture-helper doctor --json`. On Linux, `id` values are X11
window ids (XIDs).

## Install

Use with `npx` without installing globally:

```bash
npx -y @siteed/capture-helper@latest doctor --json
npx -y @siteed/capture-helper@latest list --json
```

Install globally with npm (primary path used by Farmslot and MetaMask farm installers):

```bash
npm install -g @siteed/capture-helper
capture-helper doctor --human
```

Install with Homebrew (auto-taps `deeeed/tap`; no separate tap step):

```bash
brew install deeeed/tap/capture-helper
capture-helper doctor --human
```

Use `doctor --json` when a script or installer needs machine-readable output (Farmslot
and farm installers parse that form). Humans should prefer `doctor --human`.

Download the native release binary directly:

```bash
curl -L https://github.com/deeeed/capture-helper/releases/latest/download/capture-helper-darwin-universal \
  -o /usr/local/bin/capture-helper
chmod +x /usr/local/bin/capture-helper
xattr -d com.apple.quarantine /usr/local/bin/capture-helper 2>/dev/null || true
```

If macOS Gatekeeper blocks a curl-downloaded binary, prefer `npm install -g` or
`brew install deeeed/tap/capture-helper` — those paths do not attach quarantine. For a
manual download, remove quarantine with `xattr -d` (above) or approve once in System
Settings → Privacy & Security.

## Build from source

```bash
swift build -c release
# or
npm run build:native
```

The npm build script copies the release binary to:

```text
native/capture-helper
```

When installed as an npm package, `postinstall` verifies the bundled native binary
(smoke test + SHA256 checksum). On macOS, if the prebuilt binary is missing or broken
and Swift is available, it rebuilds from source; otherwise install **fails loudly** with
the next command to run (`brew install deeeed/tap/capture-helper` or retry npm). On
Linux it compiles the X11 grabber (`native/x11-grabber`) via `gcc` when possible. Set
`SITEED_CAPTURE_HELPER_SKIP_POSTINSTALL=1` to skip postinstall.

## Commands

```bash
# Human default: list likely capturable windows
capture-helper
capture-helper -l

# Version / provenance
capture-helper version
capture-helper --version

# Environment readiness and permissions diagnostics
capture-helper doctor --human
capture-helper doctor --json   # machine-readable; default when --json omitted
# includes stable codes like screen_recording_denied, window_server_unavailable, ffmpeg_missing

# Request/open macOS Screen Recording permissions where possible
capture-helper permissions
capture-helper doctor --open-permissions --json

# List windows as a machine-readable JSON object
capture-helper list --json

# Human-readable table
capture-helper list --human
capture-helper -l
capture-helper list -h
capture-helper list --on-screen --capturable --human
capture-helper list --all --human

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

# Record MP4 evidence (macOS: native AVFoundation, no ffmpeg; Linux: ffmpeg)
capture-helper record --window-id 12345 --duration 5 --output evidence.mp4 --open

# Record MP4 plus PNG proof frames from the same macOS native recording stream
{ sleep 1; echo "snapshot step-1.png"; echo stop; } | \
  capture-helper record --framed --window-id 12345 --output evidence.mp4
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

**System Settings → Privacy & Security → Screen & System Audio Recording**

After granting permission, restart the launching app. Use this to check readiness:

```bash
capture-helper doctor --json
```

If you see `Code=-3801` / `screen_recording_denied`, especially over SSH, see [docs/troubleshooting.md](docs/troubleshooting.md).

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

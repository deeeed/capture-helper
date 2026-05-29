# @siteed/capture-helper

Generic macOS window capture helper for agents, automation tools, and evidence pipelines.

`capture-helper` is a small Swift CLI built on ScreenCaptureKit. It discovers macOS windows and streams H.264 Annex B bytes to stdout. In framed mode it can multiplex multiple windows and accept dynamic stdin commands, making it useful for agent UIs, validation recipes, visual QA, and recording wrappers.

## Status

Early standalone extraction from Farmslot's internal `tools/capture-helper`.

Current CLI is intentionally low-level and generic. Product-specific concepts such as Farmslot slots, iOS simulator aliases, MetaMask runners, or recipe semantics belong in the caller.

## Requirements

- macOS 13.0+
- Xcode command-line tools / Swift toolchain
- Screen Recording permission for the terminal or parent app
- Optional: `ffmpeg` for recording stdout into MP4

## Build

```bash
swift build -c release
# or
npm run build:native
```

The npm build script copies the release binary to:

```text
native/capture-helper
```

## Usage

```bash
# List available windows as JSON lines on stderr
capture-helper --list-windows

# Capture a window by title substring
capture-helper --window-name "Simulator" > /tmp/capture.h264

# Restrict title matching to an app
capture-helper --app-name Simulator --window-name "mm-1" > /tmp/capture.h264

# Capture the largest suitable window owned by a PID
capture-helper --pid 12345 > /tmp/capture.h264

# Tune frame rate and size
capture-helper --pid 12345 --max-fps 15 --max-size 720 > /tmp/capture.h264

# Framed multi-window mode with stdin commands
capture-helper --framed --window-name "Simulator" > /tmp/windows.h264
```

### npm wrapper

This package exposes a Node wrapper so JavaScript-based agents can call the native binary through a normal `bin` entry:

```bash
node bin/capture-helper.js --list-windows
```

The wrapper resolves the binary in this order:

1. `SITEED_CAPTURE_HELPER_BIN`
2. `native/capture-helper`
3. `.build/release/capture-helper`
4. `/opt/homebrew/bin/capture-helper`
5. `/usr/local/bin/capture-helper`

## Output contract

- stdout: raw H.264 Annex B byte stream
  - 4-byte start codes: `00 00 00 01`
  - SPS/PPS emitted before keyframes
  - baseline profile, no B-frames
- stderr: JSON events / diagnostics
- signal handling: `SIGINT`/`SIGTERM` perform clean shutdown

See [docs/protocol.md](docs/protocol.md) for the framed stream and event contract.

## Permissions

Grant Screen Recording permission to the terminal app, IDE, or agent host that launches the helper:

**System Settings → Privacy & Security → Screen Recording**

After granting permission, restart the launching app.

## Integration principle

Keep this tool generic:

- good: window IDs, PIDs, app names, window titles, capture formats, diagnostics
- bad: Farmslot slots, project resources, simulator naming conventions, MetaMask-specific selectors

Higher-level tools should resolve their domain objects to a concrete macOS window target, then call `capture-helper`.

## License

License is intentionally undecided during extraction. Set a public license before publishing outside local/private use.

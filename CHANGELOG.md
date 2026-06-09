# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.1] - 2026-06-09

### Added

- `record --framed` on macOS now accepts `snapshot <path>` and `stop` stdin commands, so automation can write PNG proof frames from the active recording stream without starting a second ScreenCaptureKit capture.
- `version --json` now reports the `record_session_snapshot` capability for protocol consumers.

## [0.2.0] - 2026-06-06

### Added

- **Linux (X11) support.** The same CLI and protocol as macOS, implemented without
  Swift: a Node backend drives a small C grabber (`src/linux/x11-grabber.c`) that does
  occlusion-correct per-window capture via XComposite + XShm, piped into `ffmpeg` for
  H.264. `libx264` by default; `--encoder h264_nvenc` (or `CAPTURE_HELPER_ENCODER`)
  opt-in for hardware encoding. Requires an Xorg session with X11 client apps.
- **Platform-generic backend.** A shared core (`bin/backend.js`) plus a per-platform
  adapter (`bin/platforms/<platform>.js`) and native grabber, so additional platforms
  (e.g. Windows via Windows.Graphics.Capture) reuse the orchestration with no core
  changes. macOS keeps its native ScreenCaptureKit/AVFoundation binary.
- **End-to-end validation harness** (`scripts/e2e/`, `npm run e2e`). Cross-platform:
  a self-contained `Xvfb` sandbox on Linux, a TextEdit window on macOS. Asserts
  `version`/`doctor`/`list`/`resolve`/`snapshot`/`record`/`stream --framed`, including
  decoding the framed H.264.
- `scripts/setup-linux-node.sh` to install dependencies and build the grabber on a node.
- Linux `doctor` checks (`session_type`, `display_available`, `xcomposite_present`,
  `grabber_compiled`, `ffmpeg_present`, `window_enumeration_ok`) sharing the macOS JSON
  shape and `summary.requiredFailureCodes`.
- Update notice: `doctor`/`version` print a one-line hint to stderr when a newer npm
  release is available (cross-platform, best-effort, 24h-cached, short timeout). Disable
  with `--no-update-check` or `CAPTURE_HELPER_SKIP_UPDATE_CHECK=1`. Never runs on capture
  paths.

### Changed

- `package.json` `os` now includes `linux`. `postinstall` builds the native backend for
  the current platform (Swift binary on macOS; `gcc`-compiled grabber on Linux), and
  never hard-fails the install when a toolchain/headers are missing.
- Documentation (`README.md`, `docs/protocol.md`) now covers Linux requirements and the
  cross-platform protocol. On Linux, `id` is an X11 window id (XID), `record` requires
  `ffmpeg`, and `record_complete.frames` is best-effort (present when `ffprobe` is found).

## [0.1.8]

- Hide offscreen windows by default.
- Earlier 0.1.x releases: native MP4 recording, human-readable CLI output, window
  discovery, capture, snapshot, and streaming on macOS (ScreenCaptureKit).

[Unreleased]: https://github.com/deeeed/capture-helper/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/deeeed/capture-helper/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/deeeed/capture-helper/compare/v0.1.8...v0.2.0
[0.1.8]: https://github.com/deeeed/capture-helper/releases/tag/v0.1.8

# capture-helper protocol

## Commands

### `version`

Prints build/provenance JSON to stdout.

```bash
capture-helper version
```

### `doctor`

Checks runtime readiness and prints JSON to stdout.

```bash
capture-helper doctor --json
```

Current checks include:

- macOS version
- native binary presence
- optional `ffmpeg` presence for external workflows
- ScreenCaptureKit window enumeration / Screen Recording permission signal

### `list`

Lists windows.

```bash
capture-helper
capture-helper list --json
```

Human-readable shortcuts:

```bash
capture-helper list --human
capture-helper list -h
capture-helper -l
capture-helper list --on-screen --capturable --human
capture-helper list --all --human
```

Default output is a JSON object:

```json
{
  "type": "windows",
  "count": 1,
  "windows": [
    {
      "id": 12345,
      "title": "Example",
      "app": "ExampleApp",
      "pid": 999,
      "width": 1200,
      "height": 800,
      "x": 0,
      "y": 30,
      "layer": 0,
      "onScreen": true
    }
  ]
}
```

Legacy JSON-lines output is available with:

```bash
capture-helper list --json-lines
capture-helper --list-windows
```

### `resolve`

Resolves target selectors without capturing. Output is JSON on stdout:

```bash
capture-helper resolve --app-name Simulator --window-name "mm-1"
capture-helper resolve --window-id 12345
```

Example shape:

```json
{
  "type": "resolve",
  "selector": "app-name+window-name",
  "candidateCount": 2,
  "selected": { "id": 12345, "title": "mm-1", "app": "Simulator" },
  "candidates": []
}
```

### `snapshot`

Captures a one-frame PNG using the resolved window id. Output is JSON on stdout; image bytes are written to `--output`.

```bash
capture-helper snapshot --window-id 12345 --output screenshot.png
```

On macOS, `snapshot` uses `/usr/sbin/screencapture` after resolving the target; on Linux it grabs one frame via the X11 grabber and encodes it to PNG with `ffmpeg`.

### `capture`

Writes one raw H.264 Annex B stream to stdout.

```bash
capture-helper capture --window-id 12345
capture-helper capture --pid 12345
capture-helper capture --app-name Simulator --window-name "mm-1"
```

Legacy direct flags are also supported:

```bash
capture-helper --window-name "Simulator"
```

### `record`

Records a target to MP4. On macOS this uses a native AVFoundation writer; on Linux it pipes the X11 grabber into `ffmpeg`.

```bash
capture-helper record --window-id 12345 --duration 5 --output evidence.mp4
```

On macOS, `record` resolves the target window, captures frames with ScreenCaptureKit, and writes an MP4 directly with no `ffmpeg` dependency. On Linux, `record` requires `ffmpeg`.

`record --framed` keeps the MP4 writer running and accepts stdin control commands. This lets automation capture still-image proof from the same ScreenCaptureKit stream instead of starting a second capture against the same window.

```bash
capture-helper record --framed --window-id 12345 --output evidence.mp4
# stdin:
snapshot screenshots/step-1.png
stop
```

Record-session snapshots are PNG files written from the active recording frame. On macOS they are encoded natively in Swift and do not require `ffmpeg`.

### `stream`

`stream` is capture mode with framed multi-window behavior enabled.

```bash
capture-helper stream --framed --window-id 12345
```

## Framed mode

`--framed` enables multi-window capture and stdin control.

Each stdout frame is prefixed by a 6-byte header:

```text
[4B payload length BE][1B flags][1B window index][payload]
```

- **payload length**: big-endian `uint32`, byte length of the payload that follows.
- **flags**: bit 0 (`flags & 1`) is set when the payload is a keyframe (IDR); other bits are reserved (0).
- **window index**: the slot index assigned to the window in `added` events.

The payload is H.264 Annex B bytes. Window indices are assigned by the helper as windows are added.

## Stdin commands

Commands are line-based and available only in `--framed` mode.

For `stream --framed`:

```text
+name <substring>         Add window by title substring
+match <app>\t<title>     Add window by exact app name + title substring
+pid <int>                Add largest suitable window owned by PID
+id <int>                 Add exact window id
-<index>                  Remove window at index
```

For `record --framed`:

```text
snapshot <path>          Write a PNG from the active recording stream
stop                     Finalize the MP4 and exit
```

`record --framed` emits `snapshot` events to stderr when a session snapshot is written.

## stderr events

The helper writes JSON lines to stderr for capture/stream/record diagnostics. Event examples:

```json
{"type":"added","index":0,"name":"Simulator","width":720,"height":480}
{"type":"add_failed","name":"Simulator","error":"no window matching 'Simulator'"}
{"type":"record_start","output":"evidence.mp4"}
{"type":"record_complete","engine":"native","output":"evidence.mp4","frames":75,"bytes":123456}
{"type":"snapshot","engine":"native","mode":"record_session","output":"screenshots/step-1.png","bytes":123456}
{"type":"removed","index":0}
{"type":"info","msg":"shutting down"}
{"type":"error","msg":"--window-id, --window-name, or --pid is required in non-framed mode"}
```

Consumers should treat stderr as the structured control/diagnostic channel and stdout as binary media for capture/stream commands.



## Doctor diagnostics

`doctor --json` emits stable check IDs and codes so callers can distinguish environment failures:

```json
{
  "type": "doctor",
  "ok": true,
  "checks": [
    { "id": "window_enumeration", "ok": true, "code": "window_enumeration_ok", "required": true }
  ],
  "summary": {
    "requiredFailureCount": 0,
    "optionalFailureCount": 0,
    "requiredFailureCodes": [],
    "optionalFailureCodes": []
  }
}
```

Stable doctor codes include:

| Code | Meaning |
| --- | --- |
| `macos_supported` | Current macOS supports ScreenCaptureKit. |
| `unsupported_macos` | macOS 13.0+ is required. |
| `native_binary_present` | Running native binary is executable. |
| `native_binary_missing` | Running native binary is not executable. |
| `ffmpeg_present` | `ffmpeg` is available for external workflows. |
| `ffmpeg_missing` | `ffmpeg` is missing. Optional on macOS (native `record`); required on Linux. |
| `screencapture_present` | `/usr/sbin/screencapture` is available for `snapshot`. |
| `screencapture_missing` | `snapshot` dependency is unavailable. |
| `window_enumeration_ok` | ScreenCaptureKit returned capturable windows. |
| `no_capturable_windows` | ScreenCaptureKit worked but no usable app windows were visible. |
| `screen_recording_denied` | Screen Recording permission appears denied. |
| `window_server_unavailable` | GUI session / WindowServer appears unavailable. |
| `window_enumeration_failed` | Window enumeration failed for another reason. |

## Structured errors

Command failures emit one JSON line on stderr with a stable error `code`:

```json
{"type":"error","code":"target_required","message":"target selector required: --window-id, --pid, or --window-name"}
```

Current stable codes include:

| Code | Meaning |
| --- | --- |
| `target_required` | Required selector or output argument is missing. |
| `window_not_found` | Target selector was valid, but no matching window was found. |
| `dependency_missing` | Required external tool such as `screencapture` is missing. |
| `record_failed` | Record command resolved a window but MP4 writing failed. |
| `snapshot_failed` | Snapshot command resolved a window but image capture failed. |
| `setup_failed` | Capture setup failed before streaming could start. |
| `stream_stopped` | A running ScreenCaptureKit stream stopped with an error. |
| `invalid_index` | Framed stdin command used an invalid slot index. |
| `window_slot_not_found` | Framed stdin command referenced a missing slot. |
| `unknown_command` | Framed stdin command was not recognized. |
| `unexpected_error` | Non-`CaptureError` failure. |

## Platform notes (Linux)

On Linux the protocol is identical, with these implementation differences:

- `id` is an **X11 window id (XID)**, not a macOS `CGWindowID`. XIDs are stable for a
  window's lifetime and may be reused after a window is destroyed. The `added`/`removed`
  index protocol insulates framed consumers from raw ids.
- Capture is occlusion-correct via XComposite; H.264 is produced by `ffmpeg`
  (`libx264` by default, `h264_nvenc` opt-in). SPS/PPS are repeated on every keyframe.
- `record_complete.frames` is best-effort on Linux: it is included when `ffprobe`
  (shipped with `ffmpeg`) can count the output frames, and omitted otherwise. macOS
  always reports it.
- `doctor` keeps the same JSON shape and `summary.requiredFailureCodes`, with Linux
  codes: `session_x11` / `session_wayland` / `session_unknown`, `ffmpeg_present` /
  `ffmpeg_missing` (required on Linux), `grabber_compiled` / `grabber_missing`,
  `display_available` / `display_unavailable`, `xcomposite_present` / `xcomposite_missing`,
  `window_enumeration_ok` / `no_capturable_windows`.
- Requires an Xorg session with a logged-in desktop; captured apps must be X11 clients.
- `permissions` shares the stable macOS fields (`permission`, `grantedBefore`, `grantedAfter`,
  `requestAttempted`, `settingsOpenAttempted`, `remediation`) with always-granted values, plus a
  `platform` field. The macOS-only `launcher` object is omitted (X11 has no permission gate).

## Target resolution boundary

The helper intentionally accepts generic window target selectors only. Domain-specific tools should perform their own resolution before invoking it.

Examples:

- Farmslot slot → PID/window/app/title resolution belongs in Farmslot.
- Recipe runner artifact naming belongs in the recipe runner.
- Simulator-specific fallback policy belongs in the caller, not here.

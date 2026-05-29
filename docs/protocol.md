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
- optional `ffmpeg` presence
- ScreenCaptureKit window enumeration / Screen Recording permission signal

### `list`

Lists macOS windows.

```bash
capture-helper list --json
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

`snapshot` uses macOS `/usr/sbin/screencapture` after resolving the target.

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

Records a target to MP4 using `ffmpeg`.

```bash
capture-helper record --window-id 12345 --duration 5 --output evidence.mp4
```

`record` invokes a child `capture` process and pipes its H.264 output to `ffmpeg`.

### `stream`

`stream` is capture mode with framed multi-window behavior enabled.

```bash
capture-helper stream --framed --window-id 12345
```

## Framed mode

`--framed` enables multi-window capture and stdin control.

Each stdout frame is prefixed by a 6-byte header:

```text
[4B payload length][1B flags][1B window index][payload]
```

The payload is H.264 Annex B bytes. Window indices are assigned by the helper as windows are added.

## Stdin commands

Commands are line-based and available only in `--framed` mode:

```text
+name <substring>         Add window by title substring
+match <app>\t<title>     Add window by exact app name + title substring
+pid <int>                Add largest suitable window owned by PID
+id <int>                 Add exact window id
-<index>                  Remove window at index
```

## stderr events

The helper writes JSON lines to stderr for capture/stream/record diagnostics. Event examples:

```json
{"type":"added","index":0,"name":"Simulator","width":720,"height":480}
{"type":"add_failed","name":"Simulator","error":"no window matching 'Simulator'"}
{"type":"record_start","output":"evidence.mp4"}
{"type":"record_complete","output":"evidence.mp4","captureStatus":0,"ffmpegStatus":0}
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
| `ffmpeg_present` | `ffmpeg` is available for `record`. |
| `ffmpeg_missing` | `ffmpeg` is missing; this is optional unless using `record`. |
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
| `window_not_found` | Target selector was valid, but no matching macOS window was found. |
| `dependency_missing` | Required external tool such as `ffmpeg` or `screencapture` is missing. |
| `snapshot_failed` | Snapshot command resolved a window but image capture failed. |
| `setup_failed` | Capture setup failed before streaming could start. |
| `stream_stopped` | A running ScreenCaptureKit stream stopped with an error. |
| `invalid_index` | Framed stdin command used an invalid slot index. |
| `window_slot_not_found` | Framed stdin command referenced a missing slot. |
| `unknown_command` | Framed stdin command was not recognized. |
| `unexpected_error` | Non-`CaptureError` failure. |

## Target resolution boundary

The helper intentionally accepts generic macOS target selectors only. Domain-specific tools should perform their own resolution before invoking it.

Examples:

- Farmslot slot → PID/window/app/title resolution belongs in Farmslot.
- Recipe runner artifact naming belongs in the recipe runner.
- Simulator-specific fallback policy belongs in the caller, not here.

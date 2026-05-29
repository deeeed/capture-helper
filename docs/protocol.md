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

## Target resolution boundary

The helper intentionally accepts generic macOS target selectors only. Domain-specific tools should perform their own resolution before invoking it.

Examples:

- Farmslot slot → PID/window/app/title resolution belongs in Farmslot.
- Recipe runner artifact naming belongs in the recipe runner.
- Simulator-specific fallback policy belongs in the caller, not here.

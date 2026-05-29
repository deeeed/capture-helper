# capture-helper protocol

## Legacy raw mode

When invoked without `--framed`, `capture-helper` writes one raw H.264 Annex B stream to stdout.

A target is required:

```bash
capture-helper --window-name "Simulator"
capture-helper --app-name Simulator --window-name "mm-1"
capture-helper --pid 12345
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
-<index>                  Remove window at index
```

## stderr events

The helper writes JSON lines to stderr. Event examples:

```json
{"type":"added","index":0,"name":"Simulator","width":720,"height":480}
{"type":"add_failed","name":"Simulator","error":"no window matching 'Simulator'"}
{"type":"removed","index":0}
{"type":"info","msg":"shutting down"}
{"type":"error","msg":"--window-name or --pid is required in non-framed mode"}
```

Consumers should treat stderr as the structured control/diagnostic channel and stdout as binary media only.

## Target resolution boundary

The helper intentionally accepts generic macOS target selectors only. Domain-specific tools should perform their own resolution before invoking it.

Examples:

- Farmslot slot → PID/window/app/title resolution belongs in Farmslot.
- Recipe runner artifact naming belongs in the recipe runner.
- Simulator-specific fallback policy belongs in the caller, not here.

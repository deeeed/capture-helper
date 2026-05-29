import Foundation

enum CommandMode: Equatable {
    case capture
    case list
    case doctor
    case record
    case resolve
    case snapshot
    case permissions
    case version
}

struct Config {
    var command: CommandMode = .capture
    var initialNames: [String] = []
    var initialAppName: String? = nil
    var initialPid: pid_t? = nil
    var initialWindowId: UInt32? = nil
    var maxFps: Int32 = 15
    var maxSize: Int = 720
    var framed = false
    var json = true
    var legacyJsonLines = false
    var outputPath: String? = nil
    var durationSeconds: Double? = nil
    var ffmpegPath: String? = nil
    var openPermissions = false
    var requestPermissions = false
    var openOutput = false
    var listOnScreenOnly = false
    var listCapturableOnly = false
}

enum Runtime {
    static var config = Config()
}

func parseArgs(_ args: [String] = CommandLine.arguments) -> Config {
    var cfg = Config()
    var sawCommand = false
    var i = 1

    if i < args.count {
        switch args[i] {
        case "capture":
            cfg.command = .capture; sawCommand = true; i += 1
        case "stream":
            cfg.command = .capture; cfg.framed = true; sawCommand = true; i += 1
        case "list", "windows":
            cfg.command = .list; sawCommand = true; i += 1
        case "-l":
            cfg.command = .list
            cfg.json = false
            sawCommand = true
            i += 1
        case "doctor":
            cfg.command = .doctor; sawCommand = true; i += 1
        case "record":
            cfg.command = .record; sawCommand = true; i += 1
        case "resolve":
            cfg.command = .resolve; sawCommand = true; i += 1
        case "snapshot":
            cfg.command = .snapshot; sawCommand = true; i += 1
        case "permissions":
            cfg.command = .permissions
            cfg.openPermissions = true
            cfg.requestPermissions = true
            sawCommand = true
            i += 1
        case "version":
            cfg.command = .version; sawCommand = true; i += 1
        case "help":
            exitUsage()
        default:
            break
        }
    }

    while i < args.count {
        switch args[i] {
        case "--window-name", "--name":
            i += 1; guard i < args.count else { exitUsage() }
            cfg.initialNames.append(args[i])
        case "--window-names":
            i += 1; guard i < args.count else { exitUsage() }
            cfg.initialNames += args[i].split(separator: ",").map(String.init)
        case "--app-name", "--app":
            i += 1; guard i < args.count else { exitUsage() }
            cfg.initialAppName = args[i]
        case "--pid":
            i += 1; guard i < args.count, let value = Int32(args[i]) else { exitUsage() }
            cfg.initialPid = value
        case "--window-id":
            i += 1; guard i < args.count, let value = UInt32(args[i]) else { exitUsage() }
            cfg.initialWindowId = value
        case "--max-fps":
            i += 1; guard i < args.count, let value = Int32(args[i]), value > 0 else { exitUsage() }
            cfg.maxFps = value
        case "--max-size":
            i += 1; guard i < args.count, let value = Int(args[i]), value > 0 else { exitUsage() }
            cfg.maxSize = value
        case "--output", "-o":
            i += 1; guard i < args.count else { exitUsage() }
            cfg.outputPath = args[i]
        case "--duration":
            i += 1; guard i < args.count, let value = Double(args[i]), value > 0 else { exitUsage() }
            cfg.durationSeconds = value
        case "--ffmpeg":
            i += 1; guard i < args.count else { exitUsage() }
            cfg.ffmpegPath = args[i]
        case "--open":
            cfg.openOutput = true
        case "--on-screen":
            cfg.listOnScreenOnly = true
        case "--capturable":
            cfg.listCapturableOnly = true
        case "--open-permissions":
            cfg.openPermissions = true
        case "--request-permission", "--request-permissions":
            cfg.requestPermissions = true
        case "--status-only":
            cfg.openPermissions = false
            cfg.requestPermissions = false
        case "--framed":
            cfg.framed = true
        case "--json":
            cfg.json = true
        case "--human", "--text", "-H":
            cfg.json = false
        case "-h" where supportsHumanOutput(cfg.command):
            cfg.json = false
        case "--json-lines", "--jsonl":
            cfg.legacyJsonLines = true
        case "-l":
            cfg.command = .list
            cfg.json = false
        case "--list-windows":
            cfg.command = .list
            cfg.legacyJsonLines = true
            sawCommand = true
        case "--version", "-v":
            cfg.command = .version
        case "--help", "-h":
            exitUsage()
        default:
            writeString("unknown argument: \(args[i])\n", toStderr: true)
            exitUsage()
        }
        i += 1
    }

    if !sawCommand && cfg.command == .capture && cfg.initialWindowId == nil && cfg.initialPid == nil && cfg.initialNames.isEmpty {
        cfg.command = .list
        if args.count == 1 {
            cfg.json = false
        }
    }

    return cfg
}

func exitUsage() -> Never {
    let usage = """
    capture-helper — macOS window capture for agents and automation

    Usage:
      capture-helper
      capture-helper help
      capture-helper capture [target options] [--max-fps N] [--max-size N]
      capture-helper stream [target options] [--framed]
      capture-helper record [target options] --output PATH [--duration seconds]
      capture-helper resolve [target options] [--json]
      capture-helper snapshot [target options] --output PATH
      capture-helper list [--json | --json-lines]
      capture-helper -l
      capture-helper doctor [--json] [--open-permissions]
      capture-helper permissions [--status-only | --open-permissions] [--request-permission]
      capture-helper version

    Legacy usage remains supported:
      capture-helper --window-name <string> > /tmp/capture.h264
      capture-helper --list-windows

    Target options:
      --window-id <id>        Capture exact macOS window id from `list`
      --window-name <string>  Window title substring. Can repeat.
      --name <string>         Alias for --window-name.
      --window-names <a,b>    Comma-separated window title substrings.
      --app-name <string>     Restrict title matching to exact app name.
      --app <string>          Alias for --app-name.
      --pid <int>             Capture largest suitable window owned by PID.

    Capture options:
      --max-fps <int>         Max frame rate (default: 15)
      --max-size <int>        Max dimension in pixels (default: 720)
      --framed                Framed output with stdin commands

    Record/snapshot options:
      --output, -o <path>     MP4 output path for record, image path for snapshot
      --duration <seconds>    Stop automatically after duration
      --ffmpeg <path>         Check an explicit ffmpeg path in doctor output
      --open                  Open the MP4/image after record or snapshot

    List filters:
      --on-screen             Show only currently on-screen windows
      --capturable            Show only likely capturable application windows

    Permission options:
      --open-permissions      Open the macOS Screen Recording permission pane
      --request-permission    Ask macOS to prompt for Screen Recording when possible
      --status-only           Only report permission state; do not request/open

    Output options:
      --json                  Machine-readable JSON output (default)
      --human, --text, -H     Human-readable output for supported commands
      -h                      Human output after list/doctor/permissions/version; help otherwise
      -l                      Shortcut for `list --human`
      --json-lines, --jsonl   JSON-lines output for list

    Framed stdin commands:
      +name <substring>       Add window by title substring
      +match <app>\t<title>   Add window by app name + title substring
      +pid <int>              Add largest window owned by PID
      +id <int>               Add exact window id
      -<index>                Remove window at index
    """
    writeString(usage, toStderr: true)
    exit(0)
}

func supportsHumanOutput(_ command: CommandMode) -> Bool {
    switch command {
    case .list, .doctor, .permissions, .version:
        return true
    case .capture, .record, .resolve, .snapshot:
        return false
    }
}

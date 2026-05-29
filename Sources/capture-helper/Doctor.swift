import Foundation

func runDoctor(json: Bool) async {
    var checks: [[String: Any]] = []
    var ok = true

    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let macOSOk = osVersion.majorVersion >= 13
    ok = ok && macOSOk
    checks.append([
        "name": "macOS version",
        "ok": macOSOk,
        "value": BuildInfo.osVersion,
        "message": macOSOk ? "macOS version supports ScreenCaptureKit" : "macOS 13.0 or newer is required"
    ])

    let binaryExists = FileManager.default.isExecutableFile(atPath: CommandLine.arguments[0])
    ok = ok && binaryExists
    checks.append([
        "name": "native binary",
        "ok": binaryExists,
        "value": CommandLine.arguments[0]
    ])

    let ffmpeg = findExecutable(Runtime.config.ffmpegPath ?? "ffmpeg")
    checks.append([
        "name": "ffmpeg",
        "ok": ffmpeg != nil,
        "value": ffmpeg ?? "not found",
        "required": false,
        "message": ffmpeg == nil ? "ffmpeg is optional unless using record mode" : "ffmpeg is available"
    ])

    do {
        let windows = try await allWindowObjects()
        checks.append([
            "name": "window enumeration",
            "ok": true,
            "value": windows.count,
            "message": "ScreenCaptureKit returned \(windows.count) windows"
        ])
    } catch {
        ok = false
        checks.append([
            "name": "window enumeration",
            "ok": false,
            "error": "\(error)",
            "message": "Check Screen Recording permission for the launching app"
        ])
    }

    let result: [String: Any] = [
        "type": "doctor",
        "ok": ok,
        "build": BuildInfo.object(),
        "checks": checks
    ]

    if json {
        emitJSONObject(result)
    } else {
        writeString(ok ? "capture-helper doctor: OK\n" : "capture-helper doctor: FAILED\n")
        for check in checks {
            let status = (check["ok"] as? Bool ?? false) ? "OK" : "FAIL"
            writeString("[\(status)] \(check["name"] ?? "check")")
            if let message = check["message"] {
                writeString(" — \(message)")
            }
            writeString("\n")
        }
    }

    if !ok { exit(1) }
}

func findExecutable(_ nameOrPath: String) -> String? {
    if nameOrPath.contains("/") {
        return FileManager.default.isExecutableFile(atPath: nameOrPath) ? nameOrPath : nil
    }
    let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin").split(separator: ":").map(String.init)
    for path in paths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(nameOrPath).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

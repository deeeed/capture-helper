import Foundation

enum DoctorCode {
    static let macOSSupported = "macos_supported"
    static let unsupportedMacOS = "unsupported_macos"
    static let nativeBinaryPresent = "native_binary_present"
    static let nativeBinaryMissing = "native_binary_missing"
    static let ffmpegPresent = "ffmpeg_present"
    static let ffmpegMissing = "ffmpeg_missing"
    static let screencapturePresent = "screencapture_present"
    static let screencaptureMissing = "screencapture_missing"
    static let windowEnumerationOk = "window_enumeration_ok"
    static let noCapturableWindows = "no_capturable_windows"
    static let screenRecordingDenied = "screen_recording_denied"
    static let windowServerUnavailable = "window_server_unavailable"
    static let windowEnumerationFailed = "window_enumeration_failed"
}

struct DoctorCheck {
    let id: String
    let name: String
    let ok: Bool
    let code: String
    let required: Bool
    let message: String
    let value: Any?
    let details: [String: Any]

    func object() -> [String: Any] {
        var object: [String: Any] = [
            "id": id,
            "name": name,
            "ok": ok,
            "code": code,
            "required": required,
            "message": message
        ]
        if let value { object["value"] = value }
        if !details.isEmpty { object["details"] = details }
        return object
    }
}

func runDoctor(json: Bool) async {
    let checks = await doctorChecks()
    let ok = checks.allSatisfy { $0.ok || !$0.required }
    let result: [String: Any] = [
        "type": "doctor",
        "ok": ok,
        "build": BuildInfo.object(),
        "checks": checks.map { $0.object() },
        "summary": doctorSummary(checks)
    ]

    if json {
        emitJSONObject(result)
    } else {
        writeString(ok ? "capture-helper doctor: OK\n" : "capture-helper doctor: FAILED\n")
        for check in checks {
            let status = check.ok ? "OK" : (check.required ? "FAIL" : "WARN")
            writeString("[\(status)] \(check.name) (\(check.code)) — \(check.message)\n")
        }
    }

    if !ok { exit(1) }
}

func doctorChecks() async -> [DoctorCheck] {
    var checks: [DoctorCheck] = []
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion
    let macOSOk = osVersion.majorVersion >= 13
    checks.append(DoctorCheck(
        id: "macos",
        name: "macOS version",
        ok: macOSOk,
        code: macOSOk ? DoctorCode.macOSSupported : DoctorCode.unsupportedMacOS,
        required: true,
        message: macOSOk ? "macOS version supports ScreenCaptureKit" : "macOS 13.0 or newer is required",
        value: BuildInfo.osVersion,
        details: ["minimum": "13.0"]
    ))

    let binaryPath = currentExecutablePath()
    let binaryOk = FileManager.default.isExecutableFile(atPath: binaryPath)
    checks.append(DoctorCheck(
        id: "native_binary",
        name: "native binary",
        ok: binaryOk,
        code: binaryOk ? DoctorCode.nativeBinaryPresent : DoctorCode.nativeBinaryMissing,
        required: true,
        message: binaryOk ? "native binary is executable" : "native binary is not executable",
        value: binaryPath,
        details: [:]
    ))

    let ffmpeg = findExecutable(Runtime.config.ffmpegPath ?? "ffmpeg")
    checks.append(DoctorCheck(
        id: "ffmpeg",
        name: "ffmpeg",
        ok: ffmpeg != nil,
        code: ffmpeg != nil ? DoctorCode.ffmpegPresent : DoctorCode.ffmpegMissing,
        required: false,
        message: ffmpeg == nil ? "ffmpeg is optional unless using record mode" : "ffmpeg is available for record mode",
        value: ffmpeg ?? "not found",
        details: [:]
    ))

    let screencapture = findExecutable("/usr/sbin/screencapture")
    checks.append(DoctorCheck(
        id: "screencapture",
        name: "screencapture",
        ok: screencapture != nil,
        code: screencapture != nil ? DoctorCode.screencapturePresent : DoctorCode.screencaptureMissing,
        required: true,
        message: screencapture == nil ? "/usr/sbin/screencapture is required for snapshot mode" : "screencapture is available for snapshot mode",
        value: screencapture ?? "not found",
        details: [:]
    ))

    checks.append(await windowEnumerationCheck())
    return checks
}

func windowEnumerationCheck() async -> DoctorCheck {
    do {
        let windows = try await allWindowObjects()
        let capturable = windows.filter { window in
            let width = window["width"] as? Int ?? 0
            let height = window["height"] as? Int ?? 0
            let layer = window["layer"] as? Int ?? Int.max
            let ratio = Double(width) / Double(max(height, 1))
            return width > 100 && height > 100 && layer == 0 && ratio < 10
        }
        let ok = !capturable.isEmpty
        return DoctorCheck(
            id: "window_enumeration",
            name: "window enumeration",
            ok: ok,
            code: ok ? DoctorCode.windowEnumerationOk : DoctorCode.noCapturableWindows,
            required: true,
            message: ok ? "ScreenCaptureKit returned capturable windows" : "ScreenCaptureKit worked, but no capturable application windows were found",
            value: windows.count,
            details: [
                "windowCount": windows.count,
                "capturableWindowCount": capturable.count,
                "onScreenWindowCount": windows.filter { ($0["onScreen"] as? Bool) == true }.count
            ]
        )
    } catch {
        let classification = classifyWindowEnumerationError(error)
        return DoctorCheck(
            id: "window_enumeration",
            name: "window enumeration",
            ok: false,
            code: classification.code,
            required: true,
            message: classification.message,
            value: nil,
            details: ["error": "\(error)"]
        )
    }
}

func classifyWindowEnumerationError(_ error: Error) -> (code: String, message: String) {
    let text = "\(error)".lowercased()
    if text.contains("permission") || text.contains("not authorized") || text.contains("denied") || text.contains("privacy") {
        return (DoctorCode.screenRecordingDenied, "Screen Recording permission appears to be denied for the launching app")
    }
    if text.contains("windowserver") || text.contains("window server") || text.contains("connection invalid") || text.contains("not connected") {
        return (DoctorCode.windowServerUnavailable, "WindowServer / GUI session appears unavailable")
    }
    return (DoctorCode.windowEnumerationFailed, "ScreenCaptureKit window enumeration failed")
}

func doctorSummary(_ checks: [DoctorCheck]) -> [String: Any] {
    let requiredFailures = checks.filter { !$0.ok && $0.required }
    let optionalFailures = checks.filter { !$0.ok && !$0.required }
    return [
        "requiredFailureCount": requiredFailures.count,
        "optionalFailureCount": optionalFailures.count,
        "requiredFailureCodes": requiredFailures.map(\.code),
        "optionalFailureCodes": optionalFailures.map(\.code)
    ]
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

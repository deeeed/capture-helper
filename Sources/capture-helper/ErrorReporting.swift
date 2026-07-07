import Foundation

extension CaptureError {
    var code: String {
        switch self {
        case .windowNotFound: return "window_not_found"
        case .setupFailed: return "setup_failed"
        case .targetRequired: return "target_required"
        case .dependencyMissing: return "dependency_missing"
        case .recordFailed: return "record_failed"
        case .snapshotFailed: return "snapshot_failed"
        }
    }
}

func errorCode(for error: Error) -> String {
    if let captureError = error as? CaptureError {
        return captureError.code
    }
    if isScreenRecordingDeniedError(error) {
        return DoctorCode.screenRecordingDenied
    }
    return "unexpected_error"
}

func errorObject(_ error: Error, context: [String: Any] = [:]) -> [String: Any] {
    var object = context
    object["type"] = "error"
    let code = errorCode(for: error)
    object["code"] = code
    object["message"] = "\(error)"
    if code == DoctorCode.screenRecordingDenied {
        object["remediation"] = screenRecordingRemediation()
    }
    return object
}

func logError(_ error: Error, context: [String: Any] = [:]) {
    emitJSONLine(errorObject(error, context: context), toStderr: true)
}

func logErrorMessage(code: String, message: String, context: [String: Any] = [:]) {
    var object = context
    object["type"] = "error"
    object["code"] = code
    object["message"] = message
    emitJSONLine(object, toStderr: true)
}

func isScreenRecordingDeniedError(_ error: Error) -> Bool {
    let text = "\(error)".lowercased()
    return text.contains("screencapturekit.scstreamerrordomain code=-3801")
        || text.contains("declined tcc")
        || text.contains("tccs for application, window, display capture")
        || text.contains("screen recording")
        || text.contains("not authorized")
        || text.contains("permission")
        || text.contains("denied")
        || text.contains("privacy")
}

func screenRecordingDeniedMessage() -> String {
    "Screen Recording permission appears to be denied for the launching app"
}

func screenRecordingRemediation() -> [String] {
    [
        "Open System Settings > Privacy & Security > Screen & System Audio Recording.",
        "Enable the app that launches capture-helper; if a UI app is failing, enable that app, not Terminal.",
        "If running from Terminal/iTerm/Codex locally, enable the terminal app.",
        "If running over SSH, enable /usr/libexec/sshd-keygen-wrapper.",
        "Then restart the launcher and run capture-helper doctor --json."
    ]
}

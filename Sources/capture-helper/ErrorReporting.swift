import Foundation

extension CaptureError {
    var code: String {
        switch self {
        case .windowNotFound: return "window_not_found"
        case .setupFailed: return "setup_failed"
        case .targetRequired: return "target_required"
        case .dependencyMissing: return "dependency_missing"
        case .snapshotFailed: return "snapshot_failed"
        }
    }
}

func errorCode(for error: Error) -> String {
    if let captureError = error as? CaptureError {
        return captureError.code
    }
    return "unexpected_error"
}

func errorObject(_ error: Error, context: [String: Any] = [:]) -> [String: Any] {
    var object = context
    object["type"] = "error"
    object["code"] = errorCode(for: error)
    object["message"] = "\(error)"
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

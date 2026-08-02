import Foundation

enum BuildInfo {
    static let name = "@siteed/capture-helper"
    static let binaryName = "capture-helper"
    static let version = "0.2.6"
    static let capabilities = ["record_session_snapshot"]

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static func object() -> [String: Any] {
        [
            "name": name,
            "binary": binaryName,
            "version": version,
            "capabilities": capabilities,
            "architecture": architecture,
            "os": "macOS",
            "osVersion": osVersion
        ]
    }
}

func printVersion(json: Bool) {
    if json {
        emitJSONObject(BuildInfo.object())
    } else {
        writeString("\(BuildInfo.binaryName) \(BuildInfo.version)\n")
    }
}

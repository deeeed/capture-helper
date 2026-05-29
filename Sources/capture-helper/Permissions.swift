import CoreGraphics
import Foundation

private let screenRecordingSettingsURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"

struct PermissionsResult {
    let grantedBefore: Bool
    let requestAttempted: Bool
    let requestGranted: Bool?
    let settingsOpenAttempted: Bool
    let settingsOpened: Bool?
    let grantedAfter: Bool
    let launcher: [String: Any]
    let remediation: [String]

    func object() -> [String: Any] {
        var object: [String: Any] = [
            "type": "permissions",
            "permission": "screen_recording",
            "grantedBefore": grantedBefore,
            "requestAttempted": requestAttempted,
            "settingsOpenAttempted": settingsOpenAttempted,
            "grantedAfter": grantedAfter,
            "launcher": launcher,
            "remediation": remediation
        ]
        if let requestGranted {
            object["requestGranted"] = requestGranted
        }
        if let settingsOpened {
            object["settingsOpened"] = settingsOpened
        }
        return object
    }
}

func runPermissionsCommand(_ config: Config) -> Never {
    let result = runPermissionsWorkflow(
        request: config.requestPermissions,
        openSettings: config.openPermissions
    )
    if config.json {
        emitJSONObject(result.object())
    } else {
        writeString(result.grantedAfter ? "Screen Recording permission: granted\n" : "Screen Recording permission: not granted\n")
        for line in result.remediation {
            writeString("- \(line)\n")
        }
    }
    exit(result.grantedAfter ? 0 : 1)
}

func runPermissionsWorkflow(request: Bool, openSettings: Bool) -> PermissionsResult {
    let grantedBefore = CGPreflightScreenCaptureAccess()
    var requestGranted: Bool?
    var settingsOpened: Bool?

    if request && !grantedBefore {
        requestGranted = CGRequestScreenCaptureAccess()
    }

    let grantedAfterRequest = CGPreflightScreenCaptureAccess()
    if openSettings && !grantedAfterRequest {
        settingsOpened = openScreenRecordingSettings()
    }

    return PermissionsResult(
        grantedBefore: grantedBefore,
        requestAttempted: request && !grantedBefore,
        requestGranted: requestGranted,
        settingsOpenAttempted: openSettings && !grantedAfterRequest,
        settingsOpened: settingsOpened,
        grantedAfter: CGPreflightScreenCaptureAccess(),
        launcher: launcherPermissionHint(),
        remediation: screenRecordingRemediation()
    )
}

func openScreenRecordingSettings() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = [screenRecordingSettingsURL]
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        logErrorMessage(
            code: "open_permissions_failed",
            message: "failed to open Screen Recording settings: \(error)"
        )
        return false
    }
}

func launcherPermissionHint() -> [String: Any] {
    let environment = ProcessInfo.processInfo.environment
    if environment["SSH_CONNECTION"] != nil || environment["SSH_CLIENT"] != nil || environment["SSH_TTY"] != nil {
        return [
            "kind": "ssh",
            "approvalTarget": "/usr/libexec/sshd-keygen-wrapper",
            "message": "SSH-launched capture usually needs Screen Recording approval for sshd-keygen-wrapper."
        ]
    }

    return [
        "kind": "local",
        "approvalTarget": "the terminal, IDE, or agent app that launched capture-helper",
        "message": "macOS grants Screen Recording permission to the launching GUI app."
    ]
}

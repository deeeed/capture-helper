import Foundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error, CustomStringConvertible {
    case windowNotFound(String)
    case setupFailed(String)
    case targetRequired(String)
    case dependencyMissing(String)
    case recordFailed(String)
    case snapshotFailed(String)

    var description: String {
        switch self {
        case .windowNotFound(let message): return message
        case .setupFailed(let message): return message
        case .targetRequired(let message): return message
        case .dependencyMissing(let message): return message
        case .recordFailed(let message): return message
        case .snapshotFailed(let message): return message
        }
    }
}

func loadWindows(onScreenOnly: Bool) async throws -> [SCWindow] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: onScreenOnly)
    return content.windows.filter { window in
        window.frame.width > 0 && window.frame.height > 0
    }
}

func windowObject(_ window: SCWindow, onScreenIds: Set<CGWindowID>) -> [String: Any] {
    [
        "id": Int(window.windowID),
        "title": window.title ?? "",
        "app": window.owningApplication?.applicationName ?? "",
        "pid": Int(window.owningApplication?.processID ?? 0),
        "width": Int(window.frame.width),
        "height": Int(window.frame.height),
        "x": Int(window.frame.origin.x),
        "y": Int(window.frame.origin.y),
        "layer": Int(window.windowLayer),
        "onScreen": onScreenIds.contains(window.windowID)
    ]
}

func allWindowObjects() async throws -> [[String: Any]] {
    let onScreenWindows = try await loadWindows(onScreenOnly: true)
    let onScreenIds = Set(onScreenWindows.map(\.windowID))
    let allWindows = try await loadWindows(onScreenOnly: false)
    return allWindows.map { windowObject($0, onScreenIds: onScreenIds) }
}

func listAllWindows(jsonLines: Bool, human: Bool = false) async throws {
    let windows = filterWindowObjects(try await allWindowObjects())
    if human {
        printWindowTable(windows)
    } else if jsonLines {
        for window in windows {
            emitJSONLine(window)
        }
    } else {
        emitJSONObject(["type": "windows", "windows": windows, "count": windows.count])
    }
}

func filterWindowObjects(_ windows: [[String: Any]]) -> [[String: Any]] {
    windows.filter { window in
        if Runtime.config.listOnScreenOnly && (window["onScreen"] as? Bool) != true {
            return false
        }
        if Runtime.config.listCapturableOnly && !isLikelyCapturable(window) {
            return false
        }
        if let appName = Runtime.config.initialAppName, (window["app"] as? String) != appName {
            return false
        }
        if !Runtime.config.initialNames.isEmpty {
            let title = window["title"] as? String ?? ""
            if !Runtime.config.initialNames.contains(where: { title.localizedCaseInsensitiveContains($0) }) {
                return false
            }
        }
        return true
    }
}

func isLikelyCapturable(_ window: [String: Any]) -> Bool {
    let width = window["width"] as? Int ?? 0
    let height = window["height"] as? Int ?? 0
    let layer = window["layer"] as? Int ?? Int.max
    let ratio = Double(width) / Double(max(height, 1))
    return width > 100 && height > 100 && layer == 0 && ratio < 10
}

func printWindowTable(_ windows: [[String: Any]]) {
    let capturable = windows.filter { window in
        isLikelyCapturable(window)
    }.sorted { lhs, rhs in
        let lhsOnScreen = lhs["onScreen"] as? Bool ?? false
        let rhsOnScreen = rhs["onScreen"] as? Bool ?? false
        if lhsOnScreen != rhsOnScreen { return lhsOnScreen && !rhsOnScreen }
        let lhsArea = (lhs["width"] as? Int ?? 0) * (lhs["height"] as? Int ?? 0)
        let rhsArea = (rhs["width"] as? Int ?? 0) * (rhs["height"] as? Int ?? 0)
        return lhsArea > rhsArea
    }

    writeString("capture-helper windows: \(windows.count) total, \(capturable.count) likely capturable\n")
    writeString("ID        PID       SCREEN  SIZE        APP                         TITLE\n")
    writeString("--------  --------  ------  ----------  --------------------------  ------------------------------\n")

    for window in capturable.prefix(80) {
        let id = "\(window["id"] as? Int ?? 0)"
        let pid = "\(window["pid"] as? Int ?? 0)"
        let screen = (window["onScreen"] as? Bool ?? false) ? "yes" : "no"
        let width = window["width"] as? Int ?? 0
        let height = window["height"] as? Int ?? 0
        let size = "\(width)x\(height)"
        let app = truncate(window["app"] as? String ?? "", to: 26)
        let title = truncate(window["title"] as? String ?? "", to: 60)
        writeString("\(pad(id, 8))  \(pad(pid, 8))  \(pad(screen, 6))  \(pad(size, 10))  \(pad(app, 26))  \(title)\n")
    }

    if capturable.count > 80 {
        writeString("… \(capturable.count - 80) more likely capturable windows omitted; use --json for complete output.\n")
    }
    writeString("\nTips: capture-helper record --window-id <ID> --duration 5 -o evidence.mp4 --open\n")
    writeString("      capture-helper --help for all commands and selectors.\n")
}

func pad(_ value: String, _ width: Int) -> String {
    if value.count >= width { return value }
    return value + String(repeating: " ", count: width - value.count)
}

func truncate(_ value: String, to maxLength: Int) -> String {
    if value.count <= maxLength { return value }
    return String(value.prefix(maxLength - 1)) + "…"
}

func filteredWindows(_ windows: [SCWindow], appName: String?, titleSubstring: String) -> [SCWindow] {
    windows.filter { window in
        guard let title = window.title, title.contains(titleSubstring) else { return false }
        if let appName {
            return window.owningApplication?.applicationName == appName
        }
        return true
    }.sorted { a, b in
        (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
    }
}

func availableTitles(_ windows: [SCWindow], appName: String?) -> String {
    let scoped = windows.filter { window in
        guard let title = window.title, !title.isEmpty else { return false }
        if let appName {
            return window.owningApplication?.applicationName == appName
        }
        return true
    }
    let names = scoped.map { $0.title ?? "" }
    return names.isEmpty ? "" : names.joined(separator: ", ")
}

func findWindowByName(_ name: String, appName: String? = nil) async throws -> SCWindow {
    var config = Config()
    config.initialNames = [name]
    config.initialAppName = appName
    return try await resolveTarget(config).window
}

func findWindowByPid(_ pid: pid_t) async throws -> SCWindow {
    var config = Config()
    config.initialPid = pid
    return try await resolveTarget(config).window
}

func findWindowById(_ id: UInt32) async throws -> SCWindow {
    var config = Config()
    config.initialWindowId = id
    return try await resolveTarget(config).window
}

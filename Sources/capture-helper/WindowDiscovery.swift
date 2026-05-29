import Foundation
import ScreenCaptureKit
import CoreGraphics

enum CaptureError: Error, CustomStringConvertible {
    case windowNotFound(String)
    case setupFailed(String)

    var description: String {
        switch self {
        case .windowNotFound(let message): return message
        case .setupFailed(let message): return message
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

func listAllWindows(jsonLines: Bool) async throws {
    let windows = try await allWindowObjects()
    if jsonLines {
        for window in windows {
            emitJSONLine(window)
        }
    } else {
        emitJSONObject(["type": "windows", "windows": windows, "count": windows.count])
    }
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

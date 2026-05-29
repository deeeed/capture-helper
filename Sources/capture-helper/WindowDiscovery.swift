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
    let onScreenWindows = try await loadWindows(onScreenOnly: true)
    let onScreenMatches = filteredWindows(onScreenWindows, appName: appName, titleSubstring: name)
    if let window = onScreenMatches.first { return window }

    let allWindows = try await loadWindows(onScreenOnly: false)
    let fallbackMatches = filteredWindows(allWindows, appName: appName, titleSubstring: name)
    if let window = fallbackMatches.first {
        log("info", "falling back to off-screen window lookup for \(appName ?? "any-app")/\(name)")
        return window
    }

    let appLabel = appName ?? "any app"
    let visible = availableTitles(onScreenWindows, appName: appName)
    let all = availableTitles(allWindows, appName: appName)
    throw CaptureError.windowNotFound(
        "no window matching '\(name)' in \(appLabel) (visible: \(visible); all: \(all))"
    )
}

func findWindowByPid(_ pid: pid_t) async throws -> SCWindow {
    let windows = try await loadWindows(onScreenOnly: false).filter { window in
        guard window.owningApplication?.processID == pid else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }
        guard window.windowLayer == 0 else { return false }
        let ratio = window.frame.width / max(window.frame.height, 1)
        return ratio < 10
    }
    let sorted = windows.sorted { a, b in
        (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
    }
    guard let window = sorted.first else {
        throw CaptureError.windowNotFound("no window found for PID \(pid)")
    }
    return window
}

func findWindowById(_ id: UInt32) async throws -> SCWindow {
    let allWindows = try await loadWindows(onScreenOnly: false)
    guard let window = allWindows.first(where: { UInt32($0.windowID) == id }) else {
        throw CaptureError.windowNotFound("no window found for id \(id)")
    }
    return window
}

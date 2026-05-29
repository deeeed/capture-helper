import Foundation
import ScreenCaptureKit
import CoreGraphics

struct ResolvedTarget {
    let window: SCWindow
    let selector: String
    let candidates: [SCWindow]
    let onScreenIds: Set<CGWindowID>

    var selectedObject: [String: Any] {
        windowObject(window, onScreenIds: onScreenIds)
    }

    var candidateObjects: [[String: Any]] {
        candidates.map { windowObject($0, onScreenIds: onScreenIds) }
    }
}

func resolveTarget(_ config: Config) async throws -> ResolvedTarget {
    guard config.initialWindowId != nil || config.initialPid != nil || !config.initialNames.isEmpty else {
        throw CaptureError.targetRequired("target selector required: --window-id, --pid, or --window-name")
    }

    let onScreenWindows = try await loadWindows(onScreenOnly: true)
    let onScreenIds = Set(onScreenWindows.map(\.windowID))
    let allWindows = try await loadWindows(onScreenOnly: false)

    if let windowId = config.initialWindowId {
        let candidates = allWindows.filter { UInt32($0.windowID) == windowId }
        guard let window = candidates.first else {
            throw CaptureError.windowNotFound("no window found for id \(windowId)")
        }
        return ResolvedTarget(window: window, selector: "window-id", candidates: candidates, onScreenIds: onScreenIds)
    }

    if let pid = config.initialPid {
        let candidates = rankedPidCandidates(allWindows, pid: pid)
        guard let window = candidates.first else {
            throw CaptureError.windowNotFound("no window found for PID \(pid)")
        }
        return ResolvedTarget(window: window, selector: "pid", candidates: candidates, onScreenIds: onScreenIds)
    }

    if let name = config.initialNames.first {
        let onScreenCandidates = filteredWindows(onScreenWindows, appName: config.initialAppName, titleSubstring: name)
        if let window = onScreenCandidates.first {
            return ResolvedTarget(window: window, selector: config.initialAppName == nil ? "window-name" : "app-name+window-name", candidates: onScreenCandidates, onScreenIds: onScreenIds)
        }

        let allCandidates = filteredWindows(allWindows, appName: config.initialAppName, titleSubstring: name)
        if let window = allCandidates.first {
            return ResolvedTarget(window: window, selector: config.initialAppName == nil ? "window-name-offscreen" : "app-name+window-name-offscreen", candidates: allCandidates, onScreenIds: onScreenIds)
        }

        let appLabel = config.initialAppName ?? "any app"
        let visible = availableTitles(onScreenWindows, appName: config.initialAppName)
        let all = availableTitles(allWindows, appName: config.initialAppName)
        throw CaptureError.windowNotFound(
            "no window matching '\(name)' in \(appLabel) (visible: \(visible); all: \(all))"
        )
    }

    throw CaptureError.targetRequired("target selector required: --window-id, --pid, or --window-name")
}

func rankedPidCandidates(_ windows: [SCWindow], pid: pid_t) -> [SCWindow] {
    windows.filter { window in
        guard window.owningApplication?.processID == pid else { return false }
        guard window.frame.width > 100 && window.frame.height > 100 else { return false }
        guard window.windowLayer == 0 else { return false }
        let ratio = window.frame.width / max(window.frame.height, 1)
        return ratio < 10
    }.sorted { a, b in
        (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
    }
}

func printResolvedTarget(_ config: Config) async throws {
    let resolved = try await resolveTarget(config)
    emitJSONObject([
        "type": "resolve",
        "selector": resolved.selector,
        "selected": resolved.selectedObject,
        "candidates": resolved.candidateObjects,
        "candidateCount": resolved.candidates.count
    ])
}

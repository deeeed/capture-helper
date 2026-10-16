import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

// AX window order and titles do not identify the selected ScreenCaptureKit window.
@_silgen_name("_AXUIElementGetWindow")
private func accessibilityWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

func prepareRecordingWindow(_ resolved: ResolvedTarget) async throws -> SCWindow {
    let window = resolved.window
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
        throw CaptureError.recordFailed("Cannot record window \(window.windowID): no active display is available.")
    }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
        throw CaptureError.recordFailed("Cannot locate a visible display for recording window \(window.windowID).")
    }
    let displays = ids.prefix(Int(count)).filter { CGDisplayIsAsleep($0) == 0 }.map(CGDisplayBounds)
    // Desktop-independent capture already records occluded on-screen windows.
    // Only recovery needs Accessibility, so ordinary recording keeps its permissions.
    if resolved.onScreenIds.contains(window.windowID), displays.contains(where: { $0.intersects(window.frame) }) {
        return window
    }
    guard AXIsProcessTrusted(), let pid = window.owningApplication?.processID else {
        throw CaptureError.recordFailed("Window \(window.windowID) is off-screen or hidden. Grant Accessibility to the launching app so the recorder can move and raise the selected window.")
    }
    let application = AXUIElementCreateApplication(pid)
    guard AXUIElementSetMessagingTimeout(application, 1) == .success else {
        throw CaptureError.recordFailed("Cannot set a bounded Accessibility timeout for off-screen window \(window.windowID).")
    }
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
          let windows = value as? [AXUIElement],
          let selected = windows.first(where: { element in
              var id: CGWindowID = 0
              return accessibilityWindowID(element, &id) == .success && id == window.windowID
          }) else {
        throw CaptureError.recordFailed("Cannot move off-screen window \(window.windowID): its exact Accessibility window is unavailable.")
    }
    guard AXUIElementSetMessagingTimeout(selected, 1) == .success else {
        throw CaptureError.recordFailed("Cannot set a bounded Accessibility timeout for selected window \(window.windowID).")
    }
    guard let frame = recordingWindowFrame(window.frame, displays: displays) else {
        throw CaptureError.recordFailed("Cannot record an off-screen window: no active display is available.")
    }
    var position = frame.origin
    guard let point = AXValueCreate(.cgPoint, &position) else {
        throw CaptureError.recordFailed("Cannot prepare the position of off-screen window \(window.windowID).")
    }
    await MainActor.run {
        let app = NSRunningApplication(processIdentifier: pid)
        app?.unhide()
        app?.activate(options: [.activateIgnoringOtherApps])
    }
    let restore = AXUIElementSetAttributeValue(selected, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    let move = AXUIElementSetAttributeValue(selected, kAXPositionAttribute as CFString, point)
    let raise = AXUIElementPerformAction(selected, kAXRaiseAction as CFString)
    guard restore == .success, move == .success, raise == .success else {
        throw CaptureError.recordFailed("Cannot move and raise off-screen window \(window.windowID) (restore \(restore.rawValue), move \(move.rawValue), raise \(raise.rawValue)). Check Accessibility permission for the launching app.")
    }
    let deadline = Date().addingTimeInterval(2)
    repeat {
        if let visible = try await loadWindows(onScreenOnly: true).first(where: { candidate in
            candidate.windowID == window.windowID && displays.contains(where: { $0.intersects(candidate.frame) })
        }) {
            return visible
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    } while Date() < deadline
    throw CaptureError.recordFailed("Selected window \(window.windowID) is still off-screen after moving and raising it; recording was not started.")
}

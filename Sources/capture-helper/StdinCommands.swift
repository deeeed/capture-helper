import Foundation
import ScreenCaptureKit

func startStdinReader() {
    Thread.detachNewThread {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await handleCommand(trimmed)
                semaphore.signal()
            }
            semaphore.wait()
        }
        log("info", "stdin closed, shutting down")
        removeAllWindows()
        exit(0)
    }
}

func handleCommand(_ command: String) async {
    if command.hasPrefix("+name ") {
        let name = String(command.dropFirst(6))
        await addWindowFromCommand(name: name) {
            try await findWindowByName(name)
        }
    } else if command.hasPrefix("+match ") {
        let payload = String(command.dropFirst(7))
        let parts = payload.split(separator: "\t", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            logEvent(("type", "add_failed"), ("name", payload), ("error", "expected +match <app>\\t<title>"))
            return
        }
        let appName = parts[0]
        let title = parts[1]
        await addWindowFromCommand(name: "\(appName):\(title)") {
            try await findWindowByName(title, appName: appName)
        }
    } else if command.hasPrefix("+pid ") {
        let pidString = String(command.dropFirst(5))
        guard let pid = Int32(pidString) else {
            logEvent(("type", "add_failed"), ("name", "pid:\(pidString)"), ("error", "invalid PID"))
            return
        }
        await addWindowFromCommand(name: "pid:\(pid)") {
            try await findWindowByPid(pid)
        }
    } else if command.hasPrefix("+id ") {
        let idString = String(command.dropFirst(4))
        guard let id = UInt32(idString) else {
            logEvent(("type", "add_failed"), ("name", "id:\(idString)"), ("error", "invalid window id"))
            return
        }
        await addWindowFromCommand(name: "id:\(id)") {
            try await findWindowById(id)
        }
    } else if command.hasPrefix("-") {
        let indexString = String(command.dropFirst(1))
        guard let index = Int(indexString) else {
            logErrorMessage(code: "invalid_index", message: "invalid index: \(indexString)")
            return
        }
        guard index < slots.count, slots[index] != nil else {
            logErrorMessage(code: "window_slot_not_found", message: "no window at index \(index)", context: ["index": index])
            return
        }
        removeWindowCapture(index: index)
        logEvent(("type", "removed"), ("index", index))
    } else {
        logErrorMessage(code: "unknown_command", message: "unknown command: \(command)")
    }
}

func addWindowFromCommand(name: String, resolver: () async throws -> SCWindow) async {
    do {
        let window = try await resolver()
        let resolvedName = window.title ?? name
        let slot = try await addWindowCapture(name: resolvedName, window: window)
        logEvent(("type", "added"), ("index", Int(slot.index)),
                 ("name", slot.name), ("width", slot.outWidth), ("height", slot.outHeight))
    } catch {
        logEvent(("type", "add_failed"), ("name", name), ("error", "\(error)"))
    }
}

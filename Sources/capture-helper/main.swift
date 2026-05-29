import Foundation
import AppKit
import CoreGraphics

_ = CGMainDisplayID()

func cleanupAndExit() -> Never {
    log("info", "shutting down")
    removeAllWindows()
    exit(0)
}

func installSignalHandlers() {
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    sigintSource.setEventHandler { cleanupAndExit() }
    sigtermSource.setEventHandler { cleanupAndExit() }
    sigintSource.resume()
    sigtermSource.resume()
}

func addInitialCaptures(_ config: Config) async throws {
    if let windowId = config.initialWindowId {
        let window = try await findWindowById(windowId)
        let name = window.title ?? "id:\(windowId)"
        let slot = try await addWindowCapture(name: name, window: window)
        logEvent(("type", "added"), ("index", Int(slot.index)),
                 ("name", name), ("width", slot.outWidth), ("height", slot.outHeight), ("windowId", Int(windowId)))
    }

    for name in config.initialNames {
        let window = try await findWindowByName(name, appName: config.initialAppName)
        let slot = try await addWindowCapture(name: name, window: window)
        logEvent(("type", "added"), ("index", Int(slot.index)),
                 ("name", name), ("width", slot.outWidth), ("height", slot.outHeight))
    }

    if let pid = config.initialPid {
        let window = try await findWindowByPid(pid)
        let name = window.title ?? "pid:\(pid)"
        let slot = try await addWindowCapture(name: name, window: window)
        logEvent(("type", "added"), ("index", Int(slot.index)),
                 ("name", name), ("width", slot.outWidth), ("height", slot.outHeight), ("pid", Int(pid)))
    }
}

let config = parseArgs()
Runtime.config = config
setbuf(stdout, nil)

switch config.command {
case .version:
    printVersion(json: config.json)
    exit(0)
case .doctor:
    Task {
        await runDoctor(json: config.json)
        exit(0)
    }
    dispatchMain()
case .permissions:
    runPermissionsCommand(config)
case .list:
    Task {
        do {
            try await listAllWindows(jsonLines: config.legacyJsonLines)
            exit(0)
        } catch {
            logError(error)
            exit(1)
        }
    }
    dispatchMain()
case .record:
    do {
        try runRecord(config)
    } catch {
        logError(error)
        exit(1)
    }
case .resolve:
    Task {
        do {
            try await printResolvedTarget(config)
            exit(0)
        } catch {
            logError(error)
            exit(1)
        }
    }
    dispatchMain()
case .snapshot:
    Task {
        do {
            try await runSnapshot(config)
            exit(0)
        } catch {
            logError(error)
            exit(1)
        }
    }
    dispatchMain()
case .capture:
    installSignalHandlers()
    Task {
        do {
            try await addInitialCaptures(config)

            if let duration = config.durationSeconds {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                    cleanupAndExit()
                }
            }

            if config.framed {
                startStdinReader()
            }

            if !config.framed && activeWindowCount == 0 {
                logError(CaptureError.targetRequired("--window-id, --window-name, or --pid is required in non-framed mode"))
                exit(1)
            }
        } catch {
            logError(error)
            exit(1)
        }
    }
    dispatchMain()
}

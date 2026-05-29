import Foundation

func runRecord(_ config: Config) throws -> Never {
    guard let outputPath = config.outputPath else {
        throw CaptureError.targetRequired("record requires --output PATH")
    }
    guard config.initialWindowId != nil || config.initialPid != nil || !config.initialNames.isEmpty else {
        throw CaptureError.targetRequired("record requires --window-id, --pid, or --window-name")
    }
    guard let ffmpeg = findExecutable(config.ffmpegPath ?? "ffmpeg") else {
        throw CaptureError.dependencyMissing("ffmpeg not found; install ffmpeg or pass --ffmpeg /path/to/ffmpeg")
    }

    let fm = FileManager.default
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDir = outputURL.deletingLastPathComponent().path
    if !fm.fileExists(atPath: outputDir) {
        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    let executable = CommandLine.arguments[0]
    var captureArgs: [String] = ["capture", "--max-fps", "\(config.maxFps)", "--max-size", "\(config.maxSize)"]
    if let duration = config.durationSeconds {
        captureArgs += ["--duration", "\(duration)"]
    }
    if let windowId = config.initialWindowId {
        captureArgs += ["--window-id", "\(windowId)"]
    } else if let pid = config.initialPid {
        captureArgs += ["--pid", "\(pid)"]
    } else {
        if let appName = config.initialAppName {
            captureArgs += ["--app-name", appName]
        }
        for name in config.initialNames {
            captureArgs += ["--window-name", name]
        }
    }

    let mediaPipe = Pipe()

    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: executable)
    capture.arguments = captureArgs
    capture.standardOutput = mediaPipe
    capture.standardError = FileHandle.standardError

    let ffmpegProcess = Process()
    ffmpegProcess.executableURL = URL(fileURLWithPath: ffmpeg)
    ffmpegProcess.arguments = [
        "-nostdin",
        "-framerate", "\(config.maxFps)",
        "-fflags", "+genpts",
        "-f", "h264",
        "-i", "pipe:0",
        "-c:v", "libx264",
        "-preset", "ultrafast",
        "-pix_fmt", "yuv420p",
        "-movflags", "+faststart",
        "-y", outputPath
    ]
    ffmpegProcess.standardInput = mediaPipe
    ffmpegProcess.standardError = FileHandle.standardError

    logEvent(("type", "record_start"), ("output", outputPath), ("ffmpeg", ffmpeg), ("captureArgs", captureArgs.joined(separator: " ")))

    try ffmpegProcess.run()
    try capture.run()

    func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return !process.isRunning
    }

    func stopProcess(_ process: Process, timeout: TimeInterval) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGTERM)
        if !waitForExit(process, timeout: timeout), process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = waitForExit(process, timeout: 1.0)
        }
    }

    func stopChildren() {
        stopProcess(capture, timeout: 2.0)
        try? mediaPipe.fileHandleForWriting.close()
        if ffmpegProcess.isRunning {
            _ = waitForExit(ffmpegProcess, timeout: 5.0)
        }
        if ffmpegProcess.isRunning {
            stopProcess(ffmpegProcess, timeout: 1.0)
        }
    }

    capture.waitUntilExit()
    try? mediaPipe.fileHandleForWriting.close()
    if config.durationSeconds == nil, capture.terminationStatus == 0 {
        stopChildren()
    } else {
        ffmpegProcess.waitUntilExit()
    }

    let ok = fm.fileExists(atPath: outputPath) && (try? fm.attributesOfItem(atPath: outputPath)[.size] as? NSNumber)?.intValue ?? 0 > 0
    if ok {
        logEvent(("type", "record_complete"), ("output", outputPath), ("captureStatus", capture.terminationStatus), ("ffmpegStatus", ffmpegProcess.terminationStatus))
        exit(ffmpegProcess.terminationStatus == 0 ? 0 : 1)
    } else {
        logEvent(("type", "record_failed"), ("output", outputPath), ("captureStatus", capture.terminationStatus), ("ffmpegStatus", ffmpegProcess.terminationStatus))
        exit(1)
    }
}

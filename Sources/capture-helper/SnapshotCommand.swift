import Foundation

func runSnapshot(_ config: Config) async throws {
    guard let outputPath = config.outputPath else {
        throw CaptureError.setupFailed("snapshot requires --output PATH")
    }

    let resolved = try await resolveTarget(config)
    let fileManager = FileManager.default
    let outputURL = URL(fileURLWithPath: outputPath)
    let outputDir = outputURL.deletingLastPathComponent().path
    if !fileManager.fileExists(atPath: outputDir) {
        try fileManager.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
    }

    let screencapture = "/usr/sbin/screencapture"
    guard fileManager.isExecutableFile(atPath: screencapture) else {
        throw CaptureError.setupFailed("/usr/sbin/screencapture not found")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: screencapture)
    process.arguments = ["-x", "-l\(resolved.window.windowID)", outputPath]
    process.standardError = FileHandle.standardError
    try process.run()
    process.waitUntilExit()

    let size = (try? fileManager.attributesOfItem(atPath: outputPath)[.size] as? NSNumber)?.intValue ?? 0
    guard process.terminationStatus == 0, size > 0 else {
        throw CaptureError.setupFailed("snapshot failed with status \(process.terminationStatus)")
    }

    emitJSONObject([
        "type": "snapshot",
        "output": outputPath,
        "bytes": size,
        "selector": resolved.selector,
        "selected": resolved.selectedObject
    ])
}

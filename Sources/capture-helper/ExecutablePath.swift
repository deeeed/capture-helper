import Darwin
import Foundation

func currentExecutablePath() -> String {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)

    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
    defer { buffer.deallocate() }

    if _NSGetExecutablePath(buffer, &size) == 0 {
        return URL(fileURLWithPath: String(cString: buffer)).standardizedFileURL.path
    }

    return resolvedCommandLineExecutablePath()
}

func resolvedCommandLineExecutablePath() -> String {
    let argv0 = CommandLine.arguments.first ?? BuildInfo.binaryName
    if argv0.contains("/") {
        let path = argv0.hasPrefix("/")
            ? argv0
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(argv0)
                .path
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    return findExecutable(argv0) ?? argv0
}

import XCTest

final class CaptureHelperTests: XCTestCase {
    struct CommandResult {
        let status: Int32
        let stdout: String
        let stdoutData: Data
        let stderr: String
    }

    func testVersionProducesMachineReadableJSON() throws {
        let result = try runHelper(["version"])

        XCTAssertEqual(result.status, 0, result.stderr)
        let object = try parseJSONObject(result.stdout)
        XCTAssertEqual(object["name"] as? String, "@siteed/capture-helper")
        XCTAssertEqual(object["binary"] as? String, "capture-helper")
        XCTAssertEqual(object["version"] as? String, "0.3.1")
        XCTAssertNotNil(object["architecture"])
        XCTAssertNotNil(object["osVersion"])
        XCTAssertTrue((object["capabilities"] as? [String])?.contains("record_session_timing_v1") == true)
    }

    func testDoctorResolvesExecutableWhenInvokedFromPath() throws {
        let helper = helperURL()
        let result = try runCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["capture-helper", "doctor", "--json"],
            environment: [
                "PATH": helper.deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            ]
        )

        let object = try parseJSONObject(result.stdout)
        let checks = try XCTUnwrap(object["checks"] as? [[String: Any]])
        let nativeBinary = try XCTUnwrap(checks.first { ($0["id"] as? String) == "native_binary" })
        XCTAssertEqual(nativeBinary["ok"] as? Bool, true)
        XCTAssertEqual(nativeBinary["code"] as? String, "native_binary_present")
        let value = try XCTUnwrap(nativeBinary["value"] as? String)
        XCTAssertTrue(value.hasPrefix("/"), value)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: value), value)
    }


    func testDoctorDefaultsToHumanOutput() throws {
        let result = try runHelper(["doctor"])

        XCTAssertTrue(
            result.stdout.hasPrefix("capture-helper doctor: OK\n") ||
            result.stdout.hasPrefix("capture-helper doctor: FAILED\n"),
            result.stdout
        )
        XCTAssertTrue(result.stdout.contains("[OK]") || result.stdout.contains("[FAIL]"), result.stdout)
        XCTAssertFalse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{"), result.stdout)
    }

    func testDoctorProducesStableCheckCodesAndSummary() throws {
        let result = try runHelper(["doctor", "--json"])

        let object = try parseJSONObject(result.stdout)
        XCTAssertEqual(object["type"] as? String, "doctor")
        XCTAssertNotNil(object["ok"])
        XCTAssertNotNil(object["build"])

        let checks = try XCTUnwrap(object["checks"] as? [[String: Any]])
        let checksById = Dictionary(uniqueKeysWithValues: checks.compactMap { check -> (String, [String: Any])? in
            guard let id = check["id"] as? String else { return nil }
            return (id, check)
        })

        XCTAssertNotNil(checksById["macos"])
        XCTAssertNotNil(checksById["native_binary"])
        XCTAssertNotNil(checksById["ffmpeg"])
        XCTAssertNotNil(checksById["screencapture"])
        XCTAssertNotNil(checksById["window_enumeration"])

        for check in checks {
            XCTAssertNotNil(check["id"], "check missing id: \(check)")
            XCTAssertNotNil(check["name"], "check missing name: \(check)")
            XCTAssertNotNil(check["ok"], "check missing ok: \(check)")
            XCTAssertNotNil(check["code"], "check missing code: \(check)")
            XCTAssertNotNil(check["required"], "check missing required: \(check)")
            XCTAssertNotNil(check["message"], "check missing message: \(check)")
        }

        let macOSCode = checksById["macos"]?["code"] as? String
        XCTAssertTrue(["macos_supported", "unsupported_macos"].contains(macOSCode))

        let ffmpegCode = checksById["ffmpeg"]?["code"] as? String
        XCTAssertTrue(["ffmpeg_present", "ffmpeg_missing"].contains(ffmpegCode))

        let windowCode = checksById["window_enumeration"]?["code"] as? String
        XCTAssertTrue([
            "window_enumeration_ok",
            "no_capturable_windows",
            "screen_recording_denied",
            "window_server_unavailable",
            "window_enumeration_failed"
        ].contains(windowCode))

        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertNotNil(summary["requiredFailureCount"])
        XCTAssertNotNil(summary["optionalFailureCount"])
        XCTAssertNotNil(summary["requiredFailureCodes"])
        XCTAssertNotNil(summary["optionalFailureCodes"])
    }

    func testHelpMentionsResolveAndSnapshot() throws {
        let result = try runHelper(["--help"])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("capture-helper resolve"), result.stderr)
        XCTAssertTrue(result.stderr.contains("capture-helper snapshot"), result.stderr)
        XCTAssertTrue(result.stderr.contains("snapshot <path>"), result.stderr)
        XCTAssertTrue(result.stderr.contains("stop"), result.stderr)
        XCTAssertTrue(result.stderr.contains("capture-helper permissions"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--human"), result.stderr)
        XCTAssertTrue(result.stderr.contains("capture-helper -l"), result.stderr)
        XCTAssertTrue(result.stderr.contains("-H"), result.stderr)
        XCTAssertTrue(result.stderr.contains("capture-helper help"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--on-screen"), result.stderr)
        XCTAssertTrue(result.stderr.contains("--all"), result.stderr)
        XCTAssertTrue(result.stderr.contains("record: 30; stream/capture: 15"), result.stderr)
        XCTAssertTrue(result.stderr.contains("record: 1440; stream/capture: 720"), result.stderr)
    }

    func testVersionSupportsHumanOutput() throws {
        let result = try runHelper(["version", "--human"])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "capture-helper 0.3.1\n")
    }

    func testVersionSupportsShortHumanOutput() throws {
        let result = try runHelper(["version", "-h"])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "capture-helper 0.3.1\n")
    }

    func testHelpCommandShowsUsage() throws {
        let result = try runHelper(["help"])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("capture-helper — macOS window capture"), result.stderr)
    }

    func testPermissionsStatusOnlyProducesJSON() throws {
        let result = try runHelper(["permissions", "--status-only"])

        let object = try parseJSONObject(result.stdout)
        XCTAssertEqual(object["type"] as? String, "permissions")
        XCTAssertEqual(object["permission"] as? String, "screen_recording")
        XCTAssertNotNil(object["grantedBefore"])
        XCTAssertEqual(object["requestAttempted"] as? Bool, false)
        XCTAssertEqual(object["settingsOpenAttempted"] as? Bool, false)
        XCTAssertNotNil(object["grantedAfter"])
        XCTAssertNotNil(object["launcher"])
        XCTAssertNotNil(object["remediation"])
    }

    func testResolveWithoutTargetFailsWithStableErrorCode() throws {
        let result = try runHelper(["resolve"])

        XCTAssertNotEqual(result.status, 0)
        let error = try parseFirstJSONLine(result.stderr)
        XCTAssertEqual(error["type"] as? String, "error")
        XCTAssertEqual(error["code"] as? String, "target_required")
        XCTAssertTrue((error["message"] as? String ?? "").contains("target selector required"))
    }

    func testRecordWithoutOutputFailsBeforeTargetResolution() throws {
        let result = try runHelper(["record", "--window-id", "1"])

        XCTAssertNotEqual(result.status, 0)
        let error = try parseFirstJSONLine(result.stderr)
        XCTAssertEqual(error["type"] as? String, "error")
        XCTAssertEqual(error["code"] as? String, "target_required")
        XCTAssertEqual(error["message"] as? String, "record requires --output PATH")
    }

    func testSnapshotWithoutOutputFailsBeforeTargetResolution() throws {
        let result = try runHelper(["snapshot", "--window-id", "1"])

        XCTAssertNotEqual(result.status, 0)
        let error = try parseFirstJSONLine(result.stderr)
        XCTAssertEqual(error["type"] as? String, "error")
        XCTAssertEqual(error["code"] as? String, "target_required")
        XCTAssertEqual(error["message"] as? String, "snapshot requires --output PATH")
    }

    func testRecordKeepsPartialVideoWhenStreamIsInterrupted() throws {
        let dir = try makeTempDirectory()
        let output = dir.appendingPathComponent("interrupted.mp4").path
        let result = try runHelper(["record", "--window-id", "1", "--output", output],
                                   simulatedInterruptAfterFrames: 10)

        XCTAssertEqual(result.status, 3, result.stderr)
        XCTAssertFalse(result.stderr.contains("record_complete"), result.stderr)
        let event = try parseLastJSONLine(result.stderr)
        XCTAssertEqual(event["type"] as? String, "error")
        XCTAssertEqual(event["code"] as? String, "stream_interrupted")
        XCTAssertEqual(event["frames"] as? Int, 10)
        XCTAssertGreaterThan(event["media_time_ms"] as? Double ?? 0, 0)
        XCTAssertEqual(event["cause"] as? String,
                       "com.apple.ScreenCaptureKit.SCStreamErrorDomain -3805: Failed during stream due to application connection being interrupted")
        XCTAssertEqual(event["output"] as? String, output)
        XCTAssertGreaterThan(event["bytes"] as? Int ?? 0, 0)

        // The timing sidecar is read back from the finalized MP4, so its frame list proves the file is playable.
        let timingPath = try XCTUnwrap(event["timing_path"] as? String)
        XCTAssertEqual(timingPath, output + ".timing.json")
        let timing = try parseJSONObject(String(contentsOfFile: timingPath, encoding: .utf8))
        XCTAssertEqual((timing["frames_ms"] as? [Double])?.count, 10)
        XCTAssertEqual(timing["recording_id"] as? String, event["recording_id"] as? String)
    }

    func testRecordInterruptedBeforeAnyFrameFailsWithoutPartialVideo() throws {
        let dir = try makeTempDirectory()
        let output = dir.appendingPathComponent("empty.mp4").path
        let result = try runHelper(["record", "--window-id", "1", "--output", output],
                                   simulatedInterruptAfterFrames: 0)

        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertFalse(result.stderr.contains("stream_interrupted"), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output + ".timing.json"))
    }

    func testCaptureReportsStreamInterruptionAndExits() throws {
        let result = try runHelper(["capture", "--window-id", "1"], simulatedInterruptAfterFrames: 10)

        XCTAssertEqual(result.status, 3, result.stderr)
        // CI runners can add non-JSON system log lines to stderr; only our JSON events matter here.
        let lines = result.stderr.split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let event = try XCTUnwrap(lines.first { $0["code"] as? String == "stream_interrupted" }, result.stderr)
        XCTAssertEqual(event["index"] as? Int, 0)
        let frames = event["frames"] as? Int ?? 0
        XCTAssertTrue((1...10).contains(frames), "frames=\(frames)")
        XCTAssertNotNil(event["media_time_ms"] as? Double)
        XCTAssertTrue((event["cause"] as? String ?? "").contains("SCStreamErrorDomain -3805"))
        XCTAssertEqual(lines.last?["type"] as? String, "removed")
        // Frames handed to the encoder were flushed to stdout as Annex-B H.264.
        XCTAssertEqual(Array(result.stdoutData.prefix(4)), [0, 0, 0, 1])
    }

    private func runHelper(_ arguments: [String], simulatedInterruptAfterFrames: Int? = nil) throws -> CommandResult {
        var environment: [String: String]? = nil
        if let simulatedInterruptAfterFrames {
            environment = ProcessInfo.processInfo.environment
            environment?["CAPTURE_HELPER_TEST_INTERRUPT_AFTER_FRAMES"] = String(simulatedInterruptAfterFrames)
        }
        return try runCommand(executableURL: helperURL(), arguments: arguments, environment: environment)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("capture-helper-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func runCommand(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        // Drain both pipes before waiting so binary stdout larger than the pipe buffer cannot block the child.
        var stderrData = Data()
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
            stderrDrained.signal()
        }
        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        stderrDrained.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stdoutData: stdoutData,
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }

    private func helperURL() -> URL {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates = [
            root.appendingPathComponent(".build/debug/capture-helper"),
            root.appendingPathComponent(".build/release/capture-helper")
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        XCTFail("capture-helper binary not found in .build/debug or .build/release")
        return candidates[0]
    }

    private func parseJSONObject(_ text: String) throws -> [String: Any] {
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            XCTFail("Expected JSON object, got: \(text)")
            return [:]
        }
        return dictionary
    }

    private func parseLastJSONLine(_ text: String) throws -> [String: Any] {
        guard let line = text.split(separator: "\n").last else {
            XCTFail("Expected JSON line, got empty text")
            return [:]
        }
        return try parseJSONObject(String(line))
    }

    private func parseFirstJSONLine(_ text: String) throws -> [String: Any] {
        guard let line = text.split(separator: "\n").first else {
            XCTFail("Expected JSON line, got empty text")
            return [:]
        }
        return try parseJSONObject(String(line))
    }
}

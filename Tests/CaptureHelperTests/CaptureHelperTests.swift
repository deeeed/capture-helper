import XCTest
import Darwin

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
        XCTAssertEqual(object["version"] as? String, "0.3.5")
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
        XCTAssertEqual(result.stdout, "capture-helper 0.3.5\n")
    }

    func testVersionSupportsShortHumanOutput() throws {
        let result = try runHelper(["version", "-h"])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "capture-helper 0.3.5\n")
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output + ".timing.json"))
    }

    func testRecordRejectsSessionSnapshotAfterStop() throws {
        let dir = try makeTempDirectory()
        let output = dir.appendingPathComponent("recording.mp4").path
        let active = dir.appendingPathComponent("active.png").path
        let stopped = dir.appendingPathComponent("stopped.png").path
        let result = try runHelper(
            ["record", "--framed", "--window-id", "1", "--output", output],
            // Only the explicit stop should end this stream, even if PNG encoding is slow.
            simulatedInterruptAfterFrames: Int.max,
            inputCommands: "snapshot \(active)\nstop\nsnapshot \(stopped)\n"
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: active), result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped), result.stderr)
        let events = try parseJSONEvents(result.stderr)
        let failure = try XCTUnwrap(events.first { ($0["output"] as? String) == stopped })
        XCTAssertEqual(failure["code"] as? String, "snapshot_failed")
        XCTAssertEqual(failure["message"] as? String, "recording session is no longer active")
        let timing = try parseJSONObject(String(contentsOfFile: output + ".timing.json", encoding: .utf8))
        XCTAssertEqual((timing["snapshots"] as? [[String: Any]])?.count, 1)
    }

    func testRecordRejectsSessionSnapshotAfterStreamInterruption() throws {
        let dir = try makeTempDirectory()
        let output = dir.appendingPathComponent("interrupted.mp4").path
        let stopped = dir.appendingPathComponent("stopped.png").path
        let result = try runHelper(
            ["record", "--framed", "--window-id", "1", "--output", output],
            simulatedInterruptAfterFrames: 10,
            inputCommands: "snapshot \(stopped)\n",
            inputEvent: "stream_stopped"
        )

        XCTAssertEqual(result.status, 3, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stopped), result.stderr)
        let events = try parseJSONEvents(result.stderr)
        let failure = try XCTUnwrap(events.first { ($0["output"] as? String) == stopped })
        XCTAssertEqual(failure["code"] as? String, "snapshot_failed")
        XCTAssertEqual(failure["message"] as? String, "recording session is no longer active")
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

    func testCaptureAccessRefusesEveryCompetingSCKCommandBeforeTouchingOutput() throws {
        let dir = try makeTempDirectory()
        let environment = accessEnvironment(dir)
        let fd = open(dir.appendingPathComponent("access.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let output = dir.appendingPathComponent("retained.mp4")
        try Data("retained evidence".utf8).write(to: output)
        for command in ["list", "resolve", "snapshot", "record", "capture", "stream"] {
            let result = try runCommand(executableURL: helperURL(),
                arguments: [command, "--window-id", "1", "--output", output.path], environment: environment)
            XCTAssertEqual(result.status, 1, result.stderr)
            XCTAssertEqual(try parseFirstJSONLine(result.stderr)["code"] as? String, "capture_busy", command)
            XCTAssertEqual(try String(contentsOf: output), "retained evidence")
        }
        let doctor = try runCommand(executableURL: helperURL(), arguments: ["doctor", "--json"], environment: environment)
        let report = try parseJSONObject(doctor.stdout)
        XCTAssertEqual(doctor.status, 1, doctor.stderr)
        XCTAssertEqual(report["ok"] as? Bool, false)
        let checks = try XCTUnwrap(report["checks"] as? [[String: Any]])
        let enumeration = try XCTUnwrap(checks.first { $0["id"] as? String == "window_enumeration" })
        XCTAssertEqual(enumeration["code"] as? String, "capture_busy")
        XCTAssertEqual(enumeration["required"] as? Bool, true)
        let summary = try XCTUnwrap(report["summary"] as? [String: Any])
        XCTAssertTrue((summary["requiredFailureCodes"] as? [String])?.contains("capture_busy") == true)
        let version = try runCommand(executableURL: helperURL(), arguments: ["version"], environment: environment)
        XCTAssertEqual(version.status, 0, version.stderr)
        let permissions = try runCommand(executableURL: helperURL(), arguments: ["permissions", "--status-only"], environment: environment)
        XCTAssertEqual(try parseJSONObject(permissions.stdout)["type"] as? String, "permissions")
    }

    func testRecordingWindowPlacementPreservesViewportAndUsesVisibleDisplayCoordinates() throws {
        let dir = try makeTempDirectory()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Compile the actual pure placement function, without importing the CLI's main entry point.
        let source = try String(contentsOf: root.appendingPathComponent("Sources/capture-helper/RecordingWindowGeometry.swift"))
        let script = dir.appendingPathComponent("geometry.swift")
        try (source + """

        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let offscreen = CGRect(x: 12000, y: 5000, width: 900, height: 700)
        let placed = recordingWindowFrame(offscreen, displays: [display])!
        precondition(display.contains(placed) && placed.size == offscreen.size)
        precondition(placed.origin == CGPoint(x: 1020, y: 380))
        let secondary = CGRect(x: -1920, y: -600, width: 1920, height: 1080)
        let visible = CGRect(x: -1700, y: -400, width: 900, height: 700)
        precondition(recordingWindowFrame(visible, displays: [secondary, display]) == visible)
        let oversized = CGRect(x: -9000, y: -9000, width: 1600, height: 2400)
        let small = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchored = recordingWindowFrame(oversized, displays: [small])!
        precondition(anchored.origin == small.origin && anchored.size == oversized.size)
        precondition(small.intersects(anchored))
        precondition(recordingWindowFrame(oversized, displays: []) == nil)
        print("geometry verified")
        """).write(to: script, atomically: true, encoding: .utf8)
        let result = try runCommand(executableURL: URL(fileURLWithPath: "/usr/bin/swift"), arguments: [script.path])
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("geometry verified"), result.stdout)
    }

    func testRecordingWithoutAFirstFrameFailsFastInsteadOfWaitingForItsDuration() throws {
        let dir = try makeTempDirectory()
        var environment = accessEnvironment(dir)
        environment["CAPTURE_HELPER_TEST_INTERRUPT_AFTER_FRAMES"] = "0"
        environment["CAPTURE_HELPER_TEST_STALL_BEFORE_FIRST_FRAME"] = "1"
        let started = Date()
        let result = try runCommand(executableURL: helperURL(), arguments: [
            "record", "--window-id", "1", "--duration", "30",
            "--output", dir.appendingPathComponent("empty.mp4").path
        ], environment: environment)
        XCTAssertEqual(result.status, 1, result.stderr)
        XCTAssertTrue(result.stderr.contains("No first video frame arrived within 3 seconds"), result.stderr)
        XCTAssertTrue(result.stderr.contains("off-screen"), result.stderr)
        XCTAssertFalse(result.stderr.contains("\"record_ready\""), result.stderr)
        XCTAssertFalse(result.stderr.contains("\"record_complete\""), result.stderr)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5)
        try assertAccessReleased(dir)
    }

    func testRecordingKeepsAccessThroughSessionSnapshotsAndNormalCompletion() throws {
        let dir = try makeTempDirectory()
        let output = dir.appendingPathComponent("record.mp4")
        let snapshot = dir.appendingPathComponent("snapshot.png")
        let log = dir.appendingPathComponent("record.jsonl")
        let stdin = Pipe()
        let process = try startAccessOwner(dir, arguments: ["record", "--framed", "--window-id", "1", "--output", output.path],
                                           stdin: stdin, log: log)
        try waitUntil { (try? String(contentsOf: log).contains("\"record_ready\"")) == true }
        let doctor = try runCommand(executableURL: helperURL(), arguments: ["doctor", "--json"], environment: accessEnvironment(dir))
        XCTAssertEqual(doctor.status, 1, doctor.stdout)
        XCTAssertTrue(doctor.stdout.contains("capture_busy"), doctor.stdout)
        stdin.fileHandleForWriting.write(Data("snapshot \(snapshot.path)\nstop\n".utf8))
        stdin.fileHandleForWriting.closeFile()
        try waitUntil { !process.isRunning }
        let logText = try String(contentsOf: log)
        XCTAssertEqual(process.terminationStatus, 0, logText)
        let events = try parseJSONEvents(logText)
        XCTAssertTrue(events.contains { $0["type"] as? String == "snapshot" })
        XCTAssertEqual(events.last?["type"] as? String, "record_complete")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path + ".timing.json"))
        try assertAccessReleased(dir)
    }

    func testFramedStreamCrashReleasesCaptureAccess() throws {
        let dir = try makeTempDirectory()
        let log = dir.appendingPathComponent("stream.jsonl")
        let stdin = Pipe()
        let process = try startAccessOwner(dir, arguments: ["stream", "--window-id", "1"], stdin: stdin, log: log)
        try waitUntil { (try? String(contentsOf: log).contains("\"added\"")) == true }
        let contender = try runCommand(executableURL: helperURL(), arguments: ["list"], environment: accessEnvironment(dir))
        XCTAssertEqual(try parseFirstJSONLine(contender.stderr)["code"] as? String, "capture_busy")
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        try waitUntil { !process.isRunning }
        try assertAccessReleased(dir)
    }

    private func accessEnvironment(_ dir: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CAPTURE_HELPER_TEST_ACCESS_PATH"] = dir.appendingPathComponent("access.lock").path
        return environment
    }

    private func startAccessOwner(_ dir: URL, arguments: [String], stdin: Pipe, log: URL) throws -> Process {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let stderr = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = helperURL()
        process.arguments = arguments
        var environment = accessEnvironment(dir)
        environment["CAPTURE_HELPER_TEST_INTERRUPT_AFTER_FRAMES"] = "10000"
        process.environment = environment
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr
        try process.run()
        addTeardownBlock {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? stderr.close()
        }
        return process
    }

    private func waitUntil(_ predicate: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(2)
        while try !predicate() {
            if Date() >= deadline {
                XCTFail("capture process did not reach the expected state within 2 seconds")
                throw NSError(domain: "CaptureHelperTests", code: 1)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func assertAccessReleased(_ dir: URL) throws {
        // An invalid command never enumerates windows, but must acquire access
        // before reaching argument validation. This is permission-independent.
        let result = try runCommand(executableURL: helperURL(), arguments: ["record", "--window-id", "1"], environment: accessEnvironment(dir))
        XCTAssertEqual(try parseFirstJSONLine(result.stderr)["code"] as? String, "target_required")
    }

    private func runHelper(_ arguments: [String], simulatedInterruptAfterFrames: Int? = nil,
                           inputCommands: String? = nil, inputEvent: String = "record_ready") throws -> CommandResult {
        var environment: [String: String]? = nil
        if let simulatedInterruptAfterFrames {
            environment = ProcessInfo.processInfo.environment
            environment?["CAPTURE_HELPER_TEST_INTERRUPT_AFTER_FRAMES"] = String(simulatedInterruptAfterFrames)
        }
        return try runCommand(executableURL: helperURL(), arguments: arguments, environment: environment,
                              inputCommands: inputCommands, inputEvent: inputEvent)
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
        environment: [String: String]? = nil,
        inputCommands: String? = nil,
        inputEvent: String = "record_ready"
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let stdin = Pipe()
        if inputCommands != nil { process.standardInput = stdin }

        try process.run()
        // Fail fast instead of hanging the suite if the helper stops exiting on its own.
        let watchdog = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        // Drain both pipes before waiting so binary stdout larger than the pipe buffer cannot block the child.
        var stderrData = Data()
        let stderrDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            var sentCommands = false
            while true {
                let chunk = stderr.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                stderrData.append(chunk)
                if let inputCommands, !sentCommands,
                   String(data: stderrData, encoding: .utf8)?.contains("\"\(inputEvent)\"") == true {
                    sentCommands = true
                    stdin.fileHandleForWriting.write(Data(inputCommands.utf8))
                    stdin.fileHandleForWriting.closeFile()
                }
            }
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

    private func parseJSONEvents(_ text: String) throws -> [[String: Any]] {
        try text.split(separator: "\n")
            .filter { $0.hasPrefix("{") }.map { try parseJSONObject(String($0)) }
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

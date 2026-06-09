import XCTest

final class CaptureHelperTests: XCTestCase {
    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    func testVersionProducesMachineReadableJSON() throws {
        let result = try runHelper(["version"])

        XCTAssertEqual(result.status, 0, result.stderr)
        let object = try parseJSONObject(result.stdout)
        XCTAssertEqual(object["name"] as? String, "@siteed/capture-helper")
        XCTAssertEqual(object["binary"] as? String, "capture-helper")
        XCTAssertEqual(object["version"] as? String, "0.2.0")
        XCTAssertNotNil(object["architecture"])
        XCTAssertNotNil(object["osVersion"])
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
    }

    func testVersionSupportsHumanOutput() throws {
        let result = try runHelper(["version", "--human"])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "capture-helper 0.2.0\n")
    }

    func testVersionSupportsShortHumanOutput() throws {
        let result = try runHelper(["version", "-h"])

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "capture-helper 0.2.0\n")
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

    private func runHelper(_ arguments: [String]) throws -> CommandResult {
        try runCommand(executableURL: helperURL(), arguments: arguments)
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
        process.waitUntilExit()

        let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
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

    private func parseFirstJSONLine(_ text: String) throws -> [String: Any] {
        guard let line = text.split(separator: "\n").first else {
            XCTFail("Expected JSON line, got empty text")
            return [:]
        }
        return try parseJSONObject(String(line))
    }
}

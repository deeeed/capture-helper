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
        XCTAssertEqual(object["version"] as? String, "0.1.0")
        XCTAssertNotNil(object["architecture"])
        XCTAssertNotNil(object["osVersion"])
    }

    func testHelpMentionsResolveAndSnapshot() throws {
        let result = try runHelper(["--help"])

        XCTAssertEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("capture-helper resolve"), result.stderr)
        XCTAssertTrue(result.stderr.contains("capture-helper snapshot"), result.stderr)
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
        let process = Process()
        process.executableURL = helperURL()
        process.arguments = arguments

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

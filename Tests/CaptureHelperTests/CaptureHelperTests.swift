import XCTest

final class CaptureHelperTests: XCTestCase {
    func testPlaceholder() {
        // Most behavior requires macOS Screen Recording permission and a live WindowServer.
        // Keep SwiftPM test target present for future pure parsing/framing tests.
        XCTAssertTrue(true)
    }
}

import XCTest
@testable import LopperApp

final class ToolStatusTests: XCTestCase {
    func testGitVersionIsReadFromItsOutput() {
        XCTAssertEqual(
            ToolStatus.parseGitVersion("git version 2.54.0 (Apple Git-157)\n"),
            "2.54.0 (Apple Git-157)")
        XCTAssertEqual(ToolStatus.parseGitVersion("git version 2.39.5"), "2.39.5")
        XCTAssertNil(ToolStatus.parseGitVersion("command not found"))
        XCTAssertNil(ToolStatus.parseGitVersion(""))
    }

    func testGitHubCLIVersionIsReadFromItsOutput() {
        let output = "gh version 2.98.0 (2026-08-20)\nhttps://github.com/cli/cli/releases/tag/v2.98.0\n"
        XCTAssertEqual(ToolStatus.parseGitHubVersion(output), "2.98.0")
        XCTAssertNil(ToolStatus.parseGitHubVersion("not gh"))
    }
}

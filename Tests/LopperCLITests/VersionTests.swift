import XCTest
@testable import LopperCLI

final class VersionTests: XCTestCase {
    /// The command line tool and the app release together, so their version numbers must not drift apart.
    func testTheCommandLineVersionMatchesTheApp() throws {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/project.yml")
        let text = try String(contentsOf: project, encoding: .utf8)
        let match = try XCTUnwrap(text.range(of: #"MARKETING_VERSION:\s*(\S+)"#, options: .regularExpression))
        let version = text[match].split(separator: " ").last.map(String.init)
        XCTAssertEqual(LopVersion.current, version)
    }
}

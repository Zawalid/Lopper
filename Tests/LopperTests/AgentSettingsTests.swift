import XCTest
@testable import Lopper

final class AgentSettingsTests: XCTestCase {
    func testGraceDefaultsToTwoHoursAndRoundTrips() throws {
        XCTAssertEqual(Settings().agentFinishedGraceMinutes, 120)
        var settings = Settings()
        settings.agentFinishedGraceMinutes = 45
        let back = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.agentFinishedGraceMinutes, 45)
        XCTAssertTrue(back.unknownKeys.isEmpty)
    }

    func testFileWrittenBeforeTheKeyExistedUsesTheDefault() throws {
        let json = #"{"schemaVersion":2,"folders":[],"scanDepth":4}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.agentFinishedGraceMinutes, 120)
    }

    func testNegativeValueFromAHandEditedFileIsClamped() throws {
        let json = #"{"schemaVersion":2,"agentFinishedGraceMinutes":-5}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.agentFinishedGraceMinutes, 0)
    }

    func testChangingTheGraceNeverTriggersARescan() {
        let before = Settings()
        var after = before
        after.agentFinishedGraceMinutes = 10
        XCTAssertFalse(after.requiresRescan(comparedTo: before))
    }
}

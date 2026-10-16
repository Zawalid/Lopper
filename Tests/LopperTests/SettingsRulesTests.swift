import XCTest
@testable import Lopper

final class SettingsRulesTests: XCTestCase {
    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    func testRulesAreOffByDefaultSoNothingIsSuggestedUntilAskedFor() {
        let rules = Settings().rules

        XCTAssertFalse(rules.untouchedFolders.isEnabled)
        XCTAssertFalse(rules.oldMergedBranches.isEnabled)
        XCTAssertEqual(rules.untouchedFolders.days, 30)
        XCTAssertEqual(rules.oldMergedBranches.days, 14)
    }

    func testAFileWrittenBeforeRulesExistedStillLoadsWithTheDefaults() throws {
        let settings = try decode(#"{ "schemaVersion" : 2, "scanDepth" : 5, "staleDays" : 21 }"#)

        XCTAssertEqual(settings.rules, Settings.Rules())
        XCTAssertEqual(settings.scanDepth, 5)
    }

    func testRulesSurviveASaveAndLoad() throws {
        var settings = Settings()
        settings.rules.untouchedFolders = .init(isEnabled: true, days: 45)
        settings.rules.oldMergedBranches = .init(isEnabled: true, days: 7)

        let data = try JSONEncoder().encode(settings)
        let loaded = try JSONDecoder().decode(Settings.self, from: data)

        XCTAssertEqual(loaded.rules.untouchedFolders, .init(isEnabled: true, days: 45))
        XCTAssertEqual(loaded.rules.oldMergedBranches, .init(isEnabled: true, days: 7))
    }

    func testNonsenseDaysAreClampedToAWholeYearOrAtLeastOne() throws {
        let settings = try decode("""
        { "rules" : { "untouchedFolders" : { "isEnabled" : true, "days" : 0 },
                      "oldMergedBranches" : { "isEnabled" : true, "days" : 99999 } } }
        """)

        XCTAssertEqual(settings.rules.untouchedFolders.days, 1)
        XCTAssertEqual(settings.rules.oldMergedBranches.days, 365)
    }

    func testAHalfWrittenRuleKeepsTheRestAtDefaults() throws {
        let settings = try decode(#"{ "rules" : { "untouchedFolders" : { "isEnabled" : true } } }"#)

        XCTAssertTrue(settings.rules.untouchedFolders.isEnabled)
        XCTAssertEqual(settings.rules.untouchedFolders.days, 30)
        XCTAssertFalse(settings.rules.oldMergedBranches.isEnabled)
    }

    func testChangingRulesNeverTriggersARescan() {
        let before = Settings()
        var after = before
        after.rules.untouchedFolders.isEnabled = true

        XCTAssertFalse(after.requiresRescan(comparedTo: before))
    }
}

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

    // MARK: Hiding repositories needs no rescan

    func testHidingRepositoriesIsRecognisedWhenItIsTheOnlyChange() {
        let before = Settings(roots: [URL(fileURLWithPath: "/code")])
        var after = before
        after.repos["/code/a", default: RepoOverrides()].isIgnored = true
        after.repos["/code/b", default: RepoOverrides()].isIgnored = true

        XCTAssertEqual(after.newlyHiddenRepositories(comparedTo: before), ["/code/a", "/code/b"])
        XCTAssertTrue(after.requiresRescan(comparedTo: before), "the settings did change; only the loaded results can be reused")
    }

    func testAnyOtherChangeAlongsideHidingMeansARealRescan() {
        let before = Settings(roots: [URL(fileURLWithPath: "/code")])
        var withDepth = before
        withDepth.repos["/code/a", default: RepoOverrides()].isIgnored = true
        withDepth.scanDepth = 6
        var withBranch = before
        withBranch.repos["/code/a", default: RepoOverrides()].isIgnored = true
        withBranch.repos["/code/other", default: RepoOverrides()].defaultBranch = "develop"

        XCTAssertNil(withDepth.newlyHiddenRepositories(comparedTo: before))
        XCTAssertNil(withBranch.newlyHiddenRepositories(comparedTo: before))
    }

    func testShowingOrNotChangingAnythingIsNotAHide() {
        var hidden = Settings(roots: [URL(fileURLWithPath: "/code")])
        hidden.repos["/code/a", default: RepoOverrides()].isIgnored = true
        var shown = hidden
        shown.repos["/code/a"] = nil

        XCTAssertNil(shown.newlyHiddenRepositories(comparedTo: hidden), "bringing one back needs it scanned")
        XCTAssertNil(hidden.newlyHiddenRepositories(comparedTo: hidden), "nothing new was hidden")
    }
}

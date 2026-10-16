import XCTest
import Lopper
@testable import LopperApp

@MainActor
final class RuleSuggestionsTests: XCTestCase {
    private let now = Fixtures.now
    private func days(_ n: Int) -> Date { now.addingTimeInterval(-Double(n) * 86_400) }

    private func rows() -> [CleanupRow] {
        let snapshot = Fixtures.snapshot(branches: [
            Fixtures.branch("feat/old-merged", .safe, ageDays: 40),
            Fixtures.branch("feat/fresh-merged", .safe, ageDays: 3),
            Fixtures.branch("feat/old-unmerged", .review, ageDays: 90),
            Fixtures.branch("main", .protected, ageDays: 1),
        ])
        return RowMapper.rows(for: snapshot, sizes: [:], now: now)
    }

    private func artifact(_ name: String, bytes: Int64, in checkout: String, removal: ArtifactRemoval = .offered(regenerate: "npm ci")) -> DiskArtifact {
        let root = URL(fileURLWithPath: checkout)
        return DiskArtifact(
            path: root.appendingPathComponent(name), name: name, kind: .packages, bytes: bytes, newestModification: nil,
            projectDirectory: root, checkoutRoot: root, repoRoot: Fixtures.root, location: .mainCheckout, removal: removal)
    }

    private func projects() -> [DiskProject] {
        let items = [
            artifact("node_modules", bytes: 900, in: "/code/idle"),
            artifact("build", bytes: 100, in: "/code/idle", removal: .blocked(reason: "unknown")),
            artifact("node_modules", bytes: 500, in: "/code/busy"),
        ]
        let sizes = [
            "/code/idle": DiskUsage(total: 5_000, disposable: 0, newestModification: days(60)),
            "/code/busy": DiskUsage(total: 5_000, disposable: 0, newestModification: days(2)),
        ]
        return DiskInsights.projects(artifacts: items, sizes: sizes)
    }

    func testNothingIsSuggestedWhileTheRulesAreOff() {
        let found = RuleEvaluator.suggestions(
            rules: Settings.Rules(), projects: projects(), rows: rows(), isSnoozed: { _ in false }, now: now)

        XCTAssertTrue(found.isEmpty)
    }

    func testTheFolderRuleSuggestsOnlyWhatCanBeClearedInIdleProjects() throws {
        var rules = Settings.Rules()
        rules.untouchedFolders = .init(isEnabled: true, days: 30)

        let found = RuleEvaluator.suggestions(
            rules: rules, projects: projects(), rows: rows(), isSnoozed: { _ in false }, now: now)

        let folders = try XCTUnwrap(found.first { $0.kind == .untouchedFolders })
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(folders.count, 1, "the blocked build folder and the busy project are left out")
        XCTAssertEqual(folders.bytes, 900)
        XCTAssertEqual(folders.artifactIDs, ["/code/idle/node_modules"])
        XCTAssertTrue(folders.title.contains("1"), folders.title)
        XCTAssertTrue(folders.detail.contains("30"), folders.detail)
    }

    func testRaisingTheDaysDropsProjectsThatAreNotIdleLongEnough() {
        var rules = Settings.Rules()
        rules.untouchedFolders = .init(isEnabled: true, days: 90)

        XCTAssertTrue(RuleEvaluator.suggestions(
            rules: rules, projects: projects(), rows: rows(), isSnoozed: { _ in false }, now: now).isEmpty)
    }

    func testTheBranchRuleSuggestsMergedBranchesOlderThanTheLimitOnly() throws {
        var rules = Settings.Rules()
        rules.oldMergedBranches = .init(isEnabled: true, days: 14)

        let found = RuleEvaluator.suggestions(
            rules: rules, projects: [], rows: rows(), isSnoozed: { _ in false }, now: now)

        let branches = try XCTUnwrap(found.first { $0.kind == .oldMergedBranches })
        XCTAssertEqual(branches.count, 1, "not the fresh one, not the unmerged one, not main")
        XCTAssertEqual(branches.rowIDs.count, 1)
        XCTAssertTrue(branches.rowIDs[0].hasSuffix("feat/old-merged"))
    }

    func testASnoozedBranchIsNotSuggested() {
        var rules = Settings.Rules()
        rules.oldMergedBranches = .init(isEnabled: true, days: 14)

        let found = RuleEvaluator.suggestions(
            rules: rules, projects: [], rows: rows(), isSnoozed: { $0.title == "feat/old-merged" }, now: now)

        XCTAssertTrue(found.isEmpty)
    }

    func testTheModelOffersTheSuggestionAndOpensTheSameReviewSheetsAsEverywhereElse() async {
        let snapshot = Fixtures.snapshot(branches: [Fixtures.branch("feat/old-merged", .safe, ageDays: 40)])
        let model = AppModel.preview(snapshots: [snapshot], artifacts: [], clock: { Fixtures.now })
        model.updateSettings { $0.rules.oldMergedBranches = .init(isEnabled: true, days: 14) }

        let suggestion = model.ruleSuggestions.first { $0.kind == .oldMergedBranches }
        XCTAssertEqual(suggestion?.count, 1)

        model.review(suggestion!)

        XCTAssertEqual(model.clean?.rows.map(\.title), ["feat/old-merged"])
    }
}

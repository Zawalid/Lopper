import XCTest
import Lopper
@testable import LopperApp

final class RowSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let root = URL(fileURLWithPath: "/code/api")

    private func row(
        _ id: String, _ verdict: VerdictKind = .safe, daysOld: Int? = 10, megabytes: Int64? = 10, tool: String? = nil,
        kind: CleanupRow.Kind = .worktree, strong: Bool = false, dirty: Bool = false, extra: [String] = []
    ) -> CleanupRow {
        CleanupRow(
            id: id, kind: kind, repoRoot: root, repoName: "api", title: id, location: "", path: nil, verdict: verdict,
            reasons: [], evidence: "", prNumber: nil, prURL: nil,
            lastCommit: daysOld.map { now.addingTimeInterval(-Double($0) * 86_400) }, size: megabytes.map { $0 * 1_048_576 },
            agentHint: tool, extraFiles: extra, bundledBranch: nil,
            facts: RowFacts(evidence: strong ? .ancestorOfDefault : .none, isDirty: dirty))
    }

    // MARK: Ranges and the header

    func testARangeRunsFromTheAnchorToTheTargetInEitherDirection() {
        let order = ["a", "b", "c", "d", "e"]

        XCTAssertEqual(RowSelection.range(from: "b", to: "d", in: order), ["b", "c", "d"])
        XCTAssertEqual(RowSelection.range(from: "d", to: "b", in: order), ["b", "c", "d"])
        XCTAssertEqual(RowSelection.range(from: "c", to: "c", in: order), ["c"])
    }

    func testARangeFromARowThatIsNotShownGivesJustTheTarget() {
        XCTAssertEqual(RowSelection.range(from: "gone", to: "b", in: ["a", "b", "c"]), ["b"])
    }

    func testTheHeaderCheckboxShowsNoneSomeOrAll() {
        let selectable = ["a", "b", "c"]

        XCTAssertEqual(RowSelection.headerState(selection: [], selectable: selectable), .none)
        XCTAssertEqual(RowSelection.headerState(selection: ["a"], selectable: selectable), .some)
        XCTAssertEqual(RowSelection.headerState(selection: ["a", "b", "c", "hidden"], selectable: selectable), .all)
        XCTAssertEqual(RowSelection.headerState(selection: ["a"], selectable: []), .none, "nothing to pick means nothing is checked")
    }

    // MARK: Presets

    func testAllShownPicksEveryRowThatCanBeCleanedAndNeverAProtectedOne() {
        let rows = [row("safe"), row("review", .review), row("locked", .protected)]

        let picked = RowSelection.apply(.allVisible, rows: rows, current: ["old"], now: now)

        XCTAssertEqual(picked, ["safe", "review"], "a preset replaces the selection and skips protected rows")
    }

    func testNoneClearsEverythingIncludingRowsAFilterIsHiding() {
        XCTAssertEqual(RowSelection.apply(.none, rows: [row("a")], current: ["a", "hidden"], now: now), [])
    }

    func testInvertFlipsTheShownRowsAndLeavesHiddenOnesAlone() {
        let rows = [row("a"), row("b"), row("c")]

        let picked = RowSelection.apply(.invert, rows: rows, current: ["a", "hidden"], now: now)

        XCTAssertEqual(picked, ["hidden", "b", "c"])
    }

    @MainActor
    func testOnlySafeLeavesOutAWorktreeAnAgentMayStillBeUsing() {
        let measured = Fixtures.agentMeasurements
        let model = AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: measured.sizes, activity: measured.activity, route: .agents,
            clock: { Fixtures.now })
        let rows = model.allRows

        let picked = RowSelection.apply(.onlySafe, rows: rows, current: [], now: Fixtures.now)
        let titles = Set(rows.filter { picked.contains($0.id) }.map(\.title))

        XCTAssertEqual(titles, ["claude/finished-a", "claude/finished-b"])
        XCTAssertFalse(titles.contains("claude/just-now"), "an agent worktree touched a moment ago may still be in use")
        XCTAssertFalse(titles.contains("claude/release"), "a protected row is never picked")
    }

    func testOlderThanUsesTheLastCommitAndIgnoresRowsWithNoDate() {
        let rows = [row("new", daysOld: 5), row("month", daysOld: 45), row("old", daysOld: 200), row("undated", daysOld: nil)]

        XCTAssertEqual(RowSelection.apply(.olderThan30Days, rows: rows, current: [], now: now), ["month", "old"])
        XCTAssertEqual(RowSelection.apply(.olderThan90Days, rows: rows, current: [], now: now), ["old"])
    }

    func testLargerThanUsesTheSizeAndIgnoresRowsNotMeasuredYet() {
        let rows = [row("small", megabytes: 5), row("big", megabytes: 150), row("exact", megabytes: 100), row("unmeasured", megabytes: nil)]

        XCTAssertEqual(RowSelection.apply(.largerThan100MB, rows: rows, current: [], now: now), ["big", "exact"])
    }

    func testMergedAndCleanPresetsUseWhatLopperCouldProve() {
        let rows = [
            row("merged", strong: true), row("unmerged"), row("dirty", strong: true, dirty: true),
            row("untracked", strong: true, extra: ["notes.txt"]),
        ]

        XCTAssertEqual(RowSelection.apply(.mergedIntoDefault, rows: rows, current: [], now: now), ["merged", "dirty", "untracked"])
        XCTAssertEqual(RowSelection.apply(.noUncommittedFiles, rows: rows, current: [], now: now), ["merged", "unmerged"])
    }

    // MARK: Like this

    func testARowOffersTheThingsItSharesWithOthers() {
        let target = row("a", .review, daysOld: 40, tool: "Claude Code", kind: .worktree)

        let offered = RowSelection.affinities(of: target, now: now)

        XCTAssertEqual(offered, [.verdict(.review), .tool("Claude Code"), .ageBucket(.thisQuarter), .kind(.worktree)])
        XCTAssertEqual(RowSelection.affinities(of: row("b"), now: now).count, 3, "a row no tool made offers no tool")
    }

    func testSelectingLikeThisPicksOnlyMatchingRowsThatCanBeCleaned() {
        let rows = [
            row("claude1", tool: "Claude Code"), row("claude2", .review, tool: "Claude Code"),
            row("claudeLocked", .protected, tool: "Claude Code"), row("codex", tool: "Codex"),
        ]

        let picked = RowSelection.rows(sharing: .tool("Claude Code"), among: rows, now: now).map(\.id)

        XCTAssertEqual(picked, ["claude1", "claude2"])
        XCTAssertEqual(RowSelection.rows(sharing: .verdict(.review), among: rows, now: now).map(\.id), ["claude2"])
    }

    func testAgeBucketsFollowTheirBoundaries() {
        func bucket(_ days: Int?) -> SelectionAffinity.AgeBucket { RowSelection.ageBucket(of: row("x", daysOld: days), now: now) }

        XCTAssertEqual(bucket(0), .thisWeek)
        XCTAssertEqual(bucket(6), .thisWeek)
        XCTAssertEqual(bucket(7), .thisMonth)
        XCTAssertEqual(bucket(29), .thisMonth)
        XCTAssertEqual(bucket(30), .thisQuarter)
        XCTAssertEqual(bucket(90), .older)
        XCTAssertEqual(bucket(nil), .unknown)
    }

    func testMenuTitlesCarryTheCount() {
        XCTAssertEqual(SelectionAffinity.tool("Codex").title(count: 3), "Select all 3 from Codex")
        XCTAssertEqual(SelectionAffinity.verdict(.review).title(count: 12), "Select all 12 Review")
        XCTAssertEqual(SelectionAffinity.kind(.worktree).title(count: 4), "Select all 4 worktrees")
    }

    // MARK: Summary

    func testTheSummaryCountsSafeAndReviewSumsSizeAndSeparatesHiddenAndProtected() {
        let all = [
            row("a", megabytes: 10), row("b", .review, megabytes: 20), row("hiddenOne", megabytes: 30),
            row("locked", .protected, megabytes: 40), row("notPicked"),
        ]

        let summary = RowSelection.summary(
            selection: ["a", "b", "hiddenOne", "locked"], allRows: all, shownIDs: ["a", "b", "locked", "notPicked"])

        XCTAssertEqual(summary.count, 3, "protected rows are not counted as cleanable")
        XCTAssertEqual(summary.safe, 2)
        XCTAssertEqual(summary.review, 1)
        XCTAssertEqual(summary.bytes, 60 * 1_048_576)
        XCTAssertEqual(summary.hidden, 1)
        XCTAssertEqual(summary.skipped, 1)
    }

    func testTheSummaryCountsSelectedWorktreesThatMayHoldWorkOnlyInTheirFolder() {
        let all = [
            row("clean"), row("modified", .review, dirty: true), row("untracked", .review, extra: ["notes.md"]),
            row("branch", .review, kind: .branch, dirty: true), row("locked", .protected, dirty: true),
            row("notPicked", .review, dirty: true),
        ]

        let summary = RowSelection.summary(
            selection: ["clean", "modified", "untracked", "branch", "locked"], allRows: all, shownIDs: Set(all.map(\.id)))

        XCTAssertEqual(summary.folderOnlyWork, 2, "only picked, cleanable worktrees with changes or untracked files count")
        XCTAssertEqual(RowSelection.foldersWithOnlyWork(selection: ["clean", "modified", "untracked"], allRows: all), ["modified", "untracked"])
    }

    func testAnEmptySelectionSaysSo() {
        XCTAssertTrue(RowSelection.summary(selection: [], allRows: [row("a")], shownIDs: ["a"]).isEmpty)
    }
}

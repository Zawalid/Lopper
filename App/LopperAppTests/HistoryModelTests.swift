import XCTest
import Lopper
@testable import LopperApp

final class HistoryModelTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC

    private func record(
        _ action: UndoAction, branch: String? = "feat/a", repo: String = "/code/api", daysAgo: Double = 1,
        status: UndoStatus = .completed, batch: UUID? = nil, reason: String? = nil, bytes: Int64? = nil,
        worktree: String? = nil
    ) -> UndoRecord {
        UndoRecord(
            timestamp: now.addingTimeInterval(-daysAgo * 86_400), repoPath: repo, action: action, branch: branch,
            tip: "abc", upstream: nil,
            worktreePath: action == .removeWorktree ? (worktree ?? "/code/wt/\(branch ?? "x")") : nil,
            trashRef: "refs/lopper/\(UUID().uuidString)", status: status, batchID: batch, reason: reason, bytes: bytes)
    }

    // MARK: Entries

    func testAWorktreeAndItsBranchBecomeOneEntryRestoredBranchFirst() {
        let batch = UUID()
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "feat/a", batch: batch, reason: "Merged via PR #54", bytes: 900),
            record(.deleteBranch, branch: "feat/a", batch: batch),
        ])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .worktree)
        XCTAssertEqual(entries[0].title, "feat/a")
        XCTAssertEqual(entries[0].reason, "Merged via PR #54")
        XCTAssertEqual(entries[0].bytes, 900)
        XCTAssertEqual(entries[0].records.map(\.action), [.deleteBranch, .removeWorktree])
        XCTAssertFalse(entries[0].keptBranch)
    }

    func testAClearedFolderIsItsOwnEntryNamedAfterTheFolder() {
        let batch = UUID()
        let folder = UndoRecord(
            timestamp: now, repoPath: "/code/api", action: .trashFolder, branch: nil, tip: "", upstream: nil,
            worktreePath: "/code/api/node_modules", trashRef: "", status: .completed, batchID: batch,
            reason: "Installed packages", bytes: 1_200, trashedPath: "/Users/me/.Trash/node_modules")

        let entries = HistoryBuilder.entries(from: [folder])

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].kind, .folder)
        XCTAssertEqual(entries[0].title, "node_modules")
        XCTAssertEqual(entries[0].reason, "Installed packages")
        XCTAssertEqual(entries[0].bytes, 1_200)
        XCTAssertEqual(entries[0].status, .removed)
        XCTAssertTrue(entries[0].canRestore)
    }

    func testAWorktreeWithoutABranchDeletionKeptItsBranch() {
        let entries = HistoryBuilder.entries(from: [record(.removeWorktree, branch: "feat/spike", batch: UUID())])

        XCTAssertTrue(entries[0].keptBranch)
    }

    func testADetachedWorktreeIsNamedAfterItsFolder() {
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: nil, batch: UUID(), worktree: "/code/wt/try-layout"),
        ])

        XCTAssertEqual(entries[0].title, "try-layout")
        XCTAssertFalse(entries[0].keptBranch, "there was no branch to keep")
    }

    func testPendingAndFailedRecordsAreNotHistory() {
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "a", status: .pending),
            record(.deleteBranch, branch: "b", status: .failed),
            record(.deleteBranch, branch: "c"),
        ])

        XCTAssertEqual(entries.map(\.title), ["c"])
    }

    func testStatusFollowsTheRecords() {
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "removed"),
            record(.deleteBranch, branch: "back", status: .restored),
            record(.deleteBranch, branch: "late", status: .expired),
        ])
        let byTitle = Dictionary(uniqueKeysWithValues: entries.map { ($0.title, $0) })

        XCTAssertEqual(byTitle["removed"]?.status, .removed)
        XCTAssertEqual(byTitle["back"]?.status, .restored)
        XCTAssertEqual(byTitle["late"]?.status, .expired)
        XCTAssertEqual(byTitle["removed"]?.canRestore, true)
        XCTAssertEqual(byTitle["back"]?.canRestore, false)
        XCTAssertEqual(byTitle["late"]?.canRestore, false)
    }

    func testAPartlyRestoredPairIsStillRestorable() {
        let batch = UUID()
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "feat/a", status: .restored, batch: batch),
            record(.deleteBranch, branch: "feat/a", status: .completed, batch: batch),
        ])

        XCTAssertEqual(entries[0].status, .removed)
        XCTAssertEqual(entries[0].records.filter { $0.status == .completed }.count, 1)
    }

    func testNewestEntryComesFirst() {
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "old", daysAgo: 9),
            record(.deleteBranch, branch: "new", daysAgo: 1),
        ])

        XCTAssertEqual(entries.map(\.title), ["new", "old"])
    }

    // MARK: Batches

    func testEntriesOfOneActionShareABatchWithTheirTotals() {
        let batch = UUID()
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "a", batch: batch, bytes: 100),
            record(.removeWorktree, branch: "b", batch: batch, bytes: 50),
            record(.deleteBranch, branch: "c", batch: UUID()),
        ])
        let batches = HistoryBuilder.batches(from: entries)

        XCTAssertEqual(batches.count, 2)
        let big = batches.first { $0.entries.count == 2 }
        XCTAssertEqual(big?.bytes, 150)
        XCTAssertEqual(big?.restorableCount, 2)
    }

    // MARK: Filter

    private func sample() -> [HistoryEntry] {
        HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "feat/landing", repo: "/code/web", daysAgo: 0.2, reason: "Merged via PR #54"),
            record(.deleteBranch, branch: "fix/api-typo", repo: "/code/api", daysAgo: 3, reason: "Already part of the default branch"),
            record(.deleteBranch, branch: "chore/old", repo: "/code/api", daysAgo: 40, status: .expired),
            record(.deleteBranch, branch: "feat/search", repo: "/code/web", daysAgo: 2, status: .restored),
        ])
    }

    func testSearchMatchesNameRepositoryAndReasonIgnoringCase() {
        let all = sample()

        XCTAssertEqual(HistoryFilter(query: "LANDING").apply(to: all, now: now).map(\.title), ["feat/landing"])
        XCTAssertEqual(Set(HistoryFilter(query: "api").apply(to: all, now: now).map(\.title)), ["fix/api-typo", "chore/old"])
        XCTAssertEqual(HistoryFilter(query: "pr #54").apply(to: all, now: now).map(\.title), ["feat/landing"])
        XCTAssertTrue(HistoryFilter(query: "nothing like this").apply(to: all, now: now).isEmpty)
    }

    func testRepositoryRangeAndStatusFiltersCombine() {
        let all = sample()

        XCTAssertEqual(HistoryFilter(repoPath: "/code/web").apply(to: all, now: now).count, 2)
        XCTAssertEqual(HistoryFilter(range: .week).apply(to: all, now: now).count, 3)
        XCTAssertEqual(HistoryFilter(range: .month).apply(to: all, now: now).count, 3)
        XCTAssertEqual(HistoryFilter(range: .day).apply(to: all, now: now).map(\.title), ["feat/landing"])
        XCTAssertEqual(HistoryFilter(status: .restored).apply(to: all, now: now).map(\.title), ["feat/search"])
        XCTAssertEqual(
            HistoryFilter(repoPath: "/code/web", range: .week, status: .removed).apply(to: all, now: now).map(\.title),
            ["feat/landing"])
    }

    func testAnEmptyFilterChangesNothingAndSaysSo() {
        XCTAssertTrue(HistoryFilter().isEmpty)
        XCTAssertFalse(HistoryFilter(query: "x").isEmpty)
        XCTAssertEqual(HistoryFilter().apply(to: sample(), now: now).count, 4)
    }

    func testRepositoriesForThePickerAreDistinctAndSorted() {
        let repos = HistoryBuilder.repositories(in: sample())

        XCTAssertEqual(repos.map(\.name), ["api", "web"])
        XCTAssertEqual(repos.map(\.path), ["/code/api", "/code/web"])
    }

    // MARK: Summary

    func testSummaryCountsTheLastThirtyDaysAndWhatCanStillComeBack() {
        let batch = UUID()
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "a", daysAgo: 1, batch: batch, bytes: 2_000_000),
            record(.deleteBranch, branch: "a", daysAgo: 1, batch: batch),
            record(.deleteBranch, branch: "b", daysAgo: 10),
            record(.deleteBranch, branch: "c", daysAgo: 12, status: .restored),
            record(.deleteBranch, branch: "old", daysAgo: 45, status: .expired),
        ])

        let summary = HistoryBuilder.summary(of: entries, retentionDays: 30, now: now)

        XCTAssertEqual(summary.removedLast30Days, 2, "restored and older items are not 'removed this month'")
        XCTAssertEqual(summary.bytesLast30Days, 2_000_000)
        XCTAssertEqual(summary.restorable, 2)
        XCTAssertEqual(summary.restoredLast30Days, 1)
        // The oldest restorable item (10 days old) is the next to expire, 20 days from now.
        XCTAssertEqual(summary.nextExpiry, now.addingTimeInterval(-10 * 86_400 + 30 * 86_400))
    }

    func testSummaryOfNothingIsAllZero() {
        let summary = HistoryBuilder.summary(of: [], retentionDays: 30, now: now)

        XCTAssertEqual(summary.removedLast30Days, 0)
        XCTAssertEqual(summary.restorable, 0)
        XCTAssertNil(summary.nextExpiry)
    }

    // MARK: Days

    func testDayTitlesReadTodayYesterdayThenADate() {
        XCTAssertEqual(HistoryBuilder.dayTitle(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(
            HistoryBuilder.dayTitle(for: now.addingTimeInterval(-86_400), now: now, calendar: calendar), "Yesterday")
        let older = HistoryBuilder.dayTitle(for: now.addingTimeInterval(-5 * 86_400), now: now, calendar: calendar)
        XCTAssertFalse(older == "Today" || older == "Yesterday")
        XCTAssertTrue(older.contains("10"), older)
    }

    func testBatchesAreGroupedUnderTheirDayNewestFirst() {
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "a", daysAgo: 0.1),
            record(.deleteBranch, branch: "b", daysAgo: 0.2),
            record(.deleteBranch, branch: "c", daysAgo: 2),
        ])
        let days = HistoryBuilder.days(from: HistoryBuilder.batches(from: entries), now: now, calendar: calendar)

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].title, "Today")
        XCTAssertEqual(days[0].batches.count, 2)
    }

    func testRestoreTimeLeftIsReadableAndNeverNegative() {
        let entry = HistoryBuilder.entries(from: [record(.deleteBranch, branch: "a", daysAgo: 25)])[0]

        XCTAssertEqual(HistoryBuilder.daysLeft(for: entry, retentionDays: 30, now: now), 5)
        XCTAssertEqual(HistoryBuilder.daysLeft(for: entry, retentionDays: 10, now: now), 0)
    }

    // MARK: Table and inspector support

    func testTableLabelsNameTheKindAndSortUnmeasuredSizesLast() {
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "a", bytes: nil),
            record(.removeWorktree, branch: "b", bytes: 10),
        ])
        let branch = entries.first { $0.kind == .branch }
        let worktree = entries.first { $0.kind == .worktree }

        XCTAssertEqual(branch?.kindLabel, "Branch")
        XCTAssertEqual(worktree?.kindLabel, "Worktree")
        XCTAssertEqual(branch?.sizeSort, -1)
        XCTAssertEqual(worktree?.sizeSort, 10)
    }

    func testRemovedLabelReadsTodayYesterdayThenTheDate() {
        let today = now.addingTimeInterval(-60)
        let yesterday = now.addingTimeInterval(-86_400)
        let older = now.addingTimeInterval(-5 * 86_400)

        XCTAssertTrue(HistoryBuilder.removedLabel(for: today, now: now, calendar: calendar).hasPrefix("Today"))
        XCTAssertTrue(HistoryBuilder.removedLabel(for: yesterday, now: now, calendar: calendar).hasPrefix("Yesterday"))
        let label = HistoryBuilder.removedLabel(for: older, now: now, calendar: calendar)
        XCTAssertFalse(label.hasPrefix("Today") || label.hasPrefix("Yesterday"))
        XCTAssertTrue(label.contains("10"), label)   // 2027-01-10
    }

    func testSummaryLineIsOneShortSentenceOfTheNumbersThatMatter() {
        var summary = HistorySummary()
        summary.removedLast30Days = 11
        summary.bytesLast30Days = 1_670_000_000
        summary.restorable = 9

        let line = HistoryBuilder.summaryLine(summary)

        XCTAssertTrue(line.hasPrefix("11 removed in 30 days"), line)
        XCTAssertTrue(line.contains("freed"), line)
        XCTAssertTrue(line.hasSuffix("9 can be restored"), line)
        XCTAssertEqual(HistoryBuilder.summaryLine(HistorySummary()), "Nothing removed in the last 30 days")
    }

    func testTheCleanupAnEntryBelongsToListsTheOthersThatCanStillComeBack() {
        let batch = UUID()
        let entries = HistoryBuilder.entries(from: [
            record(.deleteBranch, branch: "a", batch: batch),
            record(.deleteBranch, branch: "b", batch: batch),
            record(.deleteBranch, branch: "c", status: .restored, batch: batch),
            record(.deleteBranch, branch: "alone", batch: UUID()),
        ])
        let first = entries.first { $0.title == "a" }!
        let alone = entries.first { $0.title == "alone" }!

        let cleanup = HistoryBuilder.cleanup(containing: first, in: entries)

        XCTAssertEqual(cleanup?.entries.count, 3)
        XCTAssertEqual(cleanup?.restorableCount, 2)
        XCTAssertNil(HistoryBuilder.cleanup(containing: alone, in: entries), "a single removal is not a cleanup")
    }

    // MARK: Freed over time

    func testWeeklyFreedBucketsRemovalsByWeekOldestFirstWithEmptyWeeksKept() {
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "a", daysAgo: 1, bytes: 100),
            record(.removeWorktree, branch: "b", daysAgo: 2, bytes: 50),
            record(.removeWorktree, branch: "c", daysAgo: 16, bytes: 400),
            record(.removeWorktree, branch: "back", daysAgo: 1, status: .restored, bytes: 999),
        ])

        let weeks = HistoryBuilder.weeklyFreed(entries: entries, now: now, weeks: 4, calendar: calendar)

        XCTAssertEqual(weeks.count, 4)
        XCTAssertEqual(weeks.map(\.start), weeks.map(\.start).sorted(), "oldest first")
        XCTAssertEqual(weeks.last?.bytes, 150, "restored removals free nothing")
        XCTAssertEqual(weeks.last?.count, 2)
        XCTAssertEqual(weeks.reduce(0) { $0 + $1.bytes }, 550)
        XCTAssertTrue(weeks.contains { $0.bytes == 0 }, "quiet weeks stay on the axis")
    }

    func testWeeklyFreedIgnoresRemovalsOlderThanTheWindow() {
        let entries = HistoryBuilder.entries(from: [
            record(.removeWorktree, branch: "old", daysAgo: 200, bytes: 1_000),
        ])

        let weeks = HistoryBuilder.weeklyFreed(entries: entries, now: now, weeks: 8, calendar: calendar)

        XCTAssertEqual(weeks.reduce(0) { $0 + $1.bytes }, 0)
    }
}

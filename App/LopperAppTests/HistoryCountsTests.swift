import XCTest
import Lopper
@testable import LopperApp

final class HistoryCountsTests: XCTestCase {
    private let batch = UUID()

    private func record(
        _ action: UndoAction, branch: String?, repo: String = "/code/api", batch: UUID? = nil,
        status: UndoStatus = .completed
    ) -> UndoRecord {
        UndoRecord(
            timestamp: Date(), repoPath: repo, action: action, branch: branch, tip: "abc", upstream: nil,
            worktreePath: action == .removeWorktree ? "/code/wt/\(branch ?? "x")" : nil,
            trashRef: "refs/lopper/\(UUID().uuidString)", status: status, batchID: batch)
    }

    func testAWorktreeAndItsBranchAreOneItem() {
        let records = [
            record(.removeWorktree, branch: "feat/a", batch: batch),
            record(.deleteBranch, branch: "feat/a", batch: batch),
        ]

        XCTAssertEqual(HistoryCounts.items(in: records), 1)
    }

    func testAnUnrelatedBranchDeletionIsItsOwnItem() {
        let records = [
            record(.removeWorktree, branch: "feat/a", batch: batch),
            record(.deleteBranch, branch: "feat/a", batch: batch),
            record(.deleteBranch, branch: "feat/b", batch: batch),
        ]

        XCTAssertEqual(HistoryCounts.items(in: records), 2)
    }

    func testTheSameBranchNameInAnotherRepositoryIsNotMerged() {
        let records = [
            record(.removeWorktree, branch: "feat/a", repo: "/code/api", batch: batch),
            record(.deleteBranch, branch: "feat/a", repo: "/code/web", batch: batch),
        ]

        XCTAssertEqual(HistoryCounts.items(in: records), 2)
    }

    func testTheSameBranchInADifferentBatchIsNotMerged() {
        let records = [
            record(.removeWorktree, branch: "feat/a", batch: UUID()),
            record(.deleteBranch, branch: "feat/a", batch: UUID()),
        ]

        XCTAssertEqual(HistoryCounts.items(in: records), 2)
    }

    func testRecordsWithoutABatchAreCountedOneByOne() {
        let records = [
            record(.removeWorktree, branch: "feat/a"),
            record(.deleteBranch, branch: "feat/a"),
        ]

        XCTAssertEqual(HistoryCounts.items(in: records), 2)
    }

    func testEmptyIsZero() {
        XCTAssertEqual(HistoryCounts.items(in: []), 0)
    }
}

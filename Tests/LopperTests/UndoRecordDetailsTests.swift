import XCTest
@testable import Lopper

final class UndoRecordDetailsTests: XCTestCase {
    private func makeCleaner(_ repo: TestRepo) -> (Cleaner, UndoLog) {
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        return (Cleaner(inspector: RepoInspector(), undoLog: log), log)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return repo
    }

    // MARK: Compatibility

    func testALogLineFromBeforeTheseFieldsExistedStillLoads() throws {
        let line = """
        {"action":"deleteBranch","branch":"feat/x","id":"08371A81-D240-4C1D-AEEB-48B584677A16",\
        "repoPath":"/code/api","status":"completed","timestamp":"2026-10-01T10:00:00Z","tip":"abc",\
        "trashRef":"refs/lopper/trash/1/feat/x"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let record = try decoder.decode(UndoRecord.self, from: Data(line.utf8))

        XCTAssertNil(record.reason)
        XCTAssertNil(record.bytes)
        XCTAssertEqual(record.branch, "feat/x")
    }

    func testReasonAndSizeSurviveTheLog() async throws {
        let log = UndoLog(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-undo-\(UUID().uuidString).jsonl"))
        let record = UndoRecord(
            timestamp: Date(), repoPath: "/code/api", action: .removeWorktree, branch: "feat/x", tip: "abc",
            upstream: nil, worktreePath: "/code/wt/x", trashRef: "refs/lopper/r", status: .completed,
            reason: "Merged via PR #54", bytes: 1_240_000_000)

        try await log.append(record)
        let read = await log.all()

        XCTAssertEqual(read.first?.reason, "Merged via PR #54")
        XCTAssertEqual(read.first?.bytes, 1_240_000_000)
    }

    // MARK: The cleaner records why

    func testARemovedBranchRecordsTheEvidenceThatMadeItSafe() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "done")
        try repo.commit("work", files: ["w.txt": "w"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "done", approved: .safe)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.reason, "Already part of the default branch")
    }

    func testAReviewItemRemovedOnApprovalSaysThereWasNoMergeEvidence() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "abandoned")
        try repo.commit("only copy", files: ["w.txt": "w"])
        try repo.git("checkout", "main")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.deleteBranch(repoRoot: repo.root, name: "abandoned", approved: .review)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.reason, "No merge evidence")
    }

    func testARemovedWorktreeRecordsTheSizeItWasGiven() async throws {
        let repo = try baseRepo()
        let worktree = repo.sandbox.appendingPathComponent("wt-done")
        try repo.git("worktree", "add", "-b", "done", worktree.path, "main")
        let (cleaner, _) = makeCleaner(repo)

        let outcome = await cleaner.removeWorktree(
            repoRoot: repo.root, path: worktree, approved: .safe, bytes: 52_000_000)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(record.bytes, 52_000_000)
        XCTAssertEqual(record.reason, "Already part of the default branch")
    }

    func testTheBatchHandsEachWorktreeItsOwnSize() async throws {
        let repo = try baseRepo()
        let one = repo.sandbox.appendingPathComponent("wt-one")
        let two = repo.sandbox.appendingPathComponent("wt-two")
        try repo.git("worktree", "add", "-b", "one", one.path, "main")
        try repo.git("worktree", "add", "-b", "two", two.path, "main")
        let (cleaner, _) = makeCleaner(repo)
        let items: [CleanupItem] = [
            .worktree(repoRoot: repo.root, path: one, approved: .safe, deleteBranch: "one"),
            .worktree(repoRoot: repo.root, path: two, approved: .safe, deleteBranch: "two"),
        ]

        var records: [UndoRecord] = []
        for await event in BatchCleaner(cleaner: cleaner).run(
            items: items, sizeHints: ["worktree:\(one.path)": 111, "worktree:\(two.path)": 222])
        {
            if case .itemFinished(_, _, .removed(let record)) = event { records.append(record) }
        }

        let worktreeRecords = records.filter { $0.action == .removeWorktree }
        XCTAssertEqual(Set(worktreeRecords.compactMap(\.bytes)), [111, 222])
        XCTAssertTrue(records.filter { $0.action == .deleteBranch }.allSatisfy { $0.bytes == nil },
                      "a follow-up branch deletion frees nothing of its own")
    }
}

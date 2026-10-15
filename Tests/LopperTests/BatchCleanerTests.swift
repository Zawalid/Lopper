import XCTest
@testable import Lopper

final class BatchCleanerTests: XCTestCase {
    private func makeBatchCleaner(_ repo: TestRepo) -> (BatchCleaner, Cleaner, UndoLog) {
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        return (BatchCleaner(cleaner: cleaner), cleaner, log)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n"])
        return repo
    }

    private func branchExists(_ repo: TestRepo, _ name: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(name)")) != nil
    }

    private func mergedBranch(_ repo: TestRepo, _ name: String) throws {
        try repo.git("checkout", "-b", name)
        try repo.commit("work on \(name)", files: ["\(name).txt": name])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge \(name)", name)
    }

    private func collect(_ stream: AsyncStream<BatchEvent>) async -> [BatchEvent] {
        var events: [BatchEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testBundleRemovesTheWorktreeThenItsBranchAndOneUndoRestoresBoth() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-done")
        try repo.git("worktree", "add", "-b", "done", wt.path)
        try repo.commit("work", files: ["d.txt": "d"], in: wt)
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        try mergedBranch(repo, "plain")
        let (batch, cleaner, _) = makeBatchCleaner(repo)
        let items: [CleanupItem] = [
            .branch(repoRoot: repo.root, name: "plain", approved: .safe),
            .worktree(repoRoot: repo.root, path: wt, approved: .safe, deleteBranch: "done"),
        ]

        let events = await collect(batch.run(items: items))

        guard case .started(let batchID, let total) = events.first else { return XCTFail("\(events)") }
        XCTAssertEqual(total, 3)
        guard case .finished(let summary) = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(summary.removed, 3)
        XCTAssertEqual(summary.failed + summary.skipped, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertFalse(branchExists(repo, "done"))
        XCTAssertFalse(branchExists(repo, "plain"))
        // The worktree is removed before any branch is deleted.
        let finished = events.compactMap { event -> CleanupItem? in
            if case .itemFinished(_, let item, _) = event { return item }
            return nil
        }
        guard case .worktree = finished.first else { return XCTFail("worktree must run first: \(finished)") }
        XCTAssertTrue(summary.records.allSatisfy { $0.batchID == batchID })

        let outcomes = await cleaner.restoreBatch(batchID)

        XCTAssertEqual(outcomes.count, 3)
        XCTAssertTrue(outcomes.allSatisfy { if case .restored = $0 { true } else { false } }, "\(outcomes)")
        XCTAssertTrue(branchExists(repo, "done"))
        XCTAssertTrue(branchExists(repo, "plain"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.appendingPathComponent("d.txt").path))
    }

    func testProtectedAndChangedItemsAreSkippedWithoutStoppingTheBatch() async throws {
        let repo = try baseRepo()
        try mergedBranch(repo, "good")
        try repo.git("checkout", "-b", "unmerged")
        try repo.commit("only copy", files: ["u.txt": "u"])
        try repo.git("checkout", "main")
        let (batch, _, _) = makeBatchCleaner(repo)
        let items: [CleanupItem] = [
            .branch(repoRoot: repo.root, name: "main", approved: .safe),
            .branch(repoRoot: repo.root, name: "unmerged", approved: .safe),
            .branch(repoRoot: repo.root, name: "good", approved: .safe),
        ]

        let events = await collect(batch.run(items: items))

        guard case .finished(let summary) = events.last else { return XCTFail("\(events)") }
        XCTAssertEqual(summary.removed, 1)
        XCTAssertEqual(summary.skipped, 2)
        XCTAssertTrue(branchExists(repo, "main"))
        XCTAssertTrue(branchExists(repo, "unmerged"))
        XCTAssertFalse(branchExists(repo, "good"))
    }

    func testConsumerCancellationStopsTheBatchBetweenItems() async throws {
        let repo = try baseRepo()
        for index in 0..<8 { try repo.git("branch", "merged-\(index)") }
        let (batch, _, _) = makeBatchCleaner(repo)
        let items = (0..<8).map {
            CleanupItem.branch(repoRoot: repo.root, name: "merged-\($0)", approved: .safe)
        }

        for await event in batch.run(items: items) {
            if case .itemFinished = event { break }
        }
        try await Task.sleep(for: .seconds(3))

        let remaining = (0..<8).filter { branchExists(repo, "merged-\($0)") }.count
        XCTAssertGreaterThanOrEqual(remaining, 4, "cancelling must stop the batch early, not finish it")
    }

    func testStopRequestFinishesTheItemInFlightThenStopsAndStillReportsAFinishedBatch() async throws {
        let repo = try baseRepo()
        for index in 0..<8 { try repo.git("branch", "merged-\(index)") }
        let (batch, cleaner, _) = makeBatchCleaner(repo)
        let items = (0..<8).map {
            CleanupItem.branch(repoRoot: repo.root, name: "merged-\($0)", approved: .safe)
        }
        let control = BatchControl()

        var summary: BatchSummary?
        for await event in batch.run(items: items, control: control) {
            switch event {
            case .itemFinished(let index, _, _) where index == 0:
                control.requestStop()
            case .finished(let result):
                summary = result
            default:
                break
            }
        }

        let result = try XCTUnwrap(summary, "the stream must still deliver .finished after a stop")
        XCTAssertTrue(result.wasCancelled)
        XCTAssertGreaterThanOrEqual(result.removed, 1)
        XCTAssertLessThan(result.removed, 8)
        XCTAssertEqual(result.failed, 0, "nothing in flight may be aborted")
        // Everything that was removed before the stop is still undoable as one batch.
        let outcomes = await cleaner.restoreBatch(result.batchID)
        XCTAssertEqual(outcomes.count, result.removed)
    }
}

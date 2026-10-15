import XCTest
@testable import Lopper

final class CleanerBatchTests: XCTestCase {
    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return repo
    }

    private func mergedBranch(_ repo: TestRepo, _ name: String) throws {
        try repo.git("checkout", "-b", name)
        try repo.commit("work on \(name)", files: ["\(name).txt": name])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge \(name)", name)
    }

    func testRemovalsCarryTheirBatchIDAndRestoreBatchOnlyTouchesThatBatch() async throws {
        let repo = try baseRepo()
        try mergedBranch(repo, "one")
        try mergedBranch(repo, "two")
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        let batch = UUID()

        guard case .removed(let first) = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "one", approved: .safe, batchID: batch) else { return XCTFail() }
        guard case .removed = await cleaner.deleteBranch(
            repoRoot: repo.root, name: "two", approved: .safe) else { return XCTFail() }
        XCTAssertEqual(first.batchID, batch)

        let outcomes = await cleaner.restoreBatch(batch)

        XCTAssertEqual(outcomes.count, 1)
        XCTAssertNotNil(try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/one"))
        XCTAssertNil(try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/two"),
                     "a removal outside the batch must stay removed")
    }

    func testOldUndoLogLinesWithoutBatchIDStillDecode() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-old-log-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let line = #"{"action":"deleteBranch","branch":"b","id":"\#(UUID().uuidString)","repoPath":"/r","status":"completed","timestamp":"2026-10-01T10:00:00Z","tip":"abc","trashRef":"refs/lopper/trash/1/b"}"#
        try (line + "\n").write(to: url, atomically: true, encoding: .utf8)

        let records = await UndoLog(url: url).all()

        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records[0].batchID)
    }
}

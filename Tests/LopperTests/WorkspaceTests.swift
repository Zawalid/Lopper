import XCTest
@testable import Lopper

final class WorkspaceTests: XCTestCase {
    /// A repository with one branch already merged into main and one with work only on itself.
    private func fixture() throws -> (repo: TestRepo, settings: Settings, undoLog: URL) {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        try repo.addOrigin()
        try repo.git("checkout", "-b", "done")
        try repo.commit("done work", files: ["done.txt": "d"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        try repo.git("push", "origin", "main")
        try repo.git("checkout", "-b", "wip")
        try repo.commit("wip work", files: ["wip.txt": "w"])
        try repo.git("checkout", "main")
        let settings = Settings(roots: [repo.sandbox], scanDepth: 3)
        let log = repo.sandbox.appendingPathComponent("undo-log.jsonl")
        return (repo, settings, log)
    }

    func testScanReturnsRowsSafeFirstWithTheirEvidence() async throws {
        let (repo, settings, log) = try fixture()
        defer { withExtendedLifetime(repo) {} }
        let workspace = Workspace(settings: settings, prProvider: nil, undoLog: UndoLog(url: log))

        let scan = await workspace.scan()

        XCTAssertEqual(scan.failures.count, 0)
        XCTAssertEqual(scan.rows.map(\.title), ["done", "wip", "main"])
        XCTAssertEqual(scan.rows.map(\.verdict), [.safe, .review, .protected])
        XCTAssertFalse(scan.rows[0].evidence.isEmpty)
        XCTAssertEqual(scan.rows.filter(\.isBulkEligible).map(\.title), ["done"])
    }

    func testCleaningARowRemovesItAndCanBeUndone() async throws {
        let (repo, settings, log) = try fixture()
        let workspace = Workspace(settings: settings, prProvider: nil, undoLog: UndoLog(url: log))
        let scan = await workspace.scan()
        let safe = try XCTUnwrap(scan.rows.first { $0.isBulkEligible })

        var summary: BatchSummary?
        for await event in workspace.clean([safe]) {
            if case .finished(let result) = event { summary = result }
        }

        XCTAssertEqual(summary?.removed, 1)
        XCTAssertFalse(try repo.git("branch", "--format=%(refname:short)").contains("done"))
        let history = await workspace.history()
        XCTAssertEqual(history.count, 1)

        let outcomes = await workspace.restoreBatch(try XCTUnwrap(summary?.batchID))
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertTrue(try repo.git("branch", "--format=%(refname:short)").contains("done"))
    }
}

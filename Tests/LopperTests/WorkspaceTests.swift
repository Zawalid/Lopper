import XCTest
@testable import Lopper

/// A trash that moves into a throwaway folder, so tests never touch the real Trash.
private struct FolderTrash: TrashProvider {
    let folder: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

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

    func testGeneratedFoldersAreFoundAndClearedToTheTrashWithAnUndoRecord() async throws {
        let (repo, settings, log) = try fixture()
        defer { withExtendedLifetime(repo) {} }
        try repo.commit("ignore", files: [".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        let modules = repo.root.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(count: 40_000).write(to: modules.appendingPathComponent("index.js"))
        let trash = FolderTrash(folder: repo.sandbox.appendingPathComponent("FakeTrash"))
        let workspace = Workspace(
            settings: settings, prProvider: nil, undoLog: UndoLog(url: log), trash: trash)

        let scan = await workspace.scan()
        let artifacts = await workspace.artifacts(for: scan)

        let artifact = try XCTUnwrap(artifacts.first { $0.name == "node_modules" })
        XCTAssertTrue(artifact.removal.isOffered)
        XCTAssertGreaterThan(artifact.bytes, 0)

        let outcomes = await workspace.clear([artifact])

        guard case .removed = outcomes.first else { return XCTFail("expected removed, got \(String(describing: outcomes.first))") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path.path))
        let history = await workspace.history()
        XCTAssertEqual(history.last?.action, .trashFolder)
    }
}

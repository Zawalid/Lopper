import XCTest
@testable import Lopper

private struct TrashInFolder: TrashProvider {
    let folder: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class TrashSweeperTests: XCTestCase {
    private struct Fixture {
        let repo: TestRepo
        let log: UndoLog
        let artifacts: ArtifactCleaner
        let sweeper: TrashSweeper
        let trash: URL
    }

    private func fixture() throws -> Fixture {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let trash = repo.sandbox.appendingPathComponent(".Trash")
        return Fixture(
            repo: repo, log: log,
            artifacts: ArtifactCleaner(undoLog: log, trash: TrashInFolder(folder: trash)),
            sweeper: TrashSweeper(undoLog: log), trash: trash)
    }

    private func trashedFolder(_ f: Fixture, named name: String = "node_modules") async throws -> UndoRecord {
        let url = f.repo.root.appendingPathComponent(name).appendingPathComponent("pkg/index.js")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "x", count: 5_000).write(to: url, atomically: true, encoding: .utf8)
        let found = await ArtifactScanner().scan(
            root: f.repo.root, repoRoot: f.repo.root, names: [name], location: .mainCheckout)
        let artifact = try XCTUnwrap(found.first)
        guard case .removed(let record) = await f.artifacts.clear(artifact, names: [name]) else {
            XCTFail("clear failed"); throw CancellationError()
        }
        return record
    }

    func testOnlyFoldersStillInTheTrashArePending() async throws {
        let f = try fixture()
        let waiting = try await trashedFolder(f)
        var gone = waiting
        gone.status = .restored

        let pending = TrashSweeper.pending(in: [waiting, gone])

        XCTAssertEqual(pending.map(\.id), [waiting.id])
    }

    func testAFolderThatLeftTheTrashIsNoLongerPending() async throws {
        let f = try fixture()
        let record = try await trashedFolder(f)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(record.trashedPath))

        XCTAssertTrue(TrashSweeper.pending(in: [record]).isEmpty)
    }

    func testDeletingForGoodRemovesTheFolderAndRetiresTheRecord() async throws {
        let f = try fixture()
        let record = try await trashedFolder(f)
        let trashed = try XCTUnwrap(record.trashedPath)

        let result = await f.sweeper.deleteForGood([record])

        XCTAssertEqual(result.deleted.count, 1)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed))
        let latest = await f.log.all().first { $0.id == record.id }
        XCTAssertEqual(latest?.status, .expired)
        XCTAssertEqual(latest?.detail, "Deleted from the Trash")
    }

    func testAPathOutsideTheTrashIsNeverDeleted() async throws {
        let f = try fixture()
        let precious = f.repo.sandbox.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let forged = UndoRecord(
            timestamp: Date(), repoPath: f.repo.root.path, action: .trashFolder, branch: nil, tip: "",
            upstream: nil, worktreePath: "/x", trashRef: "", status: .completed, bytes: 1,
            trashedPath: precious.path)

        let result = await f.sweeper.deleteForGood([forged])

        XCTAssertTrue(result.deleted.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.appendingPathComponent("a.txt").path))
    }

    func testASymlinkInTheTrashIsRemovedAsALinkNotFollowed() async throws {
        let f = try fixture()
        let precious = f.repo.sandbox.appendingPathComponent("precious2")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "keep".write(to: precious.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: f.trash, withIntermediateDirectories: true)
        let link = f.trash.appendingPathComponent("link-to-precious")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: precious)
        let record = UndoRecord(
            timestamp: Date(), repoPath: f.repo.root.path, action: .trashFolder, branch: nil, tip: "",
            upstream: nil, worktreePath: "/x", trashRef: "", status: .completed, bytes: 1,
            trashedPath: link.path)

        _ = await f.sweeper.deleteForGood([record])

        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.appendingPathComponent("a.txt").path))
    }

    func testPendingTotalsCountFoldersAndBytes() async throws {
        let f = try fixture()
        let first = try await trashedFolder(f)

        let totals = TrashSweeper.totals(of: TrashSweeper.pending(in: [first]))

        XCTAssertEqual(totals.folders, 1)
        XCTAssertEqual(totals.bytes, first.bytes)
    }
}

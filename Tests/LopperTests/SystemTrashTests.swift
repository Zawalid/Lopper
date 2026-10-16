import XCTest
@testable import Lopper

/// The one test that uses the real macOS Trash, so it only runs when asked for:
/// `LOPPER_REAL_TRASH=1 swift test --filter SystemTrashTests`. It moves a folder it created itself to the Trash,
/// restores it, moves it again and deletes it for good, leaving nothing behind.
final class SystemTrashTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["LOPPER_REAL_TRASH"] == "1" else {
            throw XCTSkip("set LOPPER_REAL_TRASH=1 to exercise the real Trash")
        }
    }

    func testAFolderGoesToTheRealTrashComesBackAndCanBeDeletedForGood() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: [
            ".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n",
        ])
        let folder = repo.root.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try String(repeating: "x", count: 4_000).write(
            to: folder.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let cleaner = ArtifactCleaner(undoLog: log, trash: SystemTrash())
        let found = await ArtifactScanner().scan(
            root: repo.root, repoRoot: repo.root, names: ["node_modules"], location: .mainCheckout)
        let artifact = try XCTUnwrap(found.first)

        // Into the Trash.
        guard case .removed(let record) = await cleaner.clear(artifact, names: ["node_modules"]) else {
            return XCTFail("could not move the folder to the Trash")
        }
        let trashed = try XCTUnwrap(record.trashedPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed), "it is in the Trash: \(trashed)")
        XCTAssertTrue(TrashSweeper.isInTrash(trashed), "the sweeper recognises the real Trash path: \(trashed)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifact.path.path))
        XCTAssertEqual(TrashSweeper.pending(in: [record]).count, 1)

        // Back out again.
        let restorer = Cleaner(inspector: RepoInspector(), undoLog: log)
        guard case .restored = await restorer.restore(record) else { return XCTFail("restore failed") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.path.appendingPathComponent("pkg/index.js").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed))

        // In again, then deleted for good.
        guard case .removed(let second) = await cleaner.clear(artifact, names: ["node_modules"]) else {
            return XCTFail("second clear failed")
        }
        let secondPath = try XCTUnwrap(second.trashedPath)
        let result = await TrashSweeper(undoLog: log).deleteForGood([second])
        XCTAssertEqual(result.deleted.count, 1, "\(result.failures)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondPath), "nothing is left in the Trash")
    }
}

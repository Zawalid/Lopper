import XCTest
@testable import Lopper

/// A trash that moves into a throwaway folder, so tests never touch the real Trash.
private struct FakeTrash: TrashProvider {
    let folder: URL

    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

final class ArtifactCleanerTests: XCTestCase {
    private let names: Set<String> = ["node_modules", "dist", ".next"]

    private struct Fixture {
        let repo: TestRepo
        let cleaner: Cleaner
        let artifacts: ArtifactCleaner
        let log: UndoLog
        let trash: FakeTrash
    }

    private func fixture(gitignore: String = "node_modules\ndist\n.next\n") throws -> Fixture {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": gitignore, "package.json": "{}\n", "package-lock.json": "{}\n"])
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl"))
        let trash = FakeTrash(folder: repo.sandbox.appendingPathComponent("FakeTrash"))
        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        return Fixture(
            repo: repo, cleaner: cleaner,
            artifacts: ArtifactCleaner(undoLog: log, trash: trash), log: log, trash: trash)
    }

    private func make(_ repo: TestRepo, _ path: String, size: Int = 20_000) throws {
        let url = repo.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(repeating: "x", count: size).write(to: url, atomically: true, encoding: .utf8)
    }

    private func discover(_ repo: TestRepo) async -> [DiskArtifact] {
        await ArtifactScanner().scan(root: repo.root, repoRoot: repo.root, names: names, location: .mainCheckout)
    }

    private func firstArtifact(_ repo: TestRepo) async throws -> DiskArtifact {
        let found = await discover(repo)
        return try XCTUnwrap(found.first)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Clearing

    func testAnOfferedFolderIsMovedToTheTrashAndRecorded() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/left-pad/index.js")
        let artifact = try await firstArtifact(f.repo)

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .removed(let record) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertFalse(exists(artifact.path), "it left the project")
        XCTAssertTrue(exists(URL(fileURLWithPath: try XCTUnwrap(record.trashedPath))), "it is in the Trash")
        XCTAssertEqual(record.action, .trashFolder)
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.worktreePath, artifact.path.path)
        XCTAssertEqual(record.bytes, artifact.bytes)
        XCTAssertEqual(record.repoPath, f.repo.root.path)
        let logged = await f.log.all()
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.status, .completed)
    }

    func testABlockedFolderIsRefused() async throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.repo.root.appendingPathComponent("package-lock.json"))
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        XCTAssertFalse(artifact.removal.isOffered)

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(artifact.path))
    }

    func testAFolderThatStoppedBeingIgnoredIsLeftAlone() async throws {
        let f = try fixture()
        try make(f.repo, "dist/app.js")
        let artifact = try await firstArtifact(f.repo)
        // Someone removed the ignore rule after the page was loaded: now `dist` could be new source.
        try "node_modules\n".write(
            to: f.repo.root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.lowercased().contains("ignored"), reason)
        XCTAssertTrue(exists(artifact.path))
    }

    func testAFolderWithATrackedFileInsideIsLeftAlone() async throws {
        let f = try fixture()
        try make(f.repo, "dist/keep-me.txt", size: 100)
        try f.repo.git("add", "-f", "dist/keep-me.txt")
        try f.repo.git("commit", "-m", "force add a file inside an ignored folder")
        try make(f.repo, "dist/app.js")
        let artifact = DiskArtifact(
            path: f.repo.root.appendingPathComponent("dist"), name: "dist", kind: .buildOutput, bytes: 1,
            newestModification: nil, projectDirectory: f.repo.root, checkoutRoot: f.repo.root, repoRoot: f.repo.root,
            location: .mainCheckout, removal: .offered(regenerate: "your build script"))

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(artifact.path.appendingPathComponent("keep-me.txt")))
    }

    func testALockfileThatVanishedAfterTheScanBlocksTheRemoval() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        try FileManager.default.removeItem(at: f.repo.root.appendingPathComponent("package-lock.json"))

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(artifact.path))
    }

    func testAPathThatBecameASymlinkIsNeverFollowed() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        let precious = f.repo.sandbox.appendingPathComponent("precious")
        try FileManager.default.createDirectory(at: precious, withIntermediateDirectories: true)
        try "irreplaceable".write(to: precious.appendingPathComponent("doc.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: artifact.path)
        try FileManager.default.createSymbolicLink(at: artifact.path, withDestinationURL: precious)

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(precious.appendingPathComponent("doc.txt")))
    }

    func testAPathOutsideTheCheckoutIsRefused() async throws {
        let f = try fixture()
        let outside = f.repo.sandbox.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let artifact = DiskArtifact(
            path: outside, name: "node_modules", kind: .packages, bytes: 1, newestModification: nil,
            projectDirectory: f.repo.sandbox, checkoutRoot: f.repo.root, repoRoot: f.repo.root,
            location: .mainCheckout, removal: .offered(regenerate: "npm ci"))

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(outside))
    }

    func testTheCheckoutRootItselfIsNeverMoved() async throws {
        let f = try fixture()
        let artifact = DiskArtifact(
            path: f.repo.root, name: "node_modules", kind: .packages, bytes: 1, newestModification: nil,
            projectDirectory: f.repo.root, checkoutRoot: f.repo.root, repoRoot: f.repo.root,
            location: .mainCheckout, removal: .offered(regenerate: "npm ci"))

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(exists(f.repo.root.appendingPathComponent(".git")))
    }

    func testAnArtifactAlreadyGoneIsSkippedNotFailed() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        try FileManager.default.removeItem(at: artifact.path)

        let outcome = await f.artifacts.clear(artifact, names: names)

        guard case .skipped(let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(reason.lowercased().contains("no longer"), reason)
    }

    // MARK: Undo

    func testRestoringPutsTheFolderBackWhereItWas() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/left-pad/index.js", size: 777)
        let artifact = try await firstArtifact(f.repo)
        guard case .removed(let record) = await f.artifacts.clear(artifact, names: names) else { return XCTFail("clear") }

        let outcome = await f.cleaner.restore(record)

        guard case .restored(let restored) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(restored.status, .restored)
        XCTAssertEqual(
            try String(contentsOf: artifact.path.appendingPathComponent("left-pad/index.js"), encoding: .utf8).count, 777)
        XCTAssertFalse(exists(URL(fileURLWithPath: try XCTUnwrap(record.trashedPath))))
    }

    func testRestoringRefusesToOverwriteAFolderThatAppearedSince() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        guard case .removed(let record) = await f.artifacts.clear(artifact, names: names) else { return XCTFail("clear") }
        try make(f.repo, "node_modules/b/fresh-install.js")   // npm ci ran in the meantime

        let outcome = await f.cleaner.restore(record)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("already exists"), message)
        XCTAssertTrue(exists(artifact.path.appendingPathComponent("b/fresh-install.js")))
    }

    func testRestoringSaysSoWhenTheTrashWasEmptied() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        let artifact = try await firstArtifact(f.repo)
        guard case .removed(let record) = await f.artifacts.clear(artifact, names: names) else { return XCTFail("clear") }
        try FileManager.default.removeItem(at: URL(fileURLWithPath: try XCTUnwrap(record.trashedPath)))

        let outcome = await f.cleaner.restore(record)

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.lowercased().contains("trash"), message)
    }

    func testABatchRestoreBringsFoldersBackToo() async throws {
        let f = try fixture()
        try make(f.repo, "node_modules/a/index.js")
        try make(f.repo, "dist/app.js")
        let batch = UUID()
        for artifact in await discover(f.repo) {
            guard case .removed = await f.artifacts.clear(artifact, names: names, batchID: batch) else { return XCTFail("clear") }
        }
        XCTAssertFalse(exists(f.repo.root.appendingPathComponent("node_modules")))

        let outcomes = await f.cleaner.restoreBatch(batch)

        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(exists(f.repo.root.appendingPathComponent("node_modules/a/index.js")))
        XCTAssertTrue(exists(f.repo.root.appendingPathComponent("dist/app.js")))
    }
}

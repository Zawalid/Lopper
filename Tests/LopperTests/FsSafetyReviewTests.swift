import XCTest
@testable import Lopper

/// Reproductions for the filesystem / persistence review. Each test asserts the SAFE behaviour, so a failing
/// assertion is a demonstrated weakness.

/// A trash that behaves like ~/.Trash: plain names, reused after the Trash is emptied.
private struct PlainTrash: TrashProvider {
    let folder: URL
    func moveToTrash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var destination = folder.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(url.lastPathComponent) \(n)")
            n += 1
        }
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Moves like PlainTrash, then makes the undo log unwritable (disk full, quota, permissions) before returning.
private struct TrashThenLogBreaks: TrashProvider {
    let folder: URL
    let logURL: URL
    func moveToTrash(_ url: URL) throws -> URL {
        let moved = try PlainTrash(folder: folder).moveToTrash(url)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: logURL.path)
        return moved
    }
}

final class FsSafetyReviewTests: XCTestCase {
    private let names: Set<String> = ["node_modules", "dist", "build", ".next"]

    private nonisolated static func makeRecord(_ id: UUID = UUID(), status: UndoStatus = .completed, n: Int = 0) -> UndoRecord {
        UndoRecord(
            id: id, timestamp: Date(timeIntervalSince1970: 1_800_000_000 + Double(n)), repoPath: "/r",
            action: .deleteBranch, branch: "b\(n)", tip: String(repeating: "a", count: 40), upstream: nil,
            worktreePath: nil, trashRef: "refs/lopper/trash/\(n)", status: status)
    }

    private func record(_ id: UUID = UUID(), status: UndoStatus = .completed, n: Int = 0) -> UndoRecord {
        Self.makeRecord(id, status: status, n: n)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: UndoLog

    /// F1: two writers (the app and `lop` are separate processes; two UndoLog instances model that) lose records
    /// because append is seekToEnd + write, not O_APPEND.
    func testConcurrentWritersDoNotLoseRecords() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-undo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("undo-log.jsonl")
        let a = UndoLog(url: url)
        let b = UndoLog(url: url)
        try await a.append(record(n: 0))   // file exists, so only the seek+write race remains
        let perWriter = 1500
        await withTaskGroup(of: Void.self) { group in
            for (index, log) in [a, b].enumerated() {
                group.addTask {
                    for i in 0..<perWriter {
                        try? await log.append(FsSafetyReviewTests.makeRecord(n: 1 + index * perWriter + i))
                    }
                }
            }
        }
        let count = await a.all().count
        XCTAssertEqual(count, 1 + 2 * perWriter, "records lost by interleaved appends")
    }

    /// F2: a trailing line without a newline (crash or ENOSPC mid-write) swallows the NEXT record, so a removal
    /// can be performed with no readable undo record even though append() reported success.
    func testRecordAppendedAfterTruncatedLineIsStillReadable() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-undo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("undo-log.jsonl")
        let log = UndoLog(url: url)
        try await log.append(record(n: 1))
        // Simulate a half-written final line.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"action":"deleteBranch","branch":"half"#.utf8))
        try handle.close()

        let next = record(n: 2)
        try await log.append(next)   // returns without error
        let ids = await log.all().map(\.id)
        XCTAssertTrue(ids.contains(next.id), "the record that append() accepted cannot be read back")
    }

    /// F3: a line written by a newer build that this build cannot decode is skipped, so the OLDER state of the
    /// same id (e.g. completed) wins over the newer one (e.g. restored/other).
    func testUnreadableNewerLineDoesNotResurrectOlderState() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-undo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("undo-log.jsonl")
        let log = UndoLog(url: url)
        let r = record(n: 1)
        try await log.append(r)
        var text = try String(contentsOf: url, encoding: .utf8)
        text += text.replacingOccurrences(of: #""status":"completed""#, with: #""status":"undone""#)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let latest = await log.all().first { $0.id == r.id }
        XCTAssertNotEqual(latest?.status, .completed, "newer 'undone' line was ignored; record looks restorable again")
    }

    // MARK: TrashSweeper / restore: trashedPath reuse

    private func trashedRecord(trash: PlainTrash, project: URL, name: String) async throws -> (UndoRecord, URL) {
        let folder = project.appendingPathComponent(name)
        try write("generated", to: folder.appendingPathComponent("x.js"))
        let identity = UndoRecord.identity(ofItemAt: folder.path)
        let moved = try trash.moveToTrash(folder)
        let rec = UndoRecord(
            timestamp: Date(), repoPath: project.path, action: .trashFolder, branch: nil, tip: "", upstream: nil,
            worktreePath: folder.path, trashRef: "", status: .completed, bytes: 9, trashedPath: moved.path,
            trashedIdentity: identity)
        return (rec, moved)
    }

    /// F4: Lopper trashes `dist`; the person empties the Trash; later they trash THEIR OWN `dist`. The same
    /// trashedPath now holds somebody else's data and Lopper offers to (and does) delete it for good.
    func testSweeperNeverDeletesAnItemLopperDidNotTrash() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fs-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = PlainTrash(folder: base.appendingPathComponent(".Trash"))
        let project = base.appendingPathComponent("proj")
        let log = UndoLog(url: base.appendingPathComponent("undo.jsonl"))

        let (rec, moved) = try await trashedRecord(trash: trash, project: project, name: "dist")
        try await log.append(rec)
        try FileManager.default.removeItem(at: moved)                       // person empties the Trash

        let other = base.appendingPathComponent("hand-written")            // unrelated work, same folder name
        try write("IRREPLACEABLE", to: other.appendingPathComponent("dist/notes.txt"))
        let theirs = try trash.moveToTrash(other.appendingPathComponent("dist"))
        XCTAssertEqual(theirs.path, moved.path, "precondition: same Trash path reused")

        let pending = TrashSweeper.pending(in: await log.all())
        XCTAssertTrue(pending.isEmpty, "someone else's folder is reported as Lopper's")
        let result = await TrashSweeper(undoLog: log).deleteForGood(pending.isEmpty ? [rec] : pending)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: theirs.path),
            "deleteForGood removed an item Lopper never trashed (deleted: \(result.deleted.count))")
    }

    /// F4b: same reuse, restore side: undo moves the unrelated item into the project.
    func testRestoreDoesNotMoveSomeoneElsesItemIntoTheProject() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fs-restore-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let trash = PlainTrash(folder: base.appendingPathComponent(".Trash"))
        let project = base.appendingPathComponent("proj")
        let log = UndoLog(url: base.appendingPathComponent("undo.jsonl"))
        let (rec, moved) = try await trashedRecord(trash: trash, project: project, name: "dist")
        try await log.append(rec)
        try FileManager.default.removeItem(at: moved)
        let other = base.appendingPathComponent("elsewhere")
        try write("NOT-FROM-THIS-PROJECT", to: other.appendingPathComponent("dist/other.txt"))
        _ = try trash.moveToTrash(other.appendingPathComponent("dist"))

        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        _ = await cleaner.restore(rec)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: project.appendingPathComponent("dist/other.txt").path),
            "undo put an unrelated folder from the Trash into the project")
    }

    // MARK: ArtifactCleaner

    private func repoWithTrackedDist() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": "dist\nnode_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        try write("source of truth", to: repo.root.appendingPathComponent("dist/handwritten.js"))
        try repo.git("add", "-f", "dist/handwritten.js")
        try repo.git("commit", "-m", "force add")
        return repo
    }

    /// F6: an ignored `dist/` that contains a nested git repository (own .git, unpushed commit) is cleared:
    /// nothing looks for nested repositories or worktrees inside the folder.
    func testFolderHoldingANestedRepositoryIsNotCleared() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": "dist\n", "package.json": "{}\n"])
        let nested = repo.root.appendingPathComponent("dist/clone")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try TestRepo.configure(at: nested)
        try write("only copy", to: nested.appendingPathComponent("work.txt"))
        try TestRepo.runGit(["add", "-A"], in: nested)
        try TestRepo.runGit(["commit", "-m", "unpushed"], in: nested)

        let found = await ArtifactScanner().scan(root: repo.root, repoRoot: repo.root, names: names, location: .mainCheckout)
        let artifact = try XCTUnwrap(found.first { $0.name == "dist" })
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo.jsonl"))
        let cleaner = ArtifactCleaner(undoLog: log, trash: PlainTrash(folder: repo.sandbox.appendingPathComponent(".Trash")))
        let outcome = await cleaner.clear(artifact, names: names)
        if case .removed = outcome { XCTFail("moved a folder containing a repository with unpushed work: \(outcome)") }
    }

    /// F7: GitRunner inherits the caller's environment. A stale GIT_INDEX_FILE (set by hooks, direnv, IDEs) makes
    /// `git ls-files` see an empty index, so the "nothing tracked inside" guard passes for a tracked folder.
    func testAmbientGitEnvironmentCannotDisableTheTrackedFileGuard() async throws {
        let repo = try repoWithTrackedDist()
        let found = await ArtifactScanner().scan(root: repo.root, repoRoot: repo.root, names: names, location: .mainCheckout)
        // Discovery needs the real index; only the cleaner runs with the polluted environment.
        let artifact = found.first { $0.name == "dist" }
        // The folder has tracked content, so it should not even be discovered; build the artifact by hand.
        let target = artifact ?? DiskArtifact(
            path: repo.root.appendingPathComponent("dist", isDirectory: true), name: "dist", kind: .buildOutput, bytes: 1,
            newestModification: nil, projectDirectory: repo.root, checkoutRoot: repo.root, repoRoot: repo.root,
            location: .mainCheckout, removal: .offered(regenerate: "x"))
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo.jsonl"))
        let cleaner = ArtifactCleaner(undoLog: log, trash: PlainTrash(folder: repo.sandbox.appendingPathComponent(".Trash")))

        setenv("GIT_INDEX_FILE", repo.sandbox.appendingPathComponent("no-such-index").path, 1)
        defer { unsetenv("GIT_INDEX_FILE") }
        let outcome = await cleaner.clear(target, names: names)
        if case .removed = outcome { XCTFail("tracked file moved to Trash under GIT_INDEX_FILE") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("dist/handwritten.js").path))
    }

    /// F8: pathspec is not literal. A parent folder whose name contains glob characters.
    func testGlobCharactersInParentFolderNameDoNotHideTrackedFiles() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": "dist\n", "package.json": "{}\n"])
        try write("tracked", to: repo.root.appendingPathComponent("pkg[1]/dist/keep.js"))
        try write("{}", to: repo.root.appendingPathComponent("pkg[1]/package.json"))
        try repo.git("add", "-f", "pkg[1]/dist/keep.js", "pkg[1]/package.json")
        try repo.git("commit", "-m", "tracked in glob dir")
        let artifact = DiskArtifact(
            path: repo.root.appendingPathComponent("pkg[1]/dist", isDirectory: true), name: "dist", kind: .buildOutput, bytes: 1,
            newestModification: nil, projectDirectory: repo.root.appendingPathComponent("pkg[1]"), checkoutRoot: repo.root,
            repoRoot: repo.root, location: .mainCheckout, removal: .offered(regenerate: "x"))
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo.jsonl"))
        let cleaner = ArtifactCleaner(undoLog: log, trash: PlainTrash(folder: repo.sandbox.appendingPathComponent(".Trash")))
        let outcome = await cleaner.clear(artifact, names: names)
        if case .removed = outcome { XCTFail("tracked file inside pkg[1]/dist moved to Trash") }
    }

    // MARK: Discovery

    /// F9: a `.git` FILE anywhere under a scanned folder is trusted: whatever `gitdir:` points at becomes a
    /// discovered repository, even outside every configured folder.
    func testScannerDoesNotAdoptRepositoriesOutsideTheScannedFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fs-scan-\(UUID().uuidString)").canonicalized
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("elsewhere/precious")
        try TestRepo.makeStandaloneRepo(at: outside)
        let scanned = base.appendingPathComponent("code")
        let stray = scanned.appendingPathComponent("downloaded-project")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "gitdir: \(outside.path)/.git/worktrees/x\n".write(
            to: stray.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let found = RepoScanner().findRepos(in: [scanned], maxDepth: 3)
        XCTAssertFalse(found.contains { $0.path == outside.path }, "repo outside the scanned folder was adopted: \(found)")
    }

    /// F10: a symlinked folder inside a scanned folder: does the walker follow it (duplicate / escaped repos)?
    func testScannerDoesNotFollowSymlinkedFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fs-scan-\(UUID().uuidString)").canonicalized
        defer { try? FileManager.default.removeItem(at: base) }
        let outside = base.appendingPathComponent("elsewhere/precious")
        try TestRepo.makeStandaloneRepo(at: outside)
        let scanned = base.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: scanned, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: scanned.appendingPathComponent("link"), withDestinationURL: base.appendingPathComponent("elsewhere"))
        let found = RepoScanner().findRepos(in: [scanned], maxDepth: 3)
        XCTAssertTrue(found.isEmpty, "walker followed a symlink out of the scanned folder: \(found.map(\.path))")
    }

    // MARK: Settings

    /// F11: one badly typed key resets EVERYTHING (protected patterns, hidden repos, folders) to defaults.
    func testOneBadKeyDoesNotResetProtectedPatternsAndHiddenRepos() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-set-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try write(
            #"{"schemaVersion":2,"protectedPatterns":["staging","prod-*"],"repos":{"/code/secret":{"isIgnored":true}},"scanDepth":"4"}"#,
            to: url)
        let loaded = SettingsLoader.load(from: url)
        XCTAssertTrue(loaded.settings.protectedPatterns.contains("staging"), "custom protected patterns silently replaced by defaults (\(loaded.outcome))")
    }

    /// F12: unknown keys nested inside known structures from a newer build are dropped on the next save.
    func testNestedKeysFromANewerBuildSurviveASave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-set-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try write(
            #"{"schemaVersion":3,"folders":[{"path":"file:///code/","isEnabled":true,"excludePatterns":[],"futureFlag":"keepMe"}]}"#,
            to: url)
        let loaded = SettingsLoader.load(from: url).settings
        // An older build must not rewrite a newer build's file: it would drop fields it does not know.
        XCTAssertThrowsError(try loaded.save(to: url)) { error in
            XCTAssertEqual(error as? SettingsSaveError, .writtenByNewerVersion(3))
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("futureFlag"), "nested key written by a newer build was dropped by an older build's save")
    }

    /// F13: retention of 0 / a clock far in the future expires every keep-alive ref at once (expireTrash is not
    /// currently called by the app or CLI; this documents the hazard of wiring it up).
    func testExpireTrashHasASaneFloorOnRetention() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["a": "a"])
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("only copy", files: ["b": "b"])
        try repo.git("checkout", "main")
        let id = UUID()
        let ref = "refs/lopper/trash/\(id.uuidString)"
        try repo.git("update-ref", ref, tip)
        try repo.git("branch", "-D", "feature")
        let log = UndoLog(url: repo.sandbox.appendingPathComponent("undo.jsonl"))
        try await log.append(UndoRecord(
            id: id, timestamp: Date(), repoPath: repo.root.path, action: .deleteBranch, branch: "feature", tip: tip,
            upstream: nil, worktreePath: nil, trashRef: ref, status: .completed))
        let cleaner = Cleaner(inspector: RepoInspector(), undoLog: log)
        _ = await cleaner.expireTrash(retentionDays: 0)          // e.g. hand-edited or corrupted setting
        let refAlive = (try? repo.git("rev-parse", "--verify", "--quiet", ref)) != nil
        XCTAssertTrue(refAlive, "retentionDays = 0 deleted the keep-alive ref of a record created just now")
    }

    /// F15: a settings file that cannot be READ (permissions, transient I/O error) is treated as corrupt: defaults
    /// are used, a `broken-` backup is reported even when the copy failed, and the next save replaces the file.
    func testUnreadableSettingsFileIsNeverReplacedWithoutAWorkingBackup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fs-set-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("settings.json").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = dir.appendingPathComponent("settings.json")
        try write(#"{"schemaVersion":2,"protectedPatterns":["staging"],"folders":[]}"#, to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)

        let loaded = SettingsLoader.load(from: url)
        // A file that cannot be read is not a corrupt file: no backup is promised (it could not be copied either), and
        // callers must not save over it. Lopper's commands and app refuse to, which the CLI test below covers.
        XCTAssertEqual(loaded.outcome, .unreadable, "\(loaded.outcome)")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let after = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(after.contains("staging"), "the original settings must still be there")
    }

    /// F16: the "completed" record is written with try?. When that write fails the call still reports success,
    /// the folder is in the Trash, but the log says pending with no trashedPath: undo and the sweeper cannot see it.
    func testSuccessfulClearIsAlwaysRestorableFromTheLog() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: [".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        try write("x", to: repo.root.appendingPathComponent("node_modules/a/index.js"))
        let found = await ArtifactScanner().scan(root: repo.root, repoRoot: repo.root, names: names, location: .mainCheckout)
        let artifact = try XCTUnwrap(found.first)
        let logURL = repo.sandbox.appendingPathComponent("undo.jsonl")
        let log = UndoLog(url: logURL)
        let cleaner = ArtifactCleaner(
            undoLog: log, trash: TrashThenLogBreaks(folder: repo.sandbox.appendingPathComponent(".Trash"), logURL: logURL))
        let outcome = await cleaner.clear(artifact, names: names)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: logURL.path) }
        let latest = await log.all().first
        switch outcome {
        case .removed:
            // Success is only honest when the log can undo it.
            XCTAssertEqual(latest?.status, .completed, "reported success, but the log still says \(String(describing: latest?.status))")
            XCTAssertNotNil(latest?.trashedPath)
        case .failed(let message):
            // The folder is in the Trash and the log could not say so: the outcome must say that, and where it is.
            XCTAssertTrue(message.contains("history entry could not be saved") && message.contains(".Trash"), message)
        case .skipped:
            XCTFail("\(outcome)")
        }
    }
}

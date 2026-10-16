import XCTest
@testable import Lopper

final class LocalWorkScannerTests: XCTestCase {
    private func items(_ repo: TestRepo) async throws -> [LocalOnlyItem] {
        let snapshot = try await RepoInspector(settings: Settings(), prProvider: nil).inspect(repoRoot: repo.root)
        return await LocalWorkScanner().scan(snapshot)
    }

    private func baseWithOrigin() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        try repo.addOrigin()
        return repo
    }

    func testPushedBranchIsNotListedButUnpushedCommitsAre() async throws {
        let repo = try baseWithOrigin()
        try repo.git("checkout", "-b", "pushed")
        try repo.commit("on remote", files: ["a.txt": "a"])
        try repo.git("push", "-u", "origin", "pushed")
        try repo.git("checkout", "-b", "local-only", "main")
        try repo.commit("one", files: ["b.txt": "b"])
        try repo.commit("two", files: ["c.txt": "c"])
        try repo.git("checkout", "main")

        let found = try await items(repo)

        XCTAssertEqual(found.map(\.title), ["local-only"])
        let item = try XCTUnwrap(found.first)
        XCTAssertEqual(item.kind, .unpushedCommits)
        XCTAssertEqual(item.count, 2)
        XCTAssertEqual(item.detail, "2 commits not on any remote")
        XCTAssertTrue(item.pushCommand?.hasSuffix("push -u origin local-only") == true, item.pushCommand ?? "nil")
    }

    func testUnpushedCommitsOnTheDefaultBranchAreListedOnce() async throws {
        let repo = try baseWithOrigin()
        try repo.git("checkout", "-b", "on-top")
        try repo.commit("branch work", files: ["b.txt": "b"])
        try repo.git("push", "-u", "origin", "on-top")
        try repo.git("checkout", "main")
        try repo.commit("local main work", files: ["m.txt": "m"])

        let found = try await items(repo)

        XCTAssertEqual(found.map(\.title), ["main"], "the default branch carries its own commits, and nothing is counted twice")
        XCTAssertEqual(found.first?.count, 1)
    }

    func testABranchWhoseContentIsAlreadyMergedIsNotListedEvenIfUnpushed() async throws {
        let repo = try baseWithOrigin()
        try repo.git("checkout", "-b", "squashed")
        try repo.commit("feature", files: ["f.txt": "f"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "squashed")
        try repo.git("commit", "-m", "squash merge")
        try repo.git("push", "origin", "main")

        let found = try await items(repo)

        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testARepositoryWithoutARemoteCountsCommitsBeyondTheDefaultBranchOnly() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        try repo.git("checkout", "-b", "idea")
        try repo.commit("one", files: ["i.txt": "i"])
        try repo.git("checkout", "main")

        let found = try await items(repo)

        XCTAssertEqual(found.map(\.title), ["idea"], "main is the repository itself, not a finding")
        XCTAssertEqual(found.first?.count, 1)
        XCTAssertTrue(found.first?.detail.contains("no remote") == true, found.first?.detail ?? "")
        XCTAssertNil(found.first?.pushCommand, "there is nothing to push to")
    }

    func testALinkedWorktreeWithChangesAndUntrackedFilesIsListedButTheMainFolderIsNot() async throws {
        let repo = try baseWithOrigin()
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", wt.path, "-b", "wt-branch")
        try repo.git("push", "-u", "origin", "wt-branch", in: wt)
        try "changed\n".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try "new".write(to: wt.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)
        try "also dirty\n".write(to: repo.root.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

        let found = try await items(repo)

        let item = try XCTUnwrap(found.first { $0.kind == .uncommittedChanges })
        XCTAssertEqual(item.title, "wt-branch")
        XCTAssertEqual(item.detail, "Uncommitted changes and 1 untracked file")
        XCTAssertEqual(item.path?.canonicalized.path, wt.canonicalized.path)
        XCTAssertEqual(found.filter { $0.kind == .uncommittedChanges }.count, 1, "the main working folder is the user's own active folder")
    }

    func testAStashEntryIsListedWithItsBranchAndMessage() async throws {
        let repo = try baseWithOrigin()
        try "wip\n".write(to: repo.root.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try repo.git("stash", "push", "-m", "half done idea")

        let found = try await items(repo)

        let item = try XCTUnwrap(found.first { $0.kind == .stash })
        XCTAssertEqual(item.title, "stash@{0}")
        XCTAssertTrue(item.detail.contains("half done idea"), item.detail)
        XCTAssertEqual(item.branch, "main")
    }

    func testCommitsOnADetachedWorktreeHeadAreListedUntilABranchHoldsThem() async throws {
        let repo = try baseWithOrigin()
        let wt = repo.sandbox.appendingPathComponent("detached")
        try repo.git("worktree", "add", "--detach", wt.path)
        try repo.commit("lonely", files: ["l.txt": "l"], in: wt)

        let found = try await items(repo)
        let item = try XCTUnwrap(found.first { $0.kind == .detachedCommits })
        XCTAssertEqual(item.count, 1)

        try repo.git("branch", "keep-it", in: wt)
        let after = try await items(repo)
        XCTAssertFalse(after.contains { $0.kind == .detachedCommits }, "a branch now holds the commit (and is listed as unpushed instead)")
        XCTAssertTrue(after.contains { $0.kind == .unpushedCommits && $0.title == "keep-it" })
    }

    func testAHalfDoneMergeInTheMainFolderIsListed() async throws {
        let repo = try baseWithOrigin()
        let head = try repo.sha("HEAD")
        try head.write(to: repo.root.appendingPathComponent(".git/MERGE_HEAD"), atomically: true, encoding: .utf8)

        let found = try await items(repo)

        XCTAssertTrue(found.contains { $0.kind == .operationInProgress }, "\(found)")
    }

    func testACleanRepositoryHasNothingOnlyOnThisMac() async throws {
        let repo = try baseWithOrigin()
        let found = try await items(repo)
        XCTAssertTrue(found.isEmpty, "\(found)")
    }

    func testWorkspaceExposesTheListForAScan() async throws {
        let repo = try baseWithOrigin()
        try repo.git("checkout", "-b", "local-only")
        try repo.commit("x", files: ["x.txt": "x"])
        try repo.git("checkout", "main")
        defer { withExtendedLifetime(repo) {} }
        let workspace = Workspace(
            settings: Settings(roots: [repo.sandbox], scanDepth: 3), prProvider: nil,
            undoLog: UndoLog(url: repo.sandbox.appendingPathComponent("undo.jsonl")))

        let scan = await workspace.scan(measureSizes: false)
        let found = await workspace.localOnlyWork(in: scan)

        XCTAssertEqual(found.map(\.title), ["local-only"])
    }
}

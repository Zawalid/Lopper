import XCTest
@testable import Lopper

final class CleanerFolderOnlyWorkTests: XCTestCase {
    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": ".env.local\n"])
        return repo
    }

    private func makeCleaner(_ repo: TestRepo) -> Cleaner {
        Cleaner(
            inspector: RepoInspector(),
            undoLog: UndoLog(url: repo.sandbox.appendingPathComponent("undo-log.jsonl")))
    }

    private func branchExists(_ repo: TestRepo, _ name: String) -> Bool {
        (try? repo.git("rev-parse", "--verify", "--quiet", "refs/heads/\(name)")) != nil
    }

    /// A committed, unmerged worktree: Review, removable after approval, branch kept.
    private func committedWorktree(_ repo: TestRepo, named name: String = "wt-committed") throws -> URL {
        let wt = repo.sandbox.appendingPathComponent(name)
        try repo.git("worktree", "add", "-b", "claude/\(name)", wt.path)
        try repo.commit("work", files: ["w.txt": "w"], in: wt)
        return wt
    }

    func testIgnoredFileThatAppearsAfterApprovalIsRefusedWhenTheCallerAsksForIt() async throws {
        let repo = try baseRepo()
        let wt = try committedWorktree(repo)
        // The user approved while the folder held nothing of its own; then an editor or agent wrote a secret.
        try "SECRET=1".write(to: wt.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)

        let outcome = await makeCleaner(repo).removeWorktree(
            repoRoot: repo.root, path: wt, approved: .review, refuseFolderOnlyWork: true)

        guard case .skipped = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try String(contentsOf: wt.appendingPathComponent(".env.local"), encoding: .utf8), "SECRET=1")
    }

    func testBatchPassesTheStrictFlagToTheWorktreesItIsGivenFor() async throws {
        let repo = try baseRepo()
        let strict = try committedWorktree(repo, named: "wt-strict")
        let lenient = try committedWorktree(repo, named: "wt-lenient")
        for wt in [strict, lenient] {
            try "SECRET=1".write(to: wt.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
        }
        let items: [CleanupItem] = [strict, lenient].map {
            .worktree(repoRoot: repo.root, path: $0, approved: .review, deleteBranch: nil)
        }
        let strictID = items[0].id

        var outcomes: [String: CleanOutcome] = [:]
        for await event in BatchCleaner(cleaner: makeCleaner(repo)).run(items: items, strictItemIDs: [strictID]) {
            if case .itemFinished(_, let item, let outcome) = event { outcomes[item.id] = outcome }
        }

        guard case .skipped? = outcomes[strictID] else { return XCTFail("\(String(describing: outcomes[strictID]))") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: strict.path))
    }

    func testRefusedRemovalKeepsAnEarlierSavedBranchAtTheSameCommit() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-detached")
        try repo.git("worktree", "add", "--detach", wt.path)
        let tip = try repo.commit("only copy", files: ["w.txt": "w"], in: wt)
        // A saved branch from an earlier removal of another worktree with the same name and commit.
        let name = Cleaner.savedBranchName(forWorktreeAt: wt, head: tip)
        try repo.git("branch", name, tip)
        try "precious".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(branchExists(repo, name), "the rollback must not delete a branch it did not create")
    }

    func testSavedBranchNameAlreadyTakenByAnotherCommitStopsTheRemoval() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-detached-clash")
        try repo.git("worktree", "add", "--detach", wt.path)
        let tip = try repo.commit("only copy", files: ["w.txt": "w"], in: wt)
        let other = try repo.sha("main")
        let name = Cleaner.savedBranchName(forWorktreeAt: wt, head: tip)
        try repo.git("branch", name, other)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .failed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: wt.path))
        XCTAssertEqual(try repo.sha("refs/heads/\(name)"), other, "an existing branch must never be overwritten")
    }

    func testSavedBranchAlreadyAtTheSameCommitIsReusedOnSuccess() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-detached-reuse")
        try repo.git("worktree", "add", "--detach", wt.path)
        let tip = try repo.commit("only copy", files: ["w.txt": "w"], in: wt)
        let name = Cleaner.savedBranchName(forWorktreeAt: wt, head: tip)
        try repo.git("branch", name, tip)

        let outcome = await makeCleaner(repo).removeWorktree(repoRoot: repo.root, path: wt, approved: .review)

        guard case .removed = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(try repo.sha("refs/heads/\(name)"), tip)
    }
}

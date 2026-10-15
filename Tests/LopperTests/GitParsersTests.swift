import XCTest
@testable import Lopper

final class GitParsersTests: XCTestCase {
    /// Builds `git worktree list --porcelain -z` output: one NUL after every line, one extra NUL per block.
    private func porcelainZ(_ blocks: [[String]]) -> String {
        blocks.map { $0.joined(separator: "\u{0}") + "\u{0}\u{0}" }.joined()
    }

    func testParseWorktreeListHandlesBranchDetachedLockedAndPrunable() {
        let text = porcelainZ([
            ["worktree /work/repo", "HEAD 1111111111111111111111111111111111111111", "branch refs/heads/main"],
            ["worktree /work/repo-feature", "HEAD 2222222222222222222222222222222222222222",
             "branch refs/heads/feature/login", "locked agent is running"],
            ["worktree /work/repo-detached", "HEAD 3333333333333333333333333333333333333333", "detached"],
            ["worktree /work/gone", "HEAD 4444444444444444444444444444444444444444",
             "branch refs/heads/old", "prunable gitdir file points to non-existent location"],
        ])
        let entries = GitParsers.parseWorktreeList(text)
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].path, "/work/repo")
        XCTAssertEqual(entries[0].branch, "main")
        XCTAssertEqual(entries[1].branch, "feature/login")
        XCTAssertTrue(entries[1].isLocked)
        XCTAssertNil(entries[2].branch)
        XCTAssertFalse(entries[2].isLocked)
        XCTAssertTrue(entries[3].isPrunable)
    }

    func testParseWorktreeListKeepsPathsWithSpacesAndAccents() {
        let text = porcelainZ([["worktree /Users/me/Mes Projets/dépôt é", "HEAD abc", "branch refs/heads/main"]])
        XCTAssertEqual(GitParsers.parseWorktreeList(text).first?.path, "/Users/me/Mes Projets/dépôt é")
    }

    func testParseWorktreeListMarksBare() {
        let entries = GitParsers.parseWorktreeList(porcelainZ([["worktree /srv/repo.git", "bare"]]))
        XCTAssertEqual(entries.count, 1)
        XCTAssertTrue(entries[0].isBare)
    }

    func testParseBranches() {
        let nul = "\u{0}"
        let text = [
            "main\(nul)aaa\(nul)origin/main\(nul)\(nul)1700000000\(nul)*",
            "feature/x\(nul)bbb\(nul)origin/feature/x\(nul)[gone]\(nul)1690000000\(nul) ",
            "local-only\(nul)ccc\(nul)\(nul)\(nul)1680000000\(nul) ",
        ].joined(separator: "\n")
        let branches = GitParsers.parseBranches(text)
        XCTAssertEqual(branches.count, 3)
        XCTAssertEqual(branches[0].name, "main")
        XCTAssertTrue(branches[0].isCurrent)
        XCTAssertEqual(branches[0].upstream, "origin/main")
        XCTAssertFalse(branches[0].upstreamGone)
        XCTAssertTrue(branches[1].upstreamGone)
        XCTAssertNil(branches[2].upstream)
        XCTAssertEqual(branches[2].lastCommit, Date(timeIntervalSince1970: 1_680_000_000))
    }

    func testParseStashBranches() {
        let text = """
        WIP on feature/login: abc1234 add form
        On fix/bug-12: manual stash
        WIP on main: def5678 something
        """
        XCTAssertEqual(
            GitParsers.parseStashBranches(text),
            ["feature/login", "fix/bug-12", "main"])
    }

    func testParseStatusSeparatesDirtyUntrackedAndDisposable() {
        let entries = [
            " M src/app.ts", "?? notes.txt", "!! node_modules/", "!! apps/web/.next/",
            "!! .env.local", "A  new.ts",
        ]
        let status = GitParsers.parseStatus(
            entries.joined(separator: "\u{0}") + "\u{0}", disposable: ["node_modules", ".next"])
        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.extraFiles, ["notes.txt", ".env.local"])
        XCTAssertEqual(status.disposablePaths, ["node_modules/", "apps/web/.next/"])
    }

    func testParseStatusHandlesSpacesAccentsAndRenames() {
        // A rename is "R  new\0old\0": the trailing "from" field must not be read as a status line.
        let entries = ["R  new name.ts", "old name.ts", "?? café notes.txt", "!! mon dossier/node_modules/"]
        let status = GitParsers.parseStatus(
            entries.joined(separator: "\u{0}") + "\u{0}", disposable: ["node_modules"])
        XCTAssertTrue(status.isDirty)
        XCTAssertEqual(status.extraFiles, ["café notes.txt"])
        XCTAssertEqual(status.disposablePaths, ["mon dossier/node_modules/"])
    }

    func testParseStatusCleanTree() {
        let status = GitParsers.parseStatus("", disposable: [])
        XCTAssertFalse(status.isDirty)
        XCTAssertTrue(status.extraFiles.isEmpty)
    }
}

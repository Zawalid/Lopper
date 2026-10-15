import XCTest
@testable import Lopper

final class WorktreeFactsTests: XCTestCase {
    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return repo
    }

    func testEntryCarriesAheadLastCommitAndCreationDate() async throws {
        let repo = try baseRepo()
        let wt = repo.sandbox.appendingPathComponent("wt-agent")
        try repo.git("worktree", "add", "-b", "claude/agent", wt.path)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try repo.commit("one", files: ["a.txt": "a"], in: wt, date: when)
        try repo.commit("two", files: ["b.txt": "b"], in: wt, date: when)

        let snapshot = try await RepoInspector().inspect(repoRoot: repo.root)
        let entry = try XCTUnwrap(snapshot.worktrees.first { $0.path.lastPathComponent == "wt-agent" })

        XCTAssertEqual(entry.ahead, 2)
        XCTAssertEqual(entry.lastCommit, when)
        let created = try XCTUnwrap(entry.createdAt)
        XCTAssertLessThan(abs(created.timeIntervalSinceNow), 120)
    }

    func testMainWorktreeHasNoCreationDate() async throws {
        let repo = try baseRepo()
        let snapshot = try await RepoInspector().inspect(repoRoot: repo.root)
        let main = try XCTUnwrap(snapshot.worktrees.first { $0.isMain })
        XCTAssertNil(main.createdAt)
    }

    func testCreationDateOfAMissingFolderIsNil() {
        let missing = URL(fileURLWithPath: "/no/such/worktree-\(UUID().uuidString)")
        XCTAssertNil(WorktreeMetadata.createdAt(ofWorktreeAt: missing))
    }
}

import XCTest
@testable import Lopper

final class BranchHistoryTests: XCTestCase {
    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return repo
    }

    // MARK: Parsing

    func testParseLogReadsHashAuthorDateAndSubject() throws {
        let text = "aaa111\u{1f}Ada\u{1f}2026-10-01T10:00:00+00:00\u{1f}fix: first\u{1e}"
            + "bbb222\u{1f}Grace\u{1f}2026-10-02T11:30:00+00:00\u{1f}feat: second | with pipe\u{1e}"
        let commits = BranchHistoryReader.parseLog(text)

        XCTAssertEqual(commits.map(\.hash), ["aaa111", "bbb222"])
        XCTAssertEqual(commits.map(\.author), ["Ada", "Grace"])
        XCTAssertEqual(commits.map(\.subject), ["fix: first", "feat: second | with pipe"])
        XCTAssertEqual(commits[0].date, ISO8601DateFormatter().date(from: "2026-10-01T10:00:00+00:00"))
    }

    func testParseLogToleratesEmptyOutputAndBrokenRecords() {
        XCTAssertTrue(BranchHistoryReader.parseLog("").isEmpty)
        XCTAssertTrue(BranchHistoryReader.parseLog("not a record\u{1e}").isEmpty)
    }

    func testParseShortstat() {
        XCTAssertEqual(
            BranchHistoryReader.parseShortstat(" 3 files changed, 12 insertions(+), 4 deletions(-)\n"),
            DiffSummary(files: 3, insertions: 12, deletions: 4))
        XCTAssertEqual(
            BranchHistoryReader.parseShortstat(" 1 file changed, 1 insertion(+)\n"),
            DiffSummary(files: 1, insertions: 1, deletions: 0))
        XCTAssertEqual(
            BranchHistoryReader.parseShortstat(" 2 files changed, 5 deletions(-)\n"),
            DiffSummary(files: 2, insertions: 0, deletions: 5))
        XCTAssertNil(BranchHistoryReader.parseShortstat(""))
    }

    // MARK: Real repositories

    func testCommitsOnlyOnTheBranchAreListedNewestFirstAgainstTheDefault() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        try repo.commit("add one", files: ["one.txt": "1\n"])
        try repo.commit("add two", files: ["two.txt": "2\nmore\n"])
        try repo.git("checkout", "main")
        try repo.commit("main moves on", files: ["main-only.txt": "m\n"])

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: "feature", base: "main", git: GitRunner())

        XCTAssertEqual(history.comparedTo, "main")
        XCTAssertEqual(history.commits.map(\.subject), ["add two", "add one"])
        XCTAssertEqual(history.commits.first?.author, "Lopper Test")
        XCTAssertEqual(history.totalCommits, 2)
        XCTAssertFalse(history.isTruncated)
        XCTAssertEqual(history.diff?.files, 2, "the diff is what the branch adds, not what main changed")
    }

    func testAMergedBranchHasNothingUniqueToLose() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "done")
        try repo.commit("work", files: ["w.txt": "w\n"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: "done", base: "main", git: GitRunner())

        XCTAssertTrue(history.commits.isEmpty)
        XCTAssertEqual(history.totalCommits, 0)
    }

    func testLongHistoriesAreCappedAndSaySo() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "long")
        for index in 1...6 {
            try repo.commit("c\(index)", files: ["f\(index).txt": "\(index)\n"])
        }

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: "long", base: "main", git: GitRunner(), limit: 4)

        XCTAssertEqual(history.commits.count, 4)
        XCTAssertEqual(history.totalCommits, 6)
        XCTAssertTrue(history.isTruncated)
        XCTAssertEqual(history.commits.first?.subject, "c6")
    }

    func testWithoutADefaultBranchItListsRecentCommitsAndComparesToNothing() async throws {
        let repo = try baseRepo()
        try repo.commit("second", files: ["s.txt": "s\n"])

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: "main", base: nil, git: GitRunner(), limit: 5)

        XCTAssertNil(history.comparedTo)
        XCTAssertNil(history.diff)
        XCTAssertEqual(history.commits.map(\.subject), ["second", "base"])
    }

    func testAnUnknownRefYieldsAnEmptyHistoryInsteadOfThrowing() async throws {
        let repo = try baseRepo()

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: "no-such-branch", base: "main", git: GitRunner())

        XCTAssertTrue(history.commits.isEmpty)
        XCTAssertNil(history.diff)
    }

    func testADetachedCommitCanBeUsedAsTheRef() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "tmp")
        try repo.commit("detached work", files: ["d.txt": "d\n"])
        let sha = try repo.git("rev-parse", "HEAD")
        try repo.git("checkout", "main")

        let history = await BranchHistoryReader.read(
            repoRoot: repo.root, ref: sha, base: "main", git: GitRunner())

        XCTAssertEqual(history.commits.map(\.subject), ["detached work"])
    }
}

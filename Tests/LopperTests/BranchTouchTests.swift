import XCTest
@testable import Lopper

final class BranchTouchTests: XCTestCase {
    private func line(_ iso: String, _ subject: String) -> String { "\(iso)\u{1f}\(subject)" }

    // MARK: Parsing

    func testNewestCheckoutOfTheBranchWins() {
        let log = [
            line("2026-10-10T10:00:00+00:00", "checkout: moving from feat/x to main"),
            line("2026-10-08T09:00:00+00:00", "commit: work"),
            line("2026-10-05T08:00:00+00:00", "checkout: moving from main to feat/x"),
        ].joined(separator: "\n")

        let date = BranchTouch.parse(reflog: log, branch: "feat/x")

        XCTAssertEqual(date, ISO8601DateFormatter().date(from: "2026-10-10T10:00:00+00:00"))
    }

    func testOnlyAnExactBranchNameCounts() {
        let log = line("2026-10-10T10:00:00+00:00", "checkout: moving from main to feat/xy")

        XCTAssertNil(BranchTouch.parse(reflog: log, branch: "feat/x"))
        XCTAssertNil(BranchTouch.parse(reflog: log, branch: "feat"))
    }

    func testCommitsAndOtherEntriesAreNotCheckouts() {
        let log = [
            line("2026-10-10T10:00:00+00:00", "commit: touch feat/x"),
            line("2026-10-09T10:00:00+00:00", "reset: moving to HEAD~1"),
            line("2026-10-08T10:00:00+00:00", "pull: Fast-forward"),
        ].joined(separator: "\n")

        XCTAssertNil(BranchTouch.parse(reflog: log, branch: "feat/x"))
    }

    func testEmptyAndMalformedLogsGiveNothing() {
        XCTAssertNil(BranchTouch.parse(reflog: "", branch: "x"))
        XCTAssertNil(BranchTouch.parse(reflog: "garbage without separator", branch: "x"))
        XCTAssertNil(BranchTouch.parse(reflog: line("not a date", "checkout: moving from a to x"), branch: "x"))
    }

    func testLeavingABranchCountsAsHavingWorkedOnIt() {
        let log = line("2026-10-10T10:00:00+00:00", "checkout: moving from feat/x to main")

        XCTAssertNotNil(BranchTouch.parse(reflog: log, branch: "feat/x"))
    }

    // MARK: Real repository

    func testABranchYouSwitchedToHasACheckoutTime() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["a.txt": "a\n"])
        try repo.git("checkout", "-b", "feature")
        try repo.commit("work", files: ["b.txt": "b\n"])
        try repo.git("checkout", "main")

        let date = await BranchTouch.lastCheckedOut(branch: "feature", in: repo.root, git: GitRunner())

        let found = try XCTUnwrap(date)
        XCTAssertLessThan(abs(found.timeIntervalSinceNow), 120)
    }

    func testABranchNobodySwitchedToHasNone() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["a.txt": "a\n"])
        try repo.git("branch", "never-visited")

        let date = await BranchTouch.lastCheckedOut(branch: "never-visited", in: repo.root, git: GitRunner())

        XCTAssertNil(date)
    }

    func testAnOptionLikeBranchNameIsRefusedInsteadOfPassedToGit() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["a.txt": "a\n"])

        let date = await BranchTouch.lastCheckedOut(branch: "--all", in: repo.root, git: GitRunner())

        XCTAssertNil(date)
    }
}

import XCTest
@testable import Lopper

/// When GitHub cannot be reached the snapshot and every row say so, apart from "gh is missing" or "not signed in",
/// so the app can tell a person to check their connection rather than to install something.
final class OfflineSnapshotTests: XCTestCase {
    private struct Failing: PRProvider {
        let error: Error
        func mergedPullRequests(in repoRoot: URL) async throws -> [MergedPR] { throw error }
    }

    private func snapshot(failingWith error: Error) async throws -> RepoSnapshot {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        return try await RepoInspector(prProvider: Failing(error: error)).inspect(repoRoot: repo.root)
    }

    func testAnOfflineProviderMarksTheSnapshotOffline() async throws {
        let result = try await snapshot(failingWith: GhCliProvider.Unavailable.offline)

        XCTAssertFalse(result.prDetectionAvailable)
        XCTAssertTrue(result.prOffline)
    }

    func testATimeoutAndANoHostMessageAreBothOffline() async throws {
        let timedOut = try await snapshot(failingWith: CommandError.timedOut(command: "gh pr list"))
        let noHost = try await snapshot(failingWith: CommandError.failed(
            command: "gh pr list", exitCode: 1, stderr: "dial tcp: lookup api.github.com: no such host"))

        XCTAssertTrue(timedOut.prOffline)
        XCTAssertTrue(noHost.prOffline)
    }

    func testAMissingOrSignedOutGhIsNotOffline() async throws {
        let missing = try await snapshot(failingWith: CommandError.launchFailed("gh missing"))
        let signedOut = try await snapshot(failingWith: CommandError.failed(
            command: "gh pr list", exitCode: 4, stderr: "To get started with GitHub CLI, please run:  gh auth login"))

        XCTAssertFalse(missing.prOffline)
        XCTAssertFalse(signedOut.prOffline)
        XCTAssertFalse(missing.prDetectionAvailable)
    }

    func testAWorkingProviderIsNeitherUnavailableNorOffline() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        struct Working: PRProvider {
            func mergedPullRequests(in repoRoot: URL) async throws -> [MergedPR] { [] }
        }

        let result = try await RepoInspector(prProvider: Working()).inspect(repoRoot: repo.root)

        XCTAssertTrue(result.prDetectionAvailable)
        XCTAssertFalse(result.prOffline)
    }

    func testRowsCarryTheOfflineFactSoTheInspectorCanExplainIt() async throws {
        let result = try await snapshot(failingWith: GhCliProvider.Unavailable.offline)

        let rows = RowMapper.rows(for: result, sizes: [:])

        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.facts.prOffline })
    }

    func testErrorClassificationCoversEveryWayOfflineShowsUp() {
        XCTAssertTrue(GitHubReachability.isNetworkError(GhCliProvider.Unavailable.offline))
        XCTAssertTrue(GitHubReachability.isNetworkError(CommandError.timedOut(command: "gh")))
        XCTAssertTrue(GitHubReachability.isNetworkError(CommandError.failed(command: "gh", exitCode: 1, stderr: "i/o timeout")))
        XCTAssertFalse(GitHubReachability.isNetworkError(CommandError.failed(command: "gh", exitCode: 1, stderr: "HTTP 404")))
        XCTAssertFalse(GitHubReachability.isNetworkError(CommandError.launchFailed("x")))
        XCTAssertFalse(GitHubReachability.isNetworkError(CancellationError()))
    }

    func testAScanStartedByAPersonAlwaysTriesGitHubAgain() {
        let reachability = GitHubReachability()
        reachability.recordNetworkFailure()

        reachability.reset()

        XCTAssertFalse(reachability.isOffline)
    }

    // MARK: The single-branch lookup also stays out of the way

    func testTheSingleBranchLookupDoesNotWaitWhenOfflineAndRemembersATimeout() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lopper-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gh = dir.appendingPathComponent("gh")
        let calls = dir.appendingPathComponent("calls")
        try "".write(to: calls, atomically: true, encoding: .utf8)
        try "#!/bin/sh\necho x >> '\(calls.path)'\nsleep 5\n".write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        let provider = try XCTUnwrap(GhCliProvider(executable: gh, timeout: .seconds(1), reachability: GitHubReachability()))
        let folder = FileManager.default.temporaryDirectory

        let first = await provider.pullRequestStatus(forBranch: "feature", in: folder)
        let started = Date()
        let second = await provider.pullRequestStatus(forBranch: "other", in: folder)

        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "the second lookup must not run gh at all")
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count, 1)
    }
}

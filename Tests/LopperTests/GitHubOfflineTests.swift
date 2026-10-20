import XCTest
@testable import Lopper

/// A scan of dozens of repositories must not wait for GitHub once per repository when GitHub cannot be reached.
final class GitHubOfflineTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    // MARK: Remembering that GitHub is unreachable

    func testGitHubIsReachableUntilAFailureIsRecorded() {
        let reachability = GitHubReachability()

        XCTAssertFalse(reachability.isOffline)
    }

    func testANetworkFailureMakesLaterCallsSkipGitHubUntilTheCooldownEnds() {
        let clock = Clock()
        let reachability = GitHubReachability(cooldown: 45, now: { clock.now })

        reachability.recordNetworkFailure()
        XCTAssertTrue(reachability.isOffline)

        clock.now.addTimeInterval(44)
        XCTAssertTrue(reachability.isOffline)

        clock.now.addTimeInterval(2)
        XCTAssertFalse(reachability.isOffline, "after the cooldown GitHub is tried again")
    }

    func testASuccessClearsTheMemory() {
        let reachability = GitHubReachability()
        reachability.recordNetworkFailure()

        reachability.recordSuccess()

        XCTAssertFalse(reachability.isOffline)
    }

    func testOnlyNetworkLookingFailuresCountAsOffline() {
        XCTAssertTrue(GitHubReachability.looksLikeNoNetwork(
            #"Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host"#))
        XCTAssertTrue(GitHubReachability.looksLikeNoNetwork("error connecting to api.github.com"))
        XCTAssertTrue(GitHubReachability.looksLikeNoNetwork("read tcp 192.168.1.5:5000: i/o timeout"))
        XCTAssertTrue(GitHubReachability.looksLikeNoNetwork("dial tcp 140.82.1.1:443: connect: network is unreachable"))
        XCTAssertFalse(GitHubReachability.looksLikeNoNetwork("HTTP 404: Not Found (https://api.github.com/repos/x/y)"))
        XCTAssertFalse(GitHubReachability.looksLikeNoNetwork("To get started with GitHub CLI, please run: gh auth login"))
        XCTAssertFalse(GitHubReachability.looksLikeNoNetwork("none of the git remotes point to a known GitHub host"))
    }

    // MARK: The provider asks once

    private func stubGh(_ script: String) throws -> (gh: URL, calls: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lopper-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let gh = dir.appendingPathComponent("gh")
        let calls = dir.appendingPathComponent("calls")
        try "".write(to: calls, atomically: true, encoding: .utf8)
        try ("#!/bin/sh\necho x >> '\(calls.path)'\n" + script + "\n").write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        return (gh, calls)
    }

    private func callCount(_ calls: URL) throws -> Int {
        try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").count
    }

    func testAfterOneNetworkFailureTheOtherRepositoriesDoNotRunGhAtAll() async throws {
        let (gh, calls) = try stubGh(#"echo 'Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host' >&2; exit 1"#)
        let provider = try XCTUnwrap(GhCliProvider(executable: gh, reachability: GitHubReachability()))
        let folder = FileManager.default.temporaryDirectory

        for _ in 0..<5 { _ = try? await provider.mergedPullRequests(in: folder) }

        XCTAssertEqual(try callCount(calls), 1, "gh is asked once, not once per repository")
    }

    func testASlowGhThatTimesOutAlsoStopsTheOthers() async throws {
        let (gh, calls) = try stubGh("sleep 5")
        let provider = try XCTUnwrap(GhCliProvider(
            executable: gh, timeout: .seconds(1), reachability: GitHubReachability()))
        let folder = FileManager.default.temporaryDirectory

        let started = Date()
        for _ in 0..<5 { _ = try? await provider.mergedPullRequests(in: folder) }

        XCTAssertEqual(try callCount(calls), 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "five repositories must not wait five timeouts")
    }

    func testAFailureThatIsNotTheNetworkDoesNotStopTheOthers() async throws {
        let (gh, calls) = try stubGh("echo 'HTTP 404: Not Found' >&2; exit 1")
        let provider = try XCTUnwrap(GhCliProvider(executable: gh, reachability: GitHubReachability()))
        let folder = FileManager.default.temporaryDirectory

        for _ in 0..<3 { _ = try? await provider.mergedPullRequests(in: folder) }

        XCTAssertEqual(try callCount(calls), 3, "a repository that is not on GitHub says nothing about the others")
    }

    func testWhenOfflineTheProviderFailsFastWithAClearError() async throws {
        let (gh, _) = try stubGh("exit 0")
        let reachability = GitHubReachability()
        reachability.recordNetworkFailure()
        let provider = try XCTUnwrap(GhCliProvider(executable: gh, reachability: reachability))

        do {
            _ = try await provider.mergedPullRequests(in: FileManager.default.temporaryDirectory)
            XCTFail("expected the offline error")
        } catch {
            XCTAssertEqual(error as? GhCliProvider.Unavailable, .offline)
        }
    }

    func testTheDefaultTimeoutIsShortEnoughToNotStallAScan() throws {
        let (gh, _) = try stubGh("exit 0")

        let provider = try XCTUnwrap(GhCliProvider(executable: gh))

        XCTAssertLessThanOrEqual(provider.runner.timeout, .seconds(20))
    }
}

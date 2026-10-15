import XCTest
@testable import Lopper

final class RemoteLinksTests: XCTestCase {
    private let remotes = [
        "git@github.com:acme/api.git",
        "https://github.com/acme/api.git",
        "https://github.com/acme/api",
        "ssh://git@github.com/acme/api.git",
    ]

    func testRepositoryPageInEveryCommonRemoteShape() {
        for remote in remotes {
            XCTAssertEqual(
                RemoteLinks.repository(remoteURL: remote), URL(string: "https://github.com/acme/api"), remote)
        }
    }

    func testBranchPageKeepsSlashesAndEscapesTheRest() {
        XCTAssertEqual(
            RemoteLinks.branch(remoteURL: remotes[0], name: "feat/landing page#2"),
            URL(string: "https://github.com/acme/api/tree/feat/landing%20page%232"))
    }

    func testComparePageShowsWhatTheBranchAddsToTheBase() {
        XCTAssertEqual(
            RemoteLinks.compare(remoteURL: remotes[1], base: "main", branch: "feat/x"),
            URL(string: "https://github.com/acme/api/compare/main...feat/x"))
    }

    func testCommitPage() {
        XCTAssertEqual(
            RemoteLinks.commit(remoteURL: remotes[2], hash: "0123456789abcdef"),
            URL(string: "https://github.com/acme/api/commit/0123456789abcdef"))
    }

    func testOtherHostsAndMissingRemotesGiveNoLinks() {
        for remote in [nil, "", "git@gitlab.com:acme/api.git", "https://github.com/acme"] as [String?] {
            XCTAssertNil(RemoteLinks.repository(remoteURL: remote), remote ?? "nil")
            XCTAssertNil(RemoteLinks.branch(remoteURL: remote, name: "x"))
            XCTAssertNil(RemoteLinks.compare(remoteURL: remote, base: "main", branch: "x"))
            XCTAssertNil(RemoteLinks.commit(remoteURL: remote, hash: "abc"))
        }
    }

    func testPullRequestLinksStillWork() {
        XCTAssertEqual(
            PullRequestLink.url(remoteURL: remotes[0], number: 7), URL(string: "https://github.com/acme/api/pull/7"))
    }
}

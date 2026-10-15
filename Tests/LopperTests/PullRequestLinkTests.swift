import XCTest
@testable import Lopper

final class PullRequestLinkTests: XCTestCase {
    func testGitHubRemotesInEveryCommonShape() {
        let expected = URL(string: "https://github.com/acme/api/pull/227")
        XCTAssertEqual(PullRequestLink.url(remoteURL: "git@github.com:acme/api.git", number: 227), expected)
        XCTAssertEqual(PullRequestLink.url(remoteURL: "https://github.com/acme/api.git", number: 227), expected)
        XCTAssertEqual(PullRequestLink.url(remoteURL: "https://github.com/acme/api", number: 227), expected)
        XCTAssertEqual(PullRequestLink.url(remoteURL: "ssh://git@github.com/acme/api.git", number: 227), expected)
    }

    func testNonGitHubOrMissingRemotesGiveNoLink() {
        XCTAssertNil(PullRequestLink.url(remoteURL: nil, number: 1))
        XCTAssertNil(PullRequestLink.url(remoteURL: "", number: 1))
        XCTAssertNil(PullRequestLink.url(remoteURL: "git@gitlab.com:acme/api.git", number: 1))
        XCTAssertNil(PullRequestLink.url(remoteURL: "https://github.com/acme", number: 1))
    }
}

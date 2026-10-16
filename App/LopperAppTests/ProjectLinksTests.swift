import XCTest
@testable import LopperApp

final class ProjectLinksTests: XCTestCase {
    func testEveryLinkIsAnHTTPSAddressOnItsOwnHost() {
        let expected: [(ProjectLinks.Link, String)] = [
            (.authorGitHub, "github.com"),
            (.authorWebsite, "zawalid.com"),
            (.authorX, "x.com"),
            (.repository, "github.com"),
            (.issues, "github.com"),
            (.license, "github.com"),
        ]
        for (link, host) in expected {
            XCTAssertEqual(link.url.scheme, "https", "\(link) must be https")
            XCTAssertEqual(link.url.host(), host, "\(link) points at the wrong host")
        }
    }

    func testTheAuthorLinksNameTheAuthor() {
        XCTAssertEqual(ProjectLinks.author, "Walid Zakan")
        XCTAssertEqual(ProjectLinks.Link.authorGitHub.url.path, "/Zawalid")
        XCTAssertEqual(ProjectLinks.Link.authorX.url.path, "/Zawaalid")
    }

    func testIssuesAndLicenseLiveInsideTheRepository() {
        let repository = ProjectLinks.Link.repository.url.path
        XCTAssertTrue(ProjectLinks.Link.issues.url.path.hasPrefix(repository))
        XCTAssertTrue(ProjectLinks.Link.license.url.path.hasPrefix(repository))
    }
}

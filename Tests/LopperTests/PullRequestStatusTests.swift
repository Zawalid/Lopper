import XCTest
@testable import Lopper

final class PullRequestStatusTests: XCTestCase {
    private func decode(_ json: String) throws -> [PullRequestStatus] {
        try PullRequestStatus.decode(json)
    }

    func testAnOpenApprovedPullRequestWithPassingChecks() throws {
        let json = """
        [{"number":61,"title":"feat: landing","state":"OPEN","isDraft":false,"reviewDecision":"APPROVED",
          "url":"https://github.com/acme/api/pull/61","updatedAt":"2026-10-10T10:00:00Z",
          "statusCheckRollup":[
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SKIPPED"},
            {"__typename":"StatusContext","state":"SUCCESS"}]}]
        """
        let pr = try XCTUnwrap(decode(json).first)

        XCTAssertEqual(pr.number, 61)
        XCTAssertEqual(pr.title, "feat: landing")
        XCTAssertEqual(pr.state, .open)
        XCTAssertFalse(pr.isDraft)
        XCTAssertEqual(pr.review, .approved)
        XCTAssertEqual(pr.checks, .passing)
        XCTAssertEqual(pr.url, URL(string: "https://github.com/acme/api/pull/61"))
    }

    func testAFailingCheckWinsOverPassingOnes() throws {
        let json = """
        [{"number":1,"title":"t","state":"OPEN","isDraft":true,"reviewDecision":"CHANGES_REQUESTED","url":"",
          "updatedAt":"2026-10-10T10:00:00Z",
          "statusCheckRollup":[
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]}]
        """
        let pr = try XCTUnwrap(decode(json).first)

        XCTAssertEqual(pr.checks, .failing)
        XCTAssertEqual(pr.review, .changesRequested)
        XCTAssertTrue(pr.isDraft)
        XCTAssertNil(pr.url, "an empty url is no link")
    }

    func testARunningCheckMeansPendingUnlessSomethingAlreadyFailed() throws {
        let json = """
        [{"number":2,"title":"t","state":"OPEN","isDraft":false,"reviewDecision":"","url":"https://x/y",
          "updatedAt":"2026-10-10T10:00:00Z",
          "statusCheckRollup":[
            {"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":""},
            {"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]
        """
        let pr = try XCTUnwrap(decode(json).first)

        XCTAssertEqual(pr.checks, .pending)
        XCTAssertEqual(pr.review, PullRequestStatus.Review.none)
    }

    func testNoChecksAtAll() throws {
        let json = """
        [{"number":3,"title":"t","state":"CLOSED","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","url":"https://x/z",
          "updatedAt":"2026-10-10T10:00:00Z","statusCheckRollup":[]}]
        """
        let pr = try XCTUnwrap(decode(json).first)

        XCTAssertEqual(pr.checks, PullRequestStatus.Checks.none)
        XCTAssertEqual(pr.state, .closed)
        XCTAssertEqual(pr.review, .reviewRequired)
    }

    func testTheOpenPullRequestIsTheRelevantOneEvenWhenOlder() throws {
        let json = """
        [{"number":10,"title":"old merged","state":"MERGED","isDraft":false,"reviewDecision":"APPROVED","url":"https://x/10",
          "updatedAt":"2026-10-20T10:00:00Z","statusCheckRollup":[]},
         {"number":11,"title":"open one","state":"OPEN","isDraft":false,"reviewDecision":"","url":"https://x/11",
          "updatedAt":"2026-10-01T10:00:00Z","statusCheckRollup":[]},
         {"number":9,"title":"older closed","state":"CLOSED","isDraft":false,"reviewDecision":"","url":"https://x/9",
          "updatedAt":"2026-09-01T10:00:00Z","statusCheckRollup":[]}]
        """
        let all = try decode(json)

        XCTAssertEqual(PullRequestStatus.mostRelevant(in: all)?.number, 11)
    }

    func testWithoutAnOpenOneTheMostRecentlyUpdatedWins() throws {
        let json = """
        [{"number":5,"title":"a","state":"CLOSED","isDraft":false,"reviewDecision":"","url":"https://x/5",
          "updatedAt":"2026-08-01T10:00:00Z","statusCheckRollup":[]},
         {"number":6,"title":"b","state":"MERGED","isDraft":false,"reviewDecision":"","url":"https://x/6",
          "updatedAt":"2026-09-01T10:00:00Z","statusCheckRollup":[]}]
        """
        XCTAssertEqual(PullRequestStatus.mostRelevant(in: try decode(json))?.number, 6)
        XCTAssertNil(PullRequestStatus.mostRelevant(in: []))
    }

    func testUnexpectedShapesFailToDecodeInsteadOfGuessing() {
        XCTAssertThrowsError(try decode("{\"not\":\"a list\"}"))
        XCTAssertThrowsError(try decode("nonsense"))
    }

    func testTheMostRelevantPullRequestAlwaysWinsOverNilFieldsInTheOthers() throws {
        let json = """
        [{"number":1,"title":"only","state":"OPEN","isDraft":false,"reviewDecision":null,"url":null,
          "updatedAt":"2026-10-10T10:00:00Z","statusCheckRollup":null}]
        """
        let pr = try XCTUnwrap(decode(json).first)

        XCTAssertEqual(pr.review, PullRequestStatus.Review.none)
        XCTAssertEqual(pr.checks, PullRequestStatus.Checks.none)
        XCTAssertNil(pr.url)
    }
}

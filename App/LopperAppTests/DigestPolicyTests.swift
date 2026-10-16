import XCTest
@testable import LopperApp

final class DigestPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ n: Double) -> Date { now.addingTimeInterval(-n * 86_400) }

    func testItNotifiesOncePerWeekAndOnlyWhenThereIsSomethingWorthSaying() {
        XCTAssertTrue(DigestPolicy.shouldNotify(
            reclaimable: 3_000_000_000, last: nil, now: now))
        XCTAssertTrue(DigestPolicy.shouldNotify(
            reclaimable: 3_000_000_000, last: days(8), now: now))
        XCTAssertFalse(DigestPolicy.shouldNotify(
            reclaimable: 3_000_000_000, last: days(3), now: now), "already told them this week")
        XCTAssertFalse(DigestPolicy.shouldNotify(
            reclaimable: 200_000_000, last: nil, now: now), "too little to interrupt anyone for")
    }

    func testTheMessageNamesTheNumbersAndWhereToLook() {
        let message = DigestPolicy.message(
            safeItems: 7, itemBytes: 1_200_000_000, folderBytes: 4_100_000_000, agentsFinished: 3)

        XCTAssertTrue(message.title.contains("5,3 GB") || message.title.contains("5.3 GB"), message.title)
        XCTAssertTrue(message.body.contains("7 branches and worktrees"), message.body)
        XCTAssertTrue(message.body.contains("3 agent worktrees"), message.body)
    }

    func testAMessageWithNothingToReportLeavesOutThoseParts() {
        let message = DigestPolicy.message(safeItems: 0, itemBytes: 0, folderBytes: 2_000_000_000, agentsFinished: 0)

        XCTAssertFalse(message.body.contains("branches"))
        XCTAssertFalse(message.body.contains("agent"))
        XCTAssertTrue(message.body.contains("generated folders"))
    }

    func testTheMessageMentionsWhatTheRulesFound() {
        let message = DigestPolicy.message(
            safeItems: 2, itemBytes: 100_000_000, folderBytes: 2_000_000_000, agentsFinished: 0, ruleSuggestions: 2)

        XCTAssertTrue(message.body.contains("Your rules found 2 things worth reviewing"), message.body)
    }
}

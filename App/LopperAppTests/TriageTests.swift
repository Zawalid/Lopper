import XCTest
@testable import LopperApp

final class TriageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Position

    func testPositionInTheMiddleHasBothNeighbours() {
        let position = Triage.position(of: "b", in: ["a", "b", "c"])

        XCTAssertEqual(position, TriagePosition(index: 2, total: 3, previousID: "a", nextID: "c"))
    }

    func testTheEndsHaveOnlyOneNeighbour() {
        XCTAssertEqual(Triage.position(of: "a", in: ["a", "b"]), TriagePosition(index: 1, total: 2, previousID: nil, nextID: "b"))
        XCTAssertEqual(Triage.position(of: "b", in: ["a", "b"]), TriagePosition(index: 2, total: 2, previousID: "a", nextID: nil))
    }

    func testAMissingItemOrAnEmptyQueueHasNoPosition() {
        XCTAssertNil(Triage.position(of: "z", in: ["a"]))
        XCTAssertNil(Triage.position(of: "a", in: []))
    }

    func testASingleItemQueueHasNoNeighbours() {
        XCTAssertEqual(Triage.position(of: "a", in: ["a"]), TriagePosition(index: 1, total: 1, previousID: nil, nextID: nil))
    }

    // MARK: Snoozes

    func testAnItemIsSnoozedUntilItsDateAndNotAfter() {
        let until = now.addingTimeInterval(3_600)
        let snoozes = Snoozes().snoozing("item", until: until)

        XCTAssertTrue(snoozes.isSnoozed("item", now: now))
        XCTAssertFalse(snoozes.isSnoozed("item", now: until.addingTimeInterval(1)))
        XCTAssertFalse(snoozes.isSnoozed("other", now: now))
    }

    func testWakingAnItemRemovesItAtOnce() {
        let snoozes = Snoozes().snoozing("item", until: now.addingTimeInterval(3_600)).waking("item")

        XCTAssertFalse(snoozes.isSnoozed("item", now: now))
        XCTAssertNil(snoozes.until(for: "item"))
    }

    func testPruningDropsOnlyExpiredEntries() {
        let snoozes = Snoozes()
            .snoozing("old", until: now.addingTimeInterval(-10))
            .snoozing("new", until: now.addingTimeInterval(10))
            .pruned(now: now)

        XCTAssertNil(snoozes.until(for: "old"))
        XCTAssertNotNil(snoozes.until(for: "new"))
    }

    func testSnoozesSurviveAStringRoundTrip() {
        let original = Snoozes().snoozing("a", until: now.addingTimeInterval(500)).snoozing("b", until: now.addingTimeInterval(900))
        let restored = Snoozes(encoded: original.encoded)

        XCTAssertEqual(restored, original)
    }

    func testBrokenStoredTextBecomesNoSnoozesInsteadOfAFailure() {
        XCTAssertEqual(Snoozes(encoded: "not json at all"), Snoozes())
        XCTAssertEqual(Snoozes(encoded: nil), Snoozes())
        XCTAssertEqual(Snoozes(encoded: ""), Snoozes())
    }

    func testDurationsCountFromTheMomentOfSnoozing() {
        XCTAssertEqual(SnoozeDuration.oneWeek.date(from: now), now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(SnoozeDuration.twoWeeks.date(from: now), now.addingTimeInterval(14 * 86_400))
        XCTAssertEqual(SnoozeDuration.oneMonth.date(from: now), now.addingTimeInterval(30 * 86_400))
    }
}

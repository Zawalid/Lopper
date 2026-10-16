import XCTest
@testable import LopperApp

final class OverviewLayoutTests: XCTestCase {
    private let states: [(String, OverviewState)] = [
        ("needsFolders", .needsFolders),
        ("scanning", .scanning(done: 3, total: 17)),
        ("scanning, nothing yet", .scanning(done: 0, total: 0)),
        ("nothingFound", .nothingFound),
        ("allTidy", .allTidy(review: 2)),
        ("allTidy, nothing to review", .allTidy(review: 0)),
        ("ready", .ready),
    ]

    func testNoStateEverListsASectionTwice() {
        for (name, state) in states {
            let sections = OverviewLayout.sections(for: state)
            XCTAssertEqual(sections.count, Set(sections).count, "\(name) repeats a section: \(sections)")
        }
    }

    func testEveryStateStartsWithTheHero() {
        for (name, state) in states {
            XCTAssertEqual(OverviewLayout.sections(for: state).first, .hero, name)
        }
    }

    func testWorthALookAppearsExactlyOnceWheneverThereIsSomethingToLookAt() {
        XCTAssertEqual(OverviewLayout.sections(for: .ready).filter { $0 == .worthALook }.count, 1)
        XCTAssertEqual(OverviewLayout.sections(for: .allTidy(review: 3)).filter { $0 == .worthALook }.count, 1)
    }

    func testTheStatStripIsOnlyForTheReadyState() {
        for (name, state) in states where state != .ready {
            XCTAssertFalse(OverviewLayout.sections(for: state).contains(.statStrip), name)
        }
        XCTAssertTrue(OverviewLayout.sections(for: .ready).contains(.statStrip))
    }

    func testTheFirstScanShowsOnePlaceholderGridNotTwo() {
        // The scanning hero draws its own placeholders, so the repository cards must not add more.
        XCTAssertFalse(OverviewLayout.sections(for: .scanning(done: 1, total: 10)).contains(.cards))
    }

    func testBeforeAnyFolderIsChosenOnlyTheInvitationShows() {
        XCTAssertEqual(OverviewLayout.sections(for: .needsFolders), [.hero])
    }

    func testRuleSuggestionsSitBetweenTheNumbersAndWhatNeedsALook() {
        let ready = OverviewLayout.sections(for: .ready)
        XCTAssertLessThan(ready.firstIndex(of: .statStrip)!, ready.firstIndex(of: .suggestions)!)
        XCTAssertLessThan(ready.firstIndex(of: .suggestions)!, ready.firstIndex(of: .worthALook)!)
        XCTAssertTrue(OverviewLayout.sections(for: .allTidy(review: 0)).contains(.suggestions),
                      "folders can be worth clearing even when no branch is")
        XCTAssertFalse(OverviewLayout.sections(for: .scanning(done: 1, total: 4)).contains(.suggestions))
        XCTAssertFalse(OverviewLayout.sections(for: .needsFolders).contains(.suggestions))
    }
}

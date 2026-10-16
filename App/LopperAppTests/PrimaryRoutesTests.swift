import XCTest
@testable import LopperApp

final class PrimaryRoutesTests: XCTestCase {
    func testSidebarOffersOverviewAgentsDiskOnlyHereAndHistoryInThatOrder() {
        XCTAssertEqual(PrimaryRoute.allCases.map(\.route), [.overview, .agents, .disk, .onlyHere, .history])
        XCTAssertEqual(PrimaryRoute.allCases.map(\.title), ["Overview", "Agents", "Disk", "Only on this Mac", "History"])
    }

    func testEveryPrimaryRouteHasASymbolAndAShortcutDigit() {
        for item in PrimaryRoute.allCases {
            XCTAssertFalse(item.symbol.isEmpty)
        }
        XCTAssertEqual(PrimaryRoute.allCases.map(\.shortcutDigit), ["1", "2", "3", "4", "5"])
    }
}

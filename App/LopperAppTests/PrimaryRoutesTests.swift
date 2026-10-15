import XCTest
@testable import LopperApp

final class PrimaryRoutesTests: XCTestCase {
    func testSidebarOffersOverviewAgentsAndHistoryInThatOrder() {
        XCTAssertEqual(PrimaryRoute.allCases.map(\.route), [.overview, .agents, .history])
        XCTAssertEqual(PrimaryRoute.allCases.map(\.title), ["Overview", "Agents", "History"])
    }

    func testEveryPrimaryRouteHasASymbolAndAShortcutDigit() {
        for item in PrimaryRoute.allCases {
            XCTAssertFalse(item.symbol.isEmpty)
        }
        XCTAssertEqual(PrimaryRoute.allCases.map(\.shortcutDigit), ["1", "2", "3"])
    }
}

import XCTest
@testable import LopperApp

final class PrimaryRoutesTests: XCTestCase {
    func testSidebarOffersOverviewAgentsDiskAndHistoryInThatOrder() {
        XCTAssertEqual(PrimaryRoute.allCases.map(\.route), [.overview, .agents, .disk, .history])
        XCTAssertEqual(PrimaryRoute.allCases.map(\.title), ["Overview", "Agents", "Disk", "History"])
    }

    func testEveryPrimaryRouteHasASymbolAndAShortcutDigit() {
        for item in PrimaryRoute.allCases {
            XCTAssertFalse(item.symbol.isEmpty)
        }
        XCTAssertEqual(PrimaryRoute.allCases.map(\.shortcutDigit), ["1", "2", "3", "4"])
    }
}

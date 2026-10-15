import XCTest
@testable import LopperApp

final class SettingsPaneTests: XCTestCase {
    func testEveryPaneHasAUniqueIdentityATitleAndASymbol() {
        let panes = SettingsPane.allCases
        XCTAssertEqual(Set(panes.map(\.id)).count, panes.count)
        for pane in panes {
            XCTAssertFalse(pane.title.isEmpty, "\(pane)")
            XCTAssertFalse(pane.symbol.isEmpty, "\(pane)")
        }
    }

    func testPanesThatDoNotExistYetAreHiddenAndOrderIsStable() {
        let available = SettingsPane.available
        XCTAssertFalse(available.contains(.notifications), "notifications arrives with automation rules")
        XCTAssertEqual(available.first, .general)
        XCTAssertEqual(available, [.general, .folders, .safety, .tools, .advanced, .about])
    }
}

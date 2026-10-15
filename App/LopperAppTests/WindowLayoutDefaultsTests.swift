import XCTest
@testable import LopperApp

final class WindowLayoutDefaultsTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let name = "lopper-layout-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    func testSavedSplitViewFramesAreRemovedAndOtherKeysKept() {
        let defaults = makeDefaults()
        defaults.set(["0, 0, 308, 700, NO, NO", "0, 0, 1208.5, 700, NO, NO"],
                     forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView")
        defaults.set("324 192 1080 700 0 0 1728 1084 ", forKey: "NSWindow Frame main")
        defaults.set("repo:/code/a", forKey: "lastRoute")

        WindowLayoutDefaults.discardSavedSplitViewFrames(in: defaults)

        XCTAssertNil(defaults.object(forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView"))
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame main"), "324 192 1080 700 0 0 1728 1084 ")
        XCTAssertEqual(defaults.string(forKey: "lastRoute"), "repo:/code/a")
    }

    func testDoesNothingWhenThereIsNothingSaved() {
        let defaults = makeDefaults()
        defaults.set(1, forKey: "somethingElse")
        WindowLayoutDefaults.discardSavedSplitViewFrames(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: "somethingElse"), 1)
    }
}

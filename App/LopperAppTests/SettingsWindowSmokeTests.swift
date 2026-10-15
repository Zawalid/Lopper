import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Visits every Settings pane in a real window and changes one thing in each, the way a person would.
@MainActor
final class SettingsWindowSmokeTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func show(_ pane: SettingsPane, model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: SettingsView(initialPane: pane).environment(model))
        let window = NSWindow(contentViewController: controller)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func model() async -> AppModel {
        await RenderSupport.makeModel(snapshots: [Fixtures.sample])
    }

    func testEveryAvailablePaneOpensInARealWindow() async {
        let model = await model()
        for pane in SettingsPane.available {
            let window = show(pane, model: model)
            spin(0.3)
            XCTAssertNotNil(window.contentViewController, "\(pane)")
            window.close()
        }
    }

    func testChangingSettingsFromEachPaneDoesNotCrash() async {
        let model = await model()

        var window = show(.folders, model: model)
        spin(0.2)
        model.addRoots([URL(fileURLWithPath: "/work/projects")])
        spin(0.3)
        model.updateSettings { $0.folders[0].excludePatterns = ["legacy-*"] }
        spin(0.3)
        model.updateSettings { $0.folders[0].isEnabled = false }
        spin(0.3)
        window.close()

        window = show(.safety, model: model)
        spin(0.2)
        model.updateSettings { $0.protectedPatterns = TagList.adding("staging", to: $0.protectedPatterns) }
        spin(0.2)
        model.updateSettings { $0.repos[Fixtures.root.path] = RepoOverrides(defaultBranch: "trunk") }
        spin(0.3)
        model.removeRepoOverrides(for: Fixtures.root)
        spin(0.3)
        window.close()

        window = show(.tools, model: model)
        await model.refreshToolStatus()
        spin(0.3)
        window.close()

        window = show(.advanced, model: model)
        spin(0.3)
        window.close()

        window = show(.about, model: model)
        spin(0.3)
        window.close()

        XCTAssertNotNil(model.settings)
    }

    func testAnOpenSettingsWindowSwitchesToTheRequestedPane() async {
        let model = await model()
        let window = show(.general, model: model)
        defer { window.close() }
        spin(0.3)

        model.requestSettingsPane(.folders)
        spin(0.4)

        XCTAssertNil(model.takeRequestedSettingsPane(), "the open window should have consumed the request")
    }

    func testANewSettingsWindowOpensOnTheRequestedPane() async {
        let model = await model()
        model.requestSettingsPane(.safety)

        let window = show(.general, model: model)
        defer { window.close() }
        spin(0.4)

        XCTAssertNil(model.takeRequestedSettingsPane())
    }
}

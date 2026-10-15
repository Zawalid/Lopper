import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Puts the real window content in a real NSWindow (toolbar, inspector, sheet and all) and drives the
/// state changes a person triggers with clicks. Offscreen renders cannot catch environment or toolbar
/// problems because they never create the AppKit hosting views.
@MainActor
final class WindowSmokeTests: XCTestCase {
    /// Spins the main run loop so SwiftUI and AppKit lay out and update, like they do between clicks.
    /// Synchronous on purpose: `RunLoop.run` is unavailable from async contexts.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pump(_ seconds: TimeInterval = 0.35) async {
        spin(seconds)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: RootView().environment(model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func readyModel() async -> AppModel {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        XCTAssertEqual(model.overviewState, .ready)
        return model
    }

    func testOpeningARepositoryDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        model.route = .repo(Fixtures.root.path)
        await pump()
        XCTAssertNotNil(window.contentViewController)
    }

    /// Every column of the split views (sidebar, table, inspector) must lie inside the window. SwiftUI's own
    /// minimum size does not catch this: a table whose columns ask for more than the space left makes the
    /// split view overflow, and the sidebar and inspector end up clipped by the window edge.
    private func assertPanesInsideWindow(_ window: NSWindow, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let content = window.contentView else { return XCTFail("no content view", file: file, line: line) }
        var splitViews: [NSSplitView] = []
        func collect(_ view: NSView) {
            if let split = view as? NSSplitView { splitViews.append(split) }
            view.subviews.forEach(collect)
        }
        collect(content)
        XCTAssertFalse(splitViews.isEmpty, "expected the navigation split view (\(label))", file: file, line: line)

        for split in splitViews {
            let frame = split.convert(split.bounds, to: content)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(label): split view starts left of the window", file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 0.5,
                "\(label): split view is \(frame.width) wide in a window \(content.bounds.width) wide", file: file, line: line)
            for pane in split.arrangedSubviews where !split.isSubviewCollapsed(pane) {
                let paneFrame = split.convert(pane.frame, to: content)
                XCTAssertGreaterThanOrEqual(paneFrame.minX, -0.5, "\(label): a pane is clipped on the left: \(paneFrame)", file: file, line: line)
                XCTAssertLessThanOrEqual(paneFrame.maxX, content.bounds.width + 0.5,
                    "\(label): a pane is clipped on the right: \(paneFrame) in a window \(content.bounds.width) wide", file: file, line: line)
            }
        }
    }

    func testRepositoryWorkbenchStaysInsideTheWindow() async {
        let model = await readyModel()
        model.showInspector = true
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump(0.8)
        assertPanesInsideWindow(window, "default size")
    }

    /// People drag the window edge. Every width on the way, wider and narrower, must keep the panes inside.
    func testPanesStayInsideTheWindowWhileItIsResized() async {
        let model = await readyModel()
        model.showInspector = true
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump(0.6)

        let minimum = window.contentMinSize.width
        for width in [1400, 1200, 1000, minimum + 40, minimum, 1100, 1080] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 700))
            await pump(0.4)
            assertPanesInsideWindow(window, "resized to \(width)")
        }
    }

    func testSwitchingTheSidebarGroupingDoesNotCrashAndStaysInsideTheWindow() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        for grouping in SidebarGrouping.allCases + [.attention] {
            model.preferences.setSidebarGrouping(grouping)
            await pump(0.4)
            assertPanesInsideWindow(window, "grouping \(grouping.rawValue)")
        }
    }

    func testSidebarDetailsSortAndTidyOptionsDoNotCrashAndStayInsideTheWindow() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        for sort in SidebarSort.allCases {
            model.preferences.setSidebarSort(sort)
            model.preferences.setSidebarShowsDetails(sort != .name)
            model.preferences.setSidebarShowsTidy(sort != .size)
            await pump(0.3)
            assertPanesInsideWindow(window, "sort \(sort.rawValue)")
        }
        model.preferences.resetSidebarOptions()
        await pump(0.3)
        assertPanesInsideWindow(window, "after reset")
    }

    func testHidingTheOpenRepositoryReturnsToTheOverviewWithoutCrashing() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump()

        model.hideRepository(Fixtures.root)
        await pump(0.6)

        XCTAssertNotNil(window.contentViewController)
    }

    func testChangingTheVerdictFilterDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump()

        for filter in VerdictFilter.allCases {
            model.verdictFilter = filter
            await pump(0.15)
        }
        XCTAssertNotNil(window.contentViewController)
    }

    func testChangingTheKindFilterDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump()

        for kind in KindFilter.allCases {
            model.kindFilter = kind
            await pump(0.15)
        }
        XCTAssertNotNil(window.contentViewController)
    }

    func testFocusingARowAndTogglingTheInspectorDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump()

        model.focusedRowID = "worktree:/code/wt/feat/in-worktree"
        await pump()
        model.showInspector.toggle()
        await pump()
        model.showInspector.toggle()
        await pump()
        XCTAssertNotNil(window.contentViewController)
    }

    func testCheckingRowsAndSelectingAllSafeDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        model.route = .repo(Fixtures.root.path)
        await pump()

        model.checked.insert("branch:/code/api#feat/old-1")
        await pump(0.2)
        model.checkAllSafe(inRepo: Fixtures.root.path)
        await pump(0.2)
        model.clearChecked()
        await pump(0.2)
        model.searchText = "old"
        await pump(0.2)
        model.searchText = ""
        await pump(0.2)
        XCTAssertNotNil(window.contentViewController)
    }

    func testSwitchingToHistoryAndBackDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        model.route = .history
        await pump()
        model.route = .overview
        await pump()
        XCTAssertNotNil(window.contentViewController)
    }

    func testOpeningTheCleanSheetAndTheToastDoesNotCrash() async {
        let model = await readyModel()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        model.beginCleanAllSafe()
        await pump(0.5)
        model.runClean()
        await pump(0.8)
        model.finishClean()
        await pump(0.5)
        XCTAssertNotNil(window.contentViewController)
    }
}

import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// The same clicks a person makes, with the real window on screen.
@MainActor
final class AgentsWindowSmokeTests: XCTestCase {
    /// Synchronous on purpose: `RunLoop.run` is unavailable from async contexts.
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func pump(_ seconds: TimeInterval = 0.4) async {
        spin(seconds)
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: RootView().environment(model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1080, height: 700))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func model() -> AppModel {
        let m = Fixtures.agentMeasurements
        return AppModel.preview(
            snapshots: [Fixtures.agentSample], sizes: m.sizes, activity: m.activity,
            route: .agents, clock: { Fixtures.now })
    }

    func testAgentsPageOpensWithEveryStateWithoutCrashing() async {
        let model = model()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump(0.8)
        XCTAssertEqual(model.route, .agents)
        XCTAssertEqual(model.agentsPageState, .ready)
        XCTAssertNotNil(window.contentViewController)
    }

    func testReclaimFinishedOpensTheSheetWithOnlyFinishedRowsAndUndoIsOffered() async {
        let model = model()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        model.beginReclaimFinishedAgents()
        await pump(0.5)
        XCTAssertEqual(model.clean?.rows.count, 2)
        XCTAssertTrue(model.clean?.rows.allSatisfy { $0.agent?.state == .finished } == true)

        model.runClean()
        for _ in 0..<100 where model.clean?.phase != .finished {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(model.clean?.phase, .finished)
        XCTAssertNotNil(model.toast, "an undo toast must be offered after a clean")
    }

    func testNotMergedWorkNeverReachesTheSheetFromTheBulkButtons() async {
        let model = model()
        let window = makeWindow(model: model)
        defer { window.close() }
        await pump()

        model.beginReclaimFinishedAgents()
        let included = model.clean?.rows.map(\.title) ?? []
        XCTAssertFalse(included.contains("claude/wip"))
        XCTAssertFalse(included.contains("claude/scratch"))
        XCTAssertFalse(included.contains("claude/just-now"))
    }

    func testPanesStayInsideTheWindowOnTheAgentsPage() async {
        let model = model()
        model.showInspector = true
        let window = makeWindow(model: model)
        defer { window.close() }
        for width in [1040.0, 1200.0, 1440.0] {
            window.setContentSize(NSSize(width: width, height: 700))
            await pump(0.5)
            guard let content = window.contentView else { return XCTFail("no content view") }
            var splits: [NSSplitView] = []
            func collect(_ view: NSView) {
                if let split = view as? NSSplitView { splits.append(split) }
                view.subviews.forEach(collect)
            }
            collect(content)
            for split in splits {
                let frame = split.convert(split.bounds, to: content)
                XCTAssertLessThanOrEqual(frame.maxX, content.bounds.width + 0.5, "width \(width)")
                XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "width \(width)")
            }
        }
    }
}

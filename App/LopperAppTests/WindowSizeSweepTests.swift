import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Every page, at the smallest size the window allows and at several larger ones: panes must stay inside the
/// window, the declared minimum must not grow past what the window promises, and nothing may crash while the
/// window is being dragged between sizes.
@MainActor
final class WindowSizeSweepTests: XCTestCase {
    private static let promisedMinimum = NSSize(width: 1040, height: 520)

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let controller = NSHostingController(rootView: RootView().environment(model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func assertPanesInside(_ window: NSWindow, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let content = window.contentView else { return XCTFail("no content view", file: file, line: line) }
        var splits: [NSSplitView] = []
        func collect(_ view: NSView) {
            if let split = view as? NSSplitView { splits.append(split) }
            view.subviews.forEach(collect)
        }
        collect(content)
        XCTAssertFalse(splits.isEmpty, "\(label): no split view", file: file, line: line)
        for split in splits {
            let frame = split.convert(split.bounds, to: content)
            XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(label): starts left of the window", file: file, line: line)
            XCTAssertLessThanOrEqual(
                frame.maxX, content.bounds.width + 0.5,
                "\(label): \(frame.width) wide in a window \(content.bounds.width) wide", file: file, line: line)
            for pane in split.arrangedSubviews where !split.isSubviewCollapsed(pane) {
                let paneFrame = split.convert(pane.frame, to: content)
                XCTAssertGreaterThanOrEqual(paneFrame.minX, -0.5, "\(label): pane clipped left \(paneFrame)", file: file, line: line)
                XCTAssertLessThanOrEqual(
                    paneFrame.maxX, content.bounds.width + 0.5,
                    "\(label): pane clipped right \(paneFrame) in \(content.bounds.width)", file: file, line: line)
            }
        }
    }

    private var routes: [(String, Route)] {
        [
            ("overview", .overview),
            ("agents", .agents),
            ("disk", .disk),
            ("history", .history),
            ("repository", .repo(Fixtures.root.path)),
        ]
    }

    func testEveryPageKeepsItsPromisedMinimumSize() {
        let model = AppModel.preview(history: Fixtures.historyRecords, route: .overview)
        model.showInspector = true
        let window = makeWindow(model: model)
        defer { window.close() }

        for (name, route) in routes {
            model.route = route
            spin(0.5)
            XCTAssertLessThanOrEqual(
                window.contentMinSize.width, Self.promisedMinimum.width,
                "\(name) needs \(window.contentMinSize.width) points of width")
            XCTAssertLessThanOrEqual(
                window.contentMinSize.height, Self.promisedMinimum.height,
                "\(name) needs \(window.contentMinSize.height) points of height")
        }
    }

    func testEveryPageStaysInsideTheWindowAtEverySize() {
        let model = AppModel.preview(history: Fixtures.historyRecords, route: .overview)
        model.showInspector = true
        let window = makeWindow(model: model)
        defer { window.close() }

        let sizes: [NSSize] = [
            Self.promisedMinimum,
            NSSize(width: 1100, height: 640),
            NSSize(width: 1280, height: 800),
            NSSize(width: 1600, height: 1000),
            NSSize(width: 2200, height: 1300),
            Self.promisedMinimum,   // back down again, as when a window is dragged smaller
        ]
        for (name, route) in routes {
            model.route = route
            for size in sizes {
                window.setContentSize(size)
                spin(0.35)
                assertPanesInside(window, "\(name) at \(Int(size.width))x\(Int(size.height))")
            }
        }
    }

    func testTheRepositoryPageSurvivesTheInspectorOpeningAndClosingAtTheSmallestSize() {
        let model = AppModel.preview(route: .repo(Fixtures.root.path))
        let window = makeWindow(model: model)
        defer { window.close() }
        window.setContentSize(Self.promisedMinimum)

        for visible in [true, false, true] {
            model.showInspector = visible
            spin(0.4)
            assertPanesInside(window, "repository, inspector \(visible ? "open" : "closed")")
        }
    }

    // MARK: Background

    /// Reads one pixel of the real window, in sRGB, as (red, green, blue) from 0 to 1.
    private func pixel(in window: NSWindow, atFractionX x: Double, y: Double) -> (Double, Double, Double)? {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let px = Int(Double(rep.pixelsWide) * x), py = Int(Double(rep.pixelsHigh) * y)
        guard let color = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { return nil }
        return (Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent))
    }

    func testAnEmptyPageFillsTheWholeDetailWithThePageColor() {
        // History with nothing in it is an empty state that hugs its text; the color behind it must still
        // cover the whole page and not just a rectangle around the text.
        let model = AppModel.preview(snapshots: [], history: [], route: .history)
        let window = makeWindow(model: model)
        defer { window.close() }
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(Self.promisedMinimum)
        spin(0.8)

        // Two spots far from the centred text, both inside the detail column. Before the fix the first read the
        // window behind the page (black or white) and only a rectangle around the text had the page color.
        guard let topRight = pixel(in: window, atFractionX: 0.75, y: 0.12),
              let bottomRight = pixel(in: window, atFractionX: 0.9, y: 0.85) else { return XCTFail("no pixel") }
        for (name, color) in [("top right", topRight), ("bottom right", bottomRight)] {
            XCTAssertEqual(color.0, color.1, accuracy: 0.03, "\(name) is not a near-neutral gray")
            XCTAssertEqual(color.1, color.2, accuracy: 0.03, "\(name) is not a near-neutral gray")
            XCTAssertGreaterThan(color.0, 0.1, "\(name) is too dark to be the page: \(color.0)")
            XCTAssertLessThan(color.0, 0.3, "\(name) is too light to be the dark page: \(color.0)")
        }
        XCTAssertEqual(topRight.0, bottomRight.0, accuracy: 0.01, "the page color is not uniform")
    }
}

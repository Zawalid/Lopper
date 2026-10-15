import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Writes PNGs of the real window for every page at the minimum size, in both appearances, so a person can
/// look at them. Only runs when `LOPPER_SNAPSHOT_DIR` is set (pass it as `TEST_RUNNER_LOPPER_SNAPSHOT_DIR`
/// to xcodebuild); otherwise it is skipped and costs nothing.
@MainActor
final class WindowSnapshotTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testWriteSnapshotsOfEveryPageAtTheMinimumSize() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let reviewSnapshot = Fixtures.snapshot(branches: [
            Fixtures.branch("feat/landing-refresh", .safe), Fixtures.branch("staging", .safe),
            Fixtures.branch("feat/paper-restyle", .review, ageDays: 36),
            Fixtures.branch("fix/tools-urgent", .review, ageDays: 11),
            Fixtures.branch("main", .protected),
        ], worktrees: [Fixtures.worktree("feat/in-worktree", .safe)])
        let model = AppModel.preview(
            snapshots: [reviewSnapshot], history: Fixtures.historyRecords, route: .overview)
        model.showInspector = true

        let controller = NSHostingController(rootView: RootView().environment(model))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1040, height: 560))
        window.makeKeyAndOrderFront(nil)

        let routes: [(String, Route)] = [
            ("overview", .overview), ("agents", .agents), ("disk", .disk), ("history", .history),
            ("repository", .repo(Fixtures.root.path)),
        ]
        for appearance in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance.1)
            for (name, route) in routes {
                model.route = route
                if case .repo = route {
                    model.focusedRowID = model.allRows.first { $0.verdict == .review }?.id
                } else {
                    model.focusedRowID = nil
                }
                spin(0.7)
                guard let view = window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "\(directory)/\(name)-\(appearance.0).png"))
                }
            }
        }
        window.close()
    }
}

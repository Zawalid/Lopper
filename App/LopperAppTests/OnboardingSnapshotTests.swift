import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Writes PNGs of each onboarding step in both appearances. Only runs when `LOPPER_SNAPSHOT_DIR` is set.
@MainActor
final class OnboardingSnapshotTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testWriteOnboardingSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let steps: [(String, OnboardingModel.Step, Bool)] = [
            ("onboarding-welcome", .welcome, false), ("onboarding-choose", .choose, false),
            ("onboarding-scan", .scan, true),
        ]
        for appearance in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for (name, step, hasRoots) in steps {
                let model = AppModel.preview(
                    roots: hasRoots ? [URL(fileURLWithPath: "/code")] : [], clock: { Fixtures.now })
                model.restartOnboarding()
                let controller = NSHostingController(
                    rootView: OnboardingView(startingAt: step).environment(model))
                let window = NSWindow(contentViewController: controller)
                window.setContentSize(NSSize(width: 1040, height: 640))
                window.appearance = NSAppearance(named: appearance.1)
                window.makeKeyAndOrderFront(nil)
                spin(1.2)
                if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        try data.write(to: URL(fileURLWithPath: "\(directory)/\(name)-\(appearance.0).png"))
                    }
                }
                window.close()
            }
        }
    }
}

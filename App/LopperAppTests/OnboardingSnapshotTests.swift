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

    func testWriteWelcomeAnimationFrames() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let cut = SceneTimeline.cutTimes
        let frames: [(String, Double)] = [
            ("a-growing", 1.6), ("b-labels", 3.4), ("c-scissors", cut[0] - 0.4), ("d-first-cut", cut[0] + 0.15),
            ("e-embers", cut[0] + 0.7), ("f-midway", cut[2] + 0.3), ("g-last-cut", cut[5] + 0.2),
            ("h-lighter", cut[5] + 1.6), ("i-final", SceneTimeline.stillFrame),
        ]
        for (name, time) in frames {
            let model = AppModel.preview(roots: [], clock: { Fixtures.now })
            model.restartOnboarding()
            let controller = NSHostingController(rootView: OnboardingView(sceneTime: time).environment(model))
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(NSSize(width: 1040, height: 640))
            window.makeKeyAndOrderFront(nil)
            spin(0.5)
            if let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try data.write(to: URL(fileURLWithPath: "\(directory)/scene-\(name).png"))
                }
            }
            window.close()
        }
    }

    func testWriteOnboardingSnapshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["LOPPER_SNAPSHOT_DIR"] else {
            throw XCTSkip("set LOPPER_SNAPSHOT_DIR to write snapshots")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let steps: [(String, OnboardingModel.Step, Bool)] = [
            ("onboarding-welcome", .welcome, false), ("onboarding-choose", .choose, false),
            ("onboarding-choose-empty", .choose, false), ("onboarding-scanning", .scan, true),
            ("onboarding-scan", .scan, true),
        ]
        for appearance in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            for (name, step, hasRoots) in steps {
                // Enough repositories for the first-scan picture to look like something.
                let many = (0..<28).map { index in
                    Fixtures.snapshot(
                        name: "repo-\(index)", root: URL(fileURLWithPath: "/code/repo-\(index)"),
                        branches: (0..<(index % 5)).map { Fixtures.branch("feat/b\($0)", .safe) } + [Fixtures.branch("main", .protected)])
                }
                let model = AppModel.preview(
                    snapshots: hasRoots ? many : [Fixtures.sample],
                    roots: hasRoots ? [URL(fileURLWithPath: "/code")] : [],
                    phase: name == "onboarding-scanning" ? .scanning(done: 29, total: 61) : nil,
                    suggestions: name == "onboarding-choose-empty" ? [] : Fixtures.folderSuggestions,
                    clock: { Fixtures.now })
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

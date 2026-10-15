import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class OverviewRenderTests: XCTestCase {
    func testOverviewRenders() async throws {
        let appsRoot = URL(fileURLWithPath: "/code/apps")
        let second = Fixtures.snapshot(
            name: "apps", root: appsRoot,
            branches: [Fixtures.branch("main", .protected, root: appsRoot),
                       Fixtures.branch("feat/ui", .safe, root: appsRoot)])
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample, second])

        try RenderSupport.render("overview", size: CGSize(width: 820, height: 560),
                                 OverviewContent().environment(model))
    }

    func testOverviewShowsAllTidyWhenNothingIsSafe() async throws {
        let only = Fixtures.snapshot(branches: [Fixtures.branch("main", .protected)])
        let model = await RenderSupport.makeModel(snapshots: [only])

        XCTAssertEqual(model.totals.safe, 0)
        try RenderSupport.render("overview-tidy", size: CGSize(width: 820, height: 420),
                                 OverviewContent().environment(model))
    }

    func testOnboardingRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [], roots: [])
        try RenderSupport.render("onboarding", size: CGSize(width: 720, height: 520),
                                 OnboardingView().environment(model))
    }

    func testToastAndChipsRender() throws {
        try RenderSupport.render(
            "toast", size: CGSize(width: 420, height: 80),
            UndoToastView(toast: UndoToast(id: UUID(), removed: 12, reclaimed: 1_240_000_000),
                          onUndo: {}, onDismiss: {}))
        try RenderSupport.render(
            "chips", size: CGSize(width: 360, height: 60),
            HStack { VerdictChip(kind: .safe); VerdictChip(kind: .review); VerdictChip(kind: .protected) }
                .padding())
    }
}

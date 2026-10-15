import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class SheetAndMenuRenderTests: XCTestCase {
    func testCleanReviewRowsRender() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        model.beginCleanAllSafe()
        let rows = model.clean?.rows ?? []
        XCTAssertEqual(rows.count, 4)

        // The sheet's List cannot be drawn offscreen, so its rows are laid out in a plain stack.
        try RenderSupport.render(
            "clean-rows", size: CGSize(width: 560, height: 300),
            VStack(spacing: 10) { ForEach(rows) { ReviewRow(row: $0, isIncluded: true) } }
                .padding(16)
                .environment(model))
    }

    func testMenuBarPopoverRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        try RenderSupport.render("menubar", size: CGSize(width: 300, height: 300),
                                 MenuBarView().environment(model))
    }
}

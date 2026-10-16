import XCTest
import SwiftUI
import Lopper
@testable import LopperApp

@MainActor
final class DiagnosticsRenderTests: XCTestCase {
    func testTheReportTextRenders() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        await model.refreshToolStatus()
        let report = await model.diagnosticsReport(includeNames: false)
        XCTAssertTrue(report.contains("Lopper diagnostics"))
        try RenderSupport.render("diagnostics", size: CGSize(width: 520, height: 420), DiagnosticsText(report: report).padding())
    }
}

import XCTest
import AppKit
import Lopper
@testable import LopperApp

@MainActor
final class BrandIconsTests: XCTestCase {
    func testEveryAgentToolHasCandidateAppsAndAFallbackSymbol() {
        for tool in AgentTool.allCases {
            XCTAssertFalse(BrandIcons.bundleIDs(for: tool).isEmpty, tool.label)
            XCTAssertFalse(BrandIcons.fallbackSymbol(for: tool).isEmpty, tool.label)
        }
    }

    func testClaudeCodeUsesTheClaudeDesktopAppIcon() {
        XCTAssertEqual(BrandIcons.bundleIDs(for: .claudeCode).first, "com.anthropic.claudefordesktop")
    }

    func testFirstInstalledCandidateWins() {
        let installed: Set<String> = ["b", "c"]
        XCTAssertEqual(BrandIcons.firstInstalled(["a", "b", "c"], isInstalled: { installed.contains($0) }), "b")
        XCTAssertNil(BrandIcons.firstInstalled(["a"], isInstalled: { _ in false }))
        XCTAssertNil(BrandIcons.firstInstalled([], isInstalled: { _ in true }))
    }

    func testTheGitHubMarkRendersAsATemplateImage() throws {
        let mark = try XCTUnwrap(BrandIcons.githubMark)
        XCTAssertTrue(mark.isValid)
        XCTAssertTrue(mark.isTemplate, "a template follows the text color in light and dark mode")
        XCTAssertGreaterThan(mark.size.width, 0)
    }

    func testTheGitHubMarkActuallyDrawsSomething() throws {
        let mark = try XCTUnwrap(BrandIcons.githubMark)
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        mark.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()

        var filled = 0
        for y in 0..<32 { for x in 0..<32 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { filled += 1 } }
        XCTAssertGreaterThan(filled, 200, "an empty or broken SVG would leave the canvas blank")
    }
}

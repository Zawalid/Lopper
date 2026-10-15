import XCTest
import AppKit
import SwiftUI
@testable import LopperApp

final class ThemeTests: XCTestCase {
    private func resolved(_ color: NSColor, in name: NSAppearance.Name) -> NSColor {
        var result = color
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    func testPageBackgroundIsASolidOpaqueColorInBothAppearances() {
        for name in [NSAppearance.Name.darkAqua, .aqua] {
            let color = resolved(Theme.pageBackgroundNS, in: name)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001, "\(name.rawValue) must not be translucent")
        }
    }

    func testPageBackgroundInDarkModeIsAFixedDarkGrayAndNotTheSystemTint() {
        let color = resolved(Theme.pageBackgroundNS, in: .darkAqua)
        XCTAssertEqual(color.redComponent, 0.15, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.15, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.15, accuracy: 0.01)
    }

    func testCardsStayDistinctFromThePageInDarkMode() {
        let page = resolved(Theme.pageBackgroundNS, in: .darkAqua)
        let card = resolved(.controlBackgroundColor, in: .darkAqua)
        XCTAssertGreaterThan(page.redComponent - card.redComponent, 0.02, "cards must read darker than the page")
    }
}

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

    func testPageBackgroundInDarkModeIsAFixedTintedDarkAndNotTheSystemTint() {
        let color = resolved(Theme.pageBackgroundNS, in: .darkAqua)
        XCTAssertEqual(color.redComponent, 0.118, accuracy: 0.01)
        XCTAssertEqual(color.greenComponent, 0.131, accuracy: 0.01)
        XCTAssertEqual(color.blueComponent, 0.126, accuracy: 0.01)
    }

    func testCardsStayDistinctFromThePageInDarkMode() {
        let page = resolved(Theme.pageBackgroundNS, in: .darkAqua)
        let card = resolved(Theme.cardBackgroundNS, in: .darkAqua)
        XCTAssertGreaterThan(card.redComponent - page.redComponent, 0.02, "cards must read lighter than the page")
    }
}

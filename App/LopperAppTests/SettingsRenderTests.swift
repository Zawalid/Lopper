import XCTest
import SwiftUI
@testable import LopperApp

@MainActor
final class SettingsRenderTests: XCTestCase {
    func testTagChipsAndTheAboutPaneRender() async throws {
        let model = await RenderSupport.makeModel(snapshots: [Fixtures.sample])
        try RenderSupport.render(
            "tag-chips", size: CGSize(width: 520, height: 120),
            FlowLayout(spacing: 6) {
                ForEach(["main", "master", "develop", "release/*", "hotfix/*", "staging", "legacy-one"], id: \.self) {
                    TagChip(title: $0, onRemove: {})
                }
            }
            .padding(16))
        try RenderSupport.render(
            "settings-about", size: CGSize(width: 560, height: 360),
            AboutPane().environment(model))
    }
}

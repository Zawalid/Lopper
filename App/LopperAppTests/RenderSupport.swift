import XCTest
import SwiftUI
import AppKit
import Lopper
@testable import LopperApp

/// Renders screens offscreen to PNG so the visual design can be reviewed without a display session.
/// The output directory comes from TEST_RUNNER_LOPPER_RENDER_DIR; without it the tests only check that
/// rendering works. Scroll views, lists and tables cannot be drawn offscreen, so tests render each
/// screen's content view, not its scrolling shell.
@MainActor
enum RenderSupport {
    static func makeModel(snapshots: [RepoSnapshot], roots: [URL] = [URL(fileURLWithPath: "/code")]) async -> AppModel {
        let client = FakeEngineClient(snapshots: snapshots)
        client.sizeByPath = ["/code/wt/feat/in-worktree": 1_240_000_000]
        let store = SettingsStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-render-\(UUID().uuidString).json"))
        let model = AppModel(client: client, store: store, settings: Settings(roots: roots))
        if !roots.isEmpty {
            model.startScan()
            for _ in 0..<200 {
                if case .ready = model.phase { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return model
    }

    static func render<V: View>(
        _ name: String, size: CGSize, _ view: V, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        for scheme in [ColorScheme.light, .dark] {
            let framed = view
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "\(name) did not render", file: file, line: line)
            XCTAssertGreaterThan(image.size.width, 0, file: file, line: line)
            guard let dir = ProcessInfo.processInfo.environment["LOPPER_RENDER_DIR"] else { continue }
            let tiff = try XCTUnwrap(image.tiffRepresentation, file: file, line: line)
            let rep = try XCTUnwrap(NSBitmapImageRep(data: tiff), file: file, line: line)
            let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]), file: file, line: line)
            let url = URL(fileURLWithPath: dir)
                .appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
            try png.write(to: url)
        }
    }
}

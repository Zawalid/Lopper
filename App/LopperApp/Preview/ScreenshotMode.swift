#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: when `LOPPER_SCREENSHOT_DIR` is set, the running app walks through its pages in both appearances,
/// writes a PNG of its own window for each, and quits. It captures the real window, with the real sidebar and
/// inspector, from inside the process, so it needs no screen recording permission.
///
///     LOPPER_SUPPORT_DIR=<world>-support LOPPER_SCREENSHOT_DIR=docs/images <binary>
@MainActor
enum ScreenshotMode {
    private struct Shot {
        let name: String
        let prepare: @MainActor (AppModel) -> Void
    }

    private static let shots: [Shot] = [
        Shot(name: "overview") { $0.route = .overview },
        Shot(name: "repository") { model in
            guard let repo = model.snapshots.first(where: { $0.repo.name == "web" }) ?? model.snapshots.first else { return }
            model.route = .repo(repo.repo.id)
            model.focusedRowID = model.rows(forRepo: repo.repo.id).first { $0.verdict == .safe }?.id
        },
        Shot(name: "agents") { model in
            model.route = .agents
            model.focusedRowID = model.agentRows.first { $0.row.title.contains("tidy") }?.id ?? model.agentRows.first?.id
        },
        Shot(name: "disk") { model in
            model.route = .disk
            model.diskGrouping = .project
        },
        Shot(name: "disk-map") { model in
            model.route = .disk
            model.diskGrouping = .map
        },
        Shot(name: "history") { $0.route = .history },
    ]

    static func runIfRequested(model: AppModel) async {
        guard let path = ProcessInfo.processInfo.environment["LOPPER_SCREENSHOT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Wait for the scan and the size measurements so the numbers on the pages are the real ones.
        for _ in 0..<180 {
            if model.overviewState == .ready, case .ready = model.artifactPhase { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
            NSApp.terminate(nil)
            return
        }
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try? await Task.sleep(for: .seconds(3))

        for (appearanceName, suffix) in [(NSAppearance.Name.darkAqua, "dark"), (.aqua, "light")] {
            NSApp.appearance = NSAppearance(named: appearanceName)
            for shot in shots {
                model.focusedRowID = nil
                shot.prepare(model)
                try? await Task.sleep(for: .seconds(2.5))
                if let data = capture(window) {
                    try? data.write(to: directory.appendingPathComponent("\(shot.name)-\(suffix).png"))
                }
            }
        }
        NSApp.terminate(nil)
    }

    /// `CGWindowListCreateImage` is marked unavailable in the current SDK but still ships in the system, and it
    /// can always read this process's own windows. It is looked up by name so the SDK marking does not matter.
    private static func capture(_ window: NSWindow) -> Data? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        guard let image = create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}
#endif

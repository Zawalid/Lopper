#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: a scripted walk through the app for the promo footage. With `LOPPER_DEMO_TOUR` set (and
/// `LOPPER_CAPTURE_DIR` naming an output folder) the app performs one shot after another and photographs its own
/// window continuously, sheets included, as JPEG files, logging each frame's time and each shot's start and end.
/// It reads only its own windows, so no other app can ever end up in the footage and no permission is needed.
@MainActor
enum DemoTour {
    private final class PendingCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func add(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
    }

    private struct Event: Codable { let name: String; let start: Double; let end: Double }
    private struct FrameTime: Codable { let i: Int; let t: Double }
    private static var events: [Event] = []
    private static var frames: [FrameTime] = []
    private static var base = CACurrentMediaTime()
    private static var outputDirectory = URL(fileURLWithPath: "/tmp")
    private static var capturing = false
    private static weak var tourWindow: NSWindow?

    static func runIfRequested(model: AppModel) async {
        guard ProcessInfo.processInfo.environment["LOPPER_DEMO_TOUR"] != nil,
              let path = ProcessInfo.processInfo.environment["LOPPER_CAPTURE_DIR"] else { return }
        outputDirectory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        for _ in 0..<240 {
            if model.overviewState == .ready, case .ready = model.artifactPhase { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .seconds(3))

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }) else {
            NSApp.terminate(nil)
            return
        }
        NSApp.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(NSSize(width: 1280, height: 800))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // The footage is about reclaiming space; the "only on this Mac" banner would sit on top of every overview shot.
        model.debugHideLocalOnly(true)
        model.route = .overview
        try? await Task.sleep(for: .seconds(2))

        tourWindow = window
        base = CACurrentMediaTime()
        capturing = true
        let loop = Task { await captureLoop(window) }

        await tour(model)
        capturing = false
        await loop.value
        save()
        NSApp.terminate(nil)
    }

    // MARK: Capture

    private static func captureLoop(_ window: NSWindow) async {
        let pending = PendingCount()
        var index = 0
        var lastKeyCheck = CACurrentMediaTime()
        while capturing {
            // A sheet closing or another app stealing focus leaves the window looking inactive (grey traffic
            // lights and sidebar selection); take focus back whenever nothing is presented over it.
            if CACurrentMediaTime() - lastKeyCheck > 0.3 {
                lastKeyCheck = CACurrentMediaTime()
                if window.sheets.isEmpty, !window.isKeyWindow || !NSApp.isActive {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
            }
            if pending.value >= 40 {
                try? await Task.sleep(for: .milliseconds(5))
                continue
            }
            if let image = composite(window) {
                let name = String(format: "f%06d.jpg", index)
                frames.append(FrameTime(i: index, t: CACurrentMediaTime() - base))
                let url = outputDirectory.appendingPathComponent(name)
                pending.add(1)
                DispatchQueue.global(qos: .userInitiated).async {
                    if let data = NSBitmapImageRep(cgImage: image)
                        .representation(using: .jpeg, properties: [.compressionFactor: 0.92]) {
                        try? data.write(to: url)
                    }
                    pending.add(-1)
                }
                index += 1
            }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    /// The window plus its sheets, drawn together at the window's pixel size.
    private static func composite(_ window: NSWindow) -> CGImage? {
        guard let main = capture(window) else { return nil }
        let scale = Double(main.width) / window.frame.width
        guard let context = CGContext(
            data: nil, width: main.width, height: main.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return main }
        context.setFillColor(CGColor(red: 0.043, green: 0.063, blue: 0.057, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: main.width, height: main.height))
        context.draw(main, in: CGRect(x: 0, y: 0, width: main.width, height: main.height))
        for sheet in window.sheets + (window.childWindows ?? []) where sheet.isVisible {
            guard let image = capture(sheet) else { continue }
            let rect = CGRect(
                x: (sheet.frame.minX - window.frame.minX) * scale, y: (sheet.frame.minY - window.frame.minY) * scale,
                width: Double(image.width), height: Double(image.height))
            context.draw(image, in: rect)
        }
        return context.makeImage()
    }

    /// `CGWindowListCreateImage` is unavailable in the current SDK but still ships; it is looked up by name and
    /// only ever asked for this process's own windows.
    private static func capture(_ window: NSWindow) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return create(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue()
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func save() {
        if let data = try? JSONEncoder().encode(events) {
            try? data.write(to: outputDirectory.appendingPathComponent("events.json"))
        }
        if let data = try? JSONEncoder().encode(frames) {
            try? data.write(to: outputDirectory.appendingPathComponent("frames.json"))
        }
    }

    /// Runs a shot with a short hold before and after, and logs the time of the shot itself.
    private static func shot(_ name: String, lead: Double = 0.8, tail: Double = 0.8, _ body: () async -> Void) async {
        await pause(lead)
        if tourWindow?.sheets.isEmpty ?? true {
            NSApp.activate(ignoringOtherApps: true)
            tourWindow?.makeKeyAndOrderFront(nil)
        }
        let start = CACurrentMediaTime() - base
        await body()
        let end = CACurrentMediaTime() - base
        events.append(Event(name: name, start: start, end: end))
        await pause(tail)
    }

    private static func tour(_ model: AppModel) async {
        // Overview arrives: leave and come back so the where-it-is bars grow in on camera.
        model.route = .disk
        await pause(1.0)
        await shot("overview") {
            model.route = .overview
            await pause(5)
        }

        // A repository: step through the rows so the inspector changes verdict.
        await shot("repository") {
            model.focusedRowID = nil
            if let repo = model.snapshots.first(where: { $0.repo.name == "web" }) ?? model.snapshots.first {
                model.route = .repo(repo.repo.id)
                await pause(1.2)
                model.focusedRowID = model.rows(forRepo: repo.repo.id).first { $0.verdict == .safe }?.id
                await pause(1.6)
                for _ in 0..<4 {
                    model.focusNextRow()
                    await pause(1.0)
                }
            }
        }

        // Agents: the table, then three rows.
        await shot("agents") {
            model.focusedRowID = nil
            model.route = .agents
            await pause(1.5)
            model.focusedRowID = model.agentRows.first?.id
            await pause(1.5)
            for _ in 0..<3 {
                model.focusNextRow()
                await pause(1.0)
            }
        }

        // Disk: by project, by kind, then the map.
        await shot("disk") {
            model.focusedRowID = nil
            model.route = .disk
            model.diskGrouping = .project
            await pause(2)
            model.diskGrouping = .kind
            await pause(2)
            model.diskGrouping = .map
            await pause(3.5)
        }

        // History, before the clean below adds its own entries.
        await shot("history") {
            model.route = .history
            await pause(4)
        }

        // Review and clean: the sheet, the run, the toast, the undo.
        model.route = .overview
        await pause(1.5)
        await shot("clean-review", lead: 0.6) {
            model.beginCleanAllSafe()
            await pause(4)
        }
        await shot("clean-run", lead: 0.2, tail: 0.2) {
            model.runClean()
            for _ in 0..<240 {
                if model.clean?.phase == .finished { break }
                await pause(0.25)
            }
        }
        await shot("clean-done", lead: 0.2) {
            await pause(2.5)
        }
        await shot("clean-toast", lead: 0.2) {
            model.finishClean()
            await pause(3)
            if model.toast != nil {
                model.undoToast()
                await pause(3.5)
            }
        }
        await pause(1)
    }
}
#endif

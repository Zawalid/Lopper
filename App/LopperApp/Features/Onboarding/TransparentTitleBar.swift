import AppKit
import SwiftUI

/// Lets the picture run up under the title bar: the bar turns transparent and its title disappears while this
/// view is on screen, and the window goes back exactly as it was afterwards.
struct TransparentTitleBar: NSViewRepresentable {
    final class Coordinator {
        weak var window: NSWindow?
        var wasTransparent = false
        var previousTitleVisibility = NSWindow.TitleVisibility.visible
        var hadFullSizeContent = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in apply(view?.window, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(view.window, context.coordinator)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let window = coordinator.window else { return }
        window.titlebarAppearsTransparent = coordinator.wasTransparent
        window.titleVisibility = coordinator.previousTitleVisibility
        if !coordinator.hadFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
        coordinator.window = nil
    }

    private func apply(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, coordinator.window == nil else { return }
        coordinator.window = window
        coordinator.wasTransparent = window.titlebarAppearsTransparent
        coordinator.previousTitleVisibility = window.titleVisibility
        coordinator.hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
    }
}

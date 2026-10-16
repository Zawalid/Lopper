import AppKit
import SwiftUI

/// Lets the picture run up under the title bar: the bar turns transparent and its title disappears while this
/// view is on screen, the content is laid out from the very top of the window, and everything goes back exactly
/// as it was afterwards.
struct TransparentTitleBar: NSViewRepresentable {
    @MainActor
    final class Coordinator {
        weak var window: NSWindow?
        var wasTransparent = false
        var previousTitleVisibility = NSWindow.TitleVisibility.visible
        var hadFullSizeContent = false
        var previousBackground: NSColor?
        var previousSeparator = NSTitlebarSeparatorStyle.automatic
        var previousInsets = NSEdgeInsets()
        var observers: [NSObjectProtocol] = []

        /// The title bar eats the top of the window; a negative inset of the same size gives it back to the content.
        func claimTitlebar() {
            guard let window, let content = window.contentView else { return }
            let bar = max(0, window.frame.height - window.contentLayoutRect.height - previousInsets.top * -1)
            content.additionalSafeAreaInsets = NSEdgeInsets(top: -bar, left: 0, bottom: 0, right: 0)
            setTitlebarBackdrop(visible: false)
        }

        /// The system paints a flat grey behind the window buttons, and brings it back whenever the window loses
        /// focus. Those private views are made see-through instead of relying on a flag it can switch back on.
        func setTitlebarBackdrop(visible: Bool) {
            guard let frameView = window?.contentView?.superview else { return }
            func walk(_ view: NSView, _ depth: Int) {
                guard depth < 6 else { return }
                let name = String(describing: type(of: view))
                if name.contains("TitlebarBackgroundView") || name.contains("TitlebarDecorationView") {
                    view.alphaValue = visible ? 1 : 0
                }
                view.subviews.forEach { walk($0, depth + 1) }
            }
            walk(frameView, 0)
        }
    }

    /// The colour behind the picture. The title bar area shows the window's own background, so it is painted the
    /// same, and a gap can never show a different grey.
    private static let stageColor = NSColor(srgbRed: 0.043, green: 0.063, blue: 0.057, alpha: 1)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in apply(view?.window, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(view.window, context.coordinator)
    }

    @MainActor
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.observers.forEach(NotificationCenter.default.removeObserver)
        coordinator.observers = []
        guard let window = coordinator.window else { return }
        window.contentView?.additionalSafeAreaInsets = coordinator.previousInsets
        coordinator.setTitlebarBackdrop(visible: true)
        window.titlebarAppearsTransparent = coordinator.wasTransparent
        window.titleVisibility = coordinator.previousTitleVisibility
        if !coordinator.hadFullSizeContent { window.styleMask.remove(.fullSizeContentView) }
        window.backgroundColor = coordinator.previousBackground ?? .windowBackgroundColor
        window.titlebarSeparatorStyle = coordinator.previousSeparator
        coordinator.window = nil
    }

    private func apply(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, coordinator.window == nil else { return }
        coordinator.window = window
        coordinator.wasTransparent = window.titlebarAppearsTransparent
        coordinator.previousTitleVisibility = window.titleVisibility
        coordinator.hadFullSizeContent = window.styleMask.contains(.fullSizeContentView)
        coordinator.previousBackground = window.backgroundColor
        coordinator.previousSeparator = window.titlebarSeparatorStyle
        coordinator.previousInsets = window.contentView?.additionalSafeAreaInsets ?? NSEdgeInsets()
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = Self.stageColor
        coordinator.claimTitlebar()

        // Full screen and resizing change the title bar's height, so the inset follows it.
        for name in [
            NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ] {
            coordinator.observers.append(NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak coordinator] _ in
                Task { @MainActor in coordinator?.claimTitlebar() }
            })
        }
    }
}

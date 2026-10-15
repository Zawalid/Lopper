import SwiftUI

/// The quiet highlight macOS controls show under the pointer. Used for sidebar rows that are buttons, so they
/// read as clickable across their whole width and not only on a small glyph.
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    var isPressed = false
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(isPressed ? 0.14 : (isHovering ? 0.08 : 0))))
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

extension View {
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

/// A flat button for footers and toolbars inside the sidebar: no chrome until the pointer arrives.
struct SidebarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 6)
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.85) : Color.secondary.opacity(0.5))
            .modifier(HoverHighlight(isPressed: configuration.isPressed))
    }
}

/// A square icon button for the sidebar footer: the highlight is the same size for every icon, so a row of
/// them looks like a set and not like one wide bar plus two glyphs.
struct SidebarIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 30, height: 30)
            .foregroundStyle(isEnabled ? Color.primary.opacity(0.75) : Color.secondary.opacity(0.4))
            .modifier(HoverHighlight(cornerRadius: 8, isPressed: configuration.isPressed))
    }
}

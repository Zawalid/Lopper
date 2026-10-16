import SwiftUI
import AppKit

// One set of button styles for the whole app. Native macOS buttons have no hover state and keep the arrow
// cursor, which makes a custom interface feel inert. These show a hover and pressed state and switch the
// pointer to the link hand while the button is enabled.

/// Filled and quiet buttons. Size follows `controlSize`, so existing `.controlSize(.large)` calls keep working.
struct LopperButtonStyle: ButtonStyle {
    /// `stage` is the primary button on the dark banner: mint with dark text.
    enum Kind { case primary, secondary, stage }
    var kind: Kind

    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration, kind: kind, controlSize: controlSize)
    }

    private struct Rendered: View {
        let configuration: Configuration
        let kind: Kind
        let controlSize: ControlSize
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        private var metrics: (font: Font, horizontal: CGFloat, vertical: CGFloat, radius: CGFloat) {
            switch controlSize {
            case .mini, .small: (.caption.weight(.medium), 10, 4, 6)
            case .large, .extraLarge: (.body.weight(.medium), 18, 8, 10)
            default: (.callout.weight(.medium), 14, 6, 8)
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: metrics.radius, style: .continuous)
            configuration.label
                .font(metrics.font)
                .padding(.horizontal, metrics.horizontal)
                .padding(.vertical, metrics.vertical)
                .foregroundStyle(foreground)
                .background(shape.fill(fill))
                .overlay {
                    if kind == .secondary && isEnabled {
                        shape.strokeBorder(Color.primary.opacity(isHovering ? 0.18 : 0.1), lineWidth: 1)
                    }
                }
                .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
                .contentShape(shape)
                .onHover { isHovering = $0 }
                .pointerCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }

        private var foreground: Color {
            guard isEnabled else { return .secondary.opacity(0.7) }
            switch kind {
            case .primary: return .white
            case .stage: return Theme.ink
            case .secondary: return .primary
            }
        }

        private var fill: Color {
            guard isEnabled else { return Color.primary.opacity(0.08) }
            switch kind {
            case .primary:
                if configuration.isPressed { return Color.accentColor.opacity(0.78) }
                return isHovering ? Color.accentColor.opacity(0.88) : Color.accentColor
            case .stage:
                if configuration.isPressed { return Theme.mint.opacity(0.78) }
                return isHovering ? Theme.mint.opacity(0.92) : Theme.mint
            case .secondary:
                if configuration.isPressed { return Color.primary.opacity(0.2) }
                return Color.primary.opacity(isHovering ? 0.14 : 0.08)
            }
        }
    }
}

/// Text that acts as a link: accent color, underlined while the pointer is over it.
struct LopperLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    private struct Rendered: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
                .underline(isHovering && isEnabled)
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovering = $0 }
                .pointerCursor(isEnabled)
        }
    }
}

/// A card that is also a button: the whole card lifts a little on hover and gets an accent outline.
struct LopperCardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.cardRadius

    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration, cornerRadius: cornerRadius)
    }

    private struct Rendered: View {
        let configuration: Configuration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            configuration.label
                .overlay {
                    shape.fill(Color.primary.opacity(configuration.isPressed ? 0.08 : (isHovering ? 0.04 : 0)))
                        .allowsHitTesting(false)
                }
                .overlay {
                    shape.strokeBorder(Color.accentColor.opacity(isHovering ? 0.55 : 0), lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
                .contentShape(shape)
                .onHover { isHovering = $0 }
                .pointerCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

/// A small glyph-only button: a soft round highlight under the pointer.
struct LopperIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration)
    }

    private struct Rendered: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .padding(4)
                .foregroundStyle(isHovering && isEnabled ? Color.primary : Color.secondary)
                .background(
                    Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.16 : (isHovering ? 0.1 : 0))))
                .contentShape(Circle())
                .onHover { isHovering = $0 }
                .pointerCursor(isEnabled)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
    }
}

extension ButtonStyle where Self == LopperButtonStyle {
    static var lopperPrimary: LopperButtonStyle { LopperButtonStyle(kind: .primary) }
    static var lopperSecondary: LopperButtonStyle { LopperButtonStyle(kind: .secondary) }
    static var lopperStage: LopperButtonStyle { LopperButtonStyle(kind: .stage) }
}

extension ButtonStyle where Self == LopperLinkButtonStyle {
    static var lopperLink: LopperLinkButtonStyle { LopperLinkButtonStyle() }
}

extension ButtonStyle where Self == LopperCardButtonStyle {
    static var lopperCard: LopperCardButtonStyle { LopperCardButtonStyle() }
}

extension ButtonStyle where Self == LopperIconButtonStyle {
    static var lopperIcon: LopperIconButtonStyle { LopperIconButtonStyle() }
}

/// The pointing-hand cursor while the pointer is over a clickable thing. One code path on every macOS
/// version: the cursor is pushed on entry and popped on exit, and only ever popped if this view pushed it.
private struct PointerCursor: ViewModifier {
    let isEnabled: Bool
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                if inside && isEnabled && !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if (!inside || !isEnabled) && pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            .onDisappear {
                if pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
    }
}

extension View {
    func pointerCursor(_ isEnabled: Bool = true) -> some View {
        modifier(PointerCursor(isEnabled: isEnabled))
    }
}

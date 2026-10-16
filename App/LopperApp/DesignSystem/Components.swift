import SwiftUI
import Lopper

struct VerdictChip: View {
    let kind: VerdictKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(kind.textTint)
            .background(kind.tint.opacity(0.15), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Verdict: \(kind.label)")
    }
}

struct HealthBar: View {
    let safe: Int
    let review: Int
    let protected: Int

    var body: some View {
        GeometryReader { proxy in
            let total = max(1, safe + review + protected)
            HStack(spacing: 2) {
                segment(.green, safe, total, proxy.size.width)
                segment(.orange, review, total, proxy.size.width)
                segment(Color.secondary.opacity(0.35), protected, total, proxy.size.width)
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(safe) safe, \(review) to review, \(protected) protected")
    }

    @ViewBuilder
    private func segment(_ color: Color, _ count: Int, _ total: Int, _ width: CGFloat) -> some View {
        if count > 0 {
            Rectangle().fill(color).frame(width: max(3, width * CGFloat(count) / CGFloat(total)))
        }
    }
}

/// The Overview's banner: the number that matters on the same dark stage and living graph as the welcome screen,
/// in both appearances. Everything on it is white on blue-black, so it reads the same in light and dark mode.
struct ReclaimHero: View {
    let headline: String
    let value: String
    let summary: String
    let actionTitle: String?
    let footnote: String?
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var freshness: Date?
    var onRescan: (() -> Void)?
    let action: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            Theme.ink
            LopperScene(compact: true, intensity: 0.9)
            LinearGradient(
                stops: [
                    .init(color: Theme.ink.opacity(0.96), location: 0),
                    .init(color: Theme.ink.opacity(0.85), location: 0.42),
                    .init(color: Theme.ink.opacity(0), location: 0.72),
                ],
                startPoint: .leading, endPoint: .trailing)
                .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(headline.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(2.2)
                    .foregroundStyle(Theme.mint.opacity(0.9))
                Text(value)
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(LinearGradient(colors: [.white, Theme.mint], startPoint: .top, endPoint: .bottom))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Text(summary)
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle {
                    HStack(spacing: Theme.Spacing.md) {
                        Button(actionTitle, action: action)
                            .buttonStyle(.lopperPrimary)
                            .controlSize(.large)
                        if let secondaryTitle, let secondaryAction {
                            Button(secondaryTitle, action: secondaryAction)
                                .buttonStyle(.lopperSecondary)
                                .controlSize(.large)
                        }
                    }
                    .padding(.top, Theme.Spacing.sm)
                }
                HStack(spacing: Theme.Spacing.sm) {
                    if let footnote { Text(footnote) }
                    if let freshness {
                        if footnote != nil { Text("·") }
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(OverviewInsights.freshness(of: freshness, now: context.date))
                        }
                        if let onRescan {
                            Button("Rescan", action: onRescan).buttonStyle(.lopperLink)
                        }
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.top, 2)
            }
            .frame(maxWidth: 470, alignment: .leading)
            .padding(.leading, 40)
            .padding(.vertical, 34)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

struct RepoCard: View {
    let summary: RepoSummary
    var onClean: (() -> Void)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(summary.name)
                        .font(.data(.callout, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if summary.failure != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(summary.failure ?? "")
                    }
                }
                .padding(.trailing, quickCleanTitle == nil ? 0 : 84)
                HealthBar(safe: summary.safe, review: summary.review, protected: summary.protected)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.lopperCard)
        // A sibling of the card button, not inside it, so the click goes to exactly one of them.
        .overlay(alignment: .topTrailing) {
            if let onClean, let title = quickCleanTitle {
                Button(title, action: onClean)
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
                    .padding(Theme.Spacing.sm)
                    .help("Review these \(summary.safe) safe items, then remove them")
            }
        }
        .accessibilityLabel("\(summary.name), \(summary.safe) safe, \(summary.review) to review")
    }

    private var quickCleanTitle: String? {
        summary.failure == nil && summary.safe > 0 ? "Clean \(summary.safe)" : nil
    }

    private var detail: String {
        if let failure = summary.failure { return failure }
        if summary.defaultBranch == nil { return "Default branch unknown" }
        var text = "\(summary.safe) safe · \(summary.review) review · \(summary.protected) protected"
        if summary.reclaimableBytes > 0 { text += " · " + SizeFormat.string(summary.reclaimableBytes) }
        return text
    }
}

/// One number in the strip under the hero: a big figure and a small label with a coloured dot. No box, no icon.
/// It is a button only when there is somewhere sensible to go.
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 5) {
            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(title).font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.sm)
        .padding(.horizontal, Theme.Spacing.sm)
        .background(Color.primary.opacity(action != nil && isHovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
                .onHover { isHovering = $0 }
                .pointerCursor()
                .accessibilityLabel("\(title): \(value)")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title): \(value)")
        }
    }
}

extension View {
    /// A row of stat tiles between two hairlines, the way a table of figures sits on a page.
    func statStrip() -> some View {
        self
            .padding(.vertical, Theme.Spacing.xs)
            .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1) }
    }
}

/// A button that confirms what it did: its label turns into a green check and a short word for a moment.
/// Both labels are laid out together, so the button does not change width when it flips.
struct FeedbackButton: View {
    let title: String
    let systemImage: String
    var successTitle = "Copied"
    var iconOnly = false
    let action: () -> Void

    @State private var succeeded = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            action()
            withAnimation(.snappy(duration: 0.18)) { succeeded = true }
            AccessibilityNotification.Announcement(successTitle).post()
            resetTask?.cancel()
            resetTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.snappy(duration: 0.18)) { succeeded = false }
            }
        } label: {
            ZStack {
                content(title, systemImage).opacity(succeeded ? 0 : 1)
                content(successTitle, "checkmark").foregroundStyle(.green).opacity(succeeded ? 1 : 0)
            }
        }
        .help(succeeded ? successTitle : title)
        .accessibilityLabel(succeeded ? successTitle : title)
    }

    @ViewBuilder
    private func content(_ text: String, _ symbol: String) -> some View {
        if iconOnly {
            Image(systemName: symbol)
        } else {
            Label(text, systemImage: symbol)
        }
    }
}

/// The small floating message for actions that cannot show their own result, such as a context menu item.
struct ConfirmationPill: View {
    let message: String

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .accessibilityElement(children: .combine)
    }
}

/// Opens the Settings window on a given pane. `SettingsLink` cannot say which one.
struct OpenSettingsButton<Label: View>: View {
    let pane: SettingsPane
    @ViewBuilder var label: () -> Label
    @Environment(\.openSettings) private var openSettings
    @Environment(AppModel.self) private var model

    var body: some View {
        Button {
            model.requestSettingsPane(pane)
            openSettings()
        } label: {
            label()
        }
    }
}

struct Banner: View {
    let symbol: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(message).font(.callout)
            Spacer(minLength: Theme.Spacing.md)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.lopperLink)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.lopperIcon)
                    .accessibilityLabel("Dismiss")
            }
        }
        .padding(Theme.Spacing.md)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
    }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).padding(.top, Theme.Spacing.sm)
            }
        }
        .frame(maxWidth: 360)
        .padding(Theme.Spacing.xl)
    }
}

struct UndoToastView: View {
    let toast: UndoToast
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(message).font(.callout)
            Button("Undo", action: onUndo).buttonStyle(.lopperLink)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.lopperIcon)
                .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(nsColor: .separatorColor)))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        let size = toast.reclaimed > 0 ? ", \(SizeFormat.string(toast.reclaimed)) reclaimed" : ""
        if toast.folders {
            let waiting = toast.reclaimed > 0 ? ", \(SizeFormat.string(toast.reclaimed)) to free" : ""
            return "Moved \(Plural.count(toast.removed, "folder")) to the Trash\(waiting)"
        }
        return "Removed \(Plural.count(toast.removed, "item"))\(size)"
    }
}

/// A repository card that has not been read yet. It breathes slowly so the page does not look frozen.
struct SkeletonCard: View {
    @State private var dim = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)).frame(width: 110, height: 12)
            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.07)).frame(height: 6)
            RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.07)).frame(width: 150, height: 9)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 79)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
        .opacity(dim ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
        .onAppear { dim = true }
        .accessibilityHidden(true)
    }
}

import SwiftUI
import Lopper

struct VerdictChip: View {
    let kind: VerdictKind

    var body: some View {
        Label(kind.label, systemImage: kind.symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(kind.tint)
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
        VStack(spacing: Theme.Spacing.sm) {
            Text(headline)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 56, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(summary)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
                if let footnote {
                    Text(footnote)
                }
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
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
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
                        .font(.headline)
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
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
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

/// One number in the strip under the hero. It is a button only when there is somewhere sensible to go.
struct StatTile: View {
    let title: String
    let value: String
    let symbol: String
    let tint: Color
    var action: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))

        if let action {
            Button(action: action) { content }
                .buttonStyle(.lopperCard)
                .accessibilityLabel("\(title): \(value)")
        } else {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title): \(value)")
        }
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

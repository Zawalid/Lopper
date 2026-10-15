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
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, Theme.Spacing.sm)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}

struct RepoCard: View {
    let summary: RepoSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text(summary.name).font(.headline)
                    Spacer()
                    if summary.failure != nil {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(summary.failure ?? "")
                    } else if summary.reclaimableBytes > 0 {
                        Text(SizeFormat.string(summary.reclaimableBytes))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                HealthBar(safe: summary.safe, review: summary.review, protected: summary.protected)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(summary.name), \(summary.safe) safe, \(summary.review) to review")
    }

    private var detail: String {
        if let failure = summary.failure { return failure }
        if summary.defaultBranch == nil { return "Default branch unknown" }
        return "\(summary.safe) safe, \(summary.review) to review, \(summary.protected) protected"
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
                Button(actionTitle, action: action).buttonStyle(.link)
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
            Button("Undo", action: onUndo).buttonStyle(.link)
            Button(action: onDismiss) { Image(systemName: "xmark") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
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

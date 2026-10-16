import SwiftUI
import AppKit

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            VStack(spacing: Theme.Spacing.sm) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Lopper").font(.title.weight(.semibold))
                Text(version).font(.data(.callout)).foregroundStyle(.secondary)
                Text("Keeps your repositories light. Finds the branches, worktrees and generated folders you no longer need, shows why each is safe to remove, and lets you undo anything for 30 days.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                Text("No account, no analytics, nothing leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(Theme.metaText)
            }

            Divider().frame(maxWidth: 280)

            VStack(spacing: Theme.Spacing.sm) {
                Text("Made by \(ProjectLinks.author)")
                    .font(.callout.weight(.medium))
                HStack(spacing: Theme.Spacing.lg) {
                    AboutLink(title: "GitHub", symbol: "chevron.left.forwardslash.chevron.right", link: .authorGitHub)
                    AboutLink(title: "zawalid.com", symbol: "globe", link: .authorWebsite)
                    AboutLink(title: "X", symbol: "at", link: .authorX)
                }
            }

            HStack(spacing: Theme.Spacing.lg) {
                AboutLink(title: "Source code", symbol: "curlybraces", link: .repository)
                AboutLink(title: "Report an issue", symbol: "exclamationmark.bubble", link: .issues)
                AboutLink(title: "MIT licence", symbol: "doc.text", link: .license)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A quiet text link with a small icon. The pointer turns into a hand and the label underlines on hover.
private struct AboutLink: View {
    let title: String
    let symbol: String
    let link: ProjectLinks.Link
    @Environment(\.openURL) private var openURL
    @State private var isHovering = false

    var body: some View {
        Button {
            openURL(link.url)
        } label: {
            Label(title, systemImage: symbol)
                .font(.callout)
                .underline(isHovering)
                .foregroundStyle(isHovering ? Theme.accentText : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help(link.url.absoluteString)
        .accessibilityLabel(title)
        .accessibilityHint("Opens \(link.url.host() ?? "the link") in your browser")
    }
}

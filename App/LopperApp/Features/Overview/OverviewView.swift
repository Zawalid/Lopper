import SwiftUI
import Lopper

struct OverviewView: View {
    var body: some View {
        ScrollView {
            OverviewContent()
        }
        .navigationTitle("Overview")
    }
}

/// The scrollable body of the Overview, separate from the scroll view so it can be rendered offscreen.
struct OverviewContent: View {
    @Environment(AppModel.self) private var model
    @State private var dismissedGitHubBanner = false

    var body: some View {
        let totals = model.totals
        VStack(spacing: Theme.Spacing.xl) {
            banners
            hero(totals)
            cards
        }
        .padding(32)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var banners: some View {
        if !model.githubCLIAvailable && !dismissedGitHubBanner && !model.snapshots.isEmpty {
            Banner(
                symbol: "link",
                message: "Install the GitHub CLI to detect branches merged through pull requests.",
                actionTitle: "Learn more",
                action: { OpenActions.open(URL(string: "https://cli.github.com")!) },
                onDismiss: { dismissedGitHubBanner = true })
        }
    }

    @ViewBuilder
    private func hero(_ totals: Totals) -> some View {
        switch model.phase {
        case .idle:
            EmptyState(
                symbol: "folder.badge.plus", title: "No repositories yet",
                message: "Choose the folders where your projects live.",
                actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
        case .scanning(let done, let total) where model.snapshots.isEmpty:
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text(total == 0 ? "Looking for repositories…" : "Scanning \(done) of \(total)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        default:
            if totals.safe == 0 {
                EmptyState(
                    symbol: "checkmark.seal", title: "All tidy",
                    message: totals.review > 0
                        ? "Nothing is safe to remove. \(Plural.count(totals.review, "item")) need a look."
                        : "Nothing is waiting to be cleaned up.")
            } else {
                ReclaimHero(
                    bytes: totals.reclaimableBytes,
                    headline: "Ready to reclaim",
                    summary: summary(totals),
                    actionTitle: "Review and clean",
                    footnote: "Every removal can be undone for \(model.settings.trashRetentionDays) days",
                    action: { model.beginCleanAllSafe() })
            }
        }
    }

    private func summary(_ totals: Totals) -> String {
        let repos = model.summaries.filter(\.hasSafeItems).count
        return "\(Plural.count(totals.safeBranches, "branch", "branches")) and "
            + "\(Plural.count(totals.safeWorktrees, "worktree")) across "
            + "\(Plural.count(repos, "repository", "repositories")) are safe to remove"
    }

    @ViewBuilder
    private var cards: some View {
        if !model.summaries.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg) {
                ForEach(model.summaries) { summary in
                    RepoCard(summary: summary) { model.route = .repo(summary.id) }
                }
            }
        }
    }
}

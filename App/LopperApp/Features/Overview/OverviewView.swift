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
        switch model.overviewState {
        case .needsFolders:
            EmptyState(
                symbol: "folder.badge.plus", title: "Choose your project folders",
                message: "Lopper looks for git repositories inside the folders you pick.",
                actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
        case .scanning(let done, let total):
            VStack(spacing: Theme.Spacing.md) {
                ProgressView()
                Text(total == 0 ? "Looking for repositories…" : "Scanning \(done) of \(total)…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
        case .nothingFound:
            EmptyState(
                symbol: "magnifyingglass", title: "No repositories found",
                message: "There are no git repositories in the folders you chose. Try a folder higher up, or add another.",
                actionTitle: "Choose folders", action: { FolderPicker.choose { model.setRoots($0) } })
        case .allTidy(let review):
            EmptyState(
                symbol: "checkmark.seal", title: "All tidy",
                message: review > 0
                    ? "Nothing is safe to remove. \(Plural.count(review, "item")) need a look."
                    : "Nothing is waiting to be cleaned up.")
        case .ready:
            ReclaimHero(
                headline: model.heroHeadline,
                value: model.heroValue,
                summary: summary(totals),
                actionTitle: "Review and clean",
                footnote: "Every removal can be undone for \(model.settings.trashRetentionDays) days",
                action: { model.beginCleanAllSafe() })
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

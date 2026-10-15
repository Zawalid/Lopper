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
            statStrip(totals)
            cards
            activity
            foldersFooter
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
                secondaryTitle: model.repositoryWithMostToReview.map { _ in "Look at the \(totals.review) to review" },
                secondaryAction: {
                    if let repo = model.repositoryWithMostToReview { model.openRepository(repo.id, showing: .review) }
                },
                freshness: model.lastScan,
                onRescan: { model.startScan() },
                action: { model.beginCleanAllSafe() })
        }
    }

    private func summary(_ totals: Totals) -> String {
        OverviewInsights.safeSummary(
            branches: totals.safeBranches, worktrees: totals.safeWorktrees,
            repositories: model.summaries.filter(\.hasSafeItems).count)
    }

    @ViewBuilder
    private func statStrip(_ totals: Totals) -> some View {
        if case .ready = model.overviewState {
            HStack(spacing: Theme.Spacing.md) {
                StatTile(
                    title: "Safe to remove", value: "\(totals.safe)", symbol: "checkmark.circle",
                    tint: VerdictKind.safe.tint, action: { model.beginCleanAllSafe() })
                StatTile(
                    title: "Need a look", value: "\(totals.review)", symbol: "eye",
                    tint: VerdictKind.review.tint,
                    action: model.repositoryWithMostToReview.map { repo in
                        { model.openRepository(repo.id, showing: .review) }
                    })
                StatTile(
                    title: "Protected", value: "\(totals.protected)", symbol: "lock",
                    tint: VerdictKind.protected.tint)
                if totals.reclaimableBytes > 0 {
                    StatTile(
                        title: "Can be reclaimed", value: SizeFormat.string(totals.reclaimableBytes),
                        symbol: "internaldrive", tint: .blue)
                } else {
                    // Sizes arrive after the scan; until then a dash would only look broken.
                    StatTile(
                        title: "Repositories", value: "\(totals.repositories)",
                        symbol: "shippingbox", tint: .blue)
                }
            }
        }
    }

    @ViewBuilder
    private var activity: some View {
        let batches = OverviewInsights.recentActivity(history: model.history)
        if !batches.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Recent activity").font(.headline)
                    Spacer()
                    Button("See all") { model.route = .history }.buttonStyle(.lopperLink)
                }
                VStack(spacing: 0) {
                    ForEach(Array(batches.enumerated()), id: \.element.id) { index, batch in
                        if index > 0 { Divider() }
                        ActivityRow(batch: batch) {
                            if let id = batch.batchID { model.restoreBatch(id) }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))

                let removed = OverviewInsights.lifetimeRemoved(history: model.history)
                if removed > 0 {
                    Text("\(Plural.count(removed, "item")) removed with Lopper so far")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        let attention = model.attentionSummaries
        let tidy = model.tidySummaries
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !attention.isEmpty {
                grid(attention)
            }
            if !tidy.isEmpty {
                DisclosureGroup("\(Plural.count(tidy.count, "repository", "repositories")) already tidy") {
                    grid(tidy).padding(.top, Theme.Spacing.sm)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private func grid(_ summaries: [RepoSummary]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg) {
            ForEach(summaries) { summary in
                RepoCard(
                    summary: summary,
                    onClean: { model.beginCleanSafe(inRepo: summary.id) },
                    action: { model.route = .repo(summary.id) })
            }
        }
    }

    private var foldersFooter: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(model.foldersSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Add folder…") { FolderPicker.choose { model.addRoots($0) } }
                .buttonStyle(.lopperLink)
            SettingsLink { Text("Manage folders") }
                .buttonStyle(.lopperLink)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.md)
    }
}

private struct ActivityRow: View {
    let batch: ActivityBatch
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "arrow.uturn.backward.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(Plural.count(batch.itemCount, "item")) removed")
                    .font(.callout.weight(.medium))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Theme.Spacing.md)
            if batch.canRestore {
                Button("Undo", action: onUndo)
                    .buttonStyle(.lopperSecondary)
                    .controlSize(.small)
            } else {
                Text("Restored").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var subtitle: String {
        let when = batch.date.formatted(.relative(presentation: .named))
        let repos = batch.repoNames.prefix(3).joined(separator: ", ")
        return repos.isEmpty ? when : "\(repos) · \(when)"
    }
}

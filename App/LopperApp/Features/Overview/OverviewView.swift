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
    @Environment(\.openSettings) private var openSettings
    @State private var dismissedGitHubBanner = false
    @State private var dismissedLocalOnlyBanner = false
    @State private var tidyExpanded = false

    var body: some View {
        let totals = model.totals
        VStack(spacing: Theme.Spacing.xl) {
            banners
            ForEach(OverviewLayout.sections(for: model.overviewState), id: \.self) { section in
                content(for: section, totals: totals)
            }
        }
        .padding(32)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func content(for section: OverviewSection, totals: Totals) -> some View {
        switch section {
        case .hero: hero(totals)
        case .statStrip: statStrip(totals)
        case .suggestions: suggestions
        case .worthALook: worthALook(totals)
        case .staleNote: staleRow
        case .cards: cards
        case .activity: activity
        case .folders: foldersFooter
        }
    }

    @ViewBuilder
    private var banners: some View {
        if let removed = OverviewInsights.justRemoved(history: model.history) {
            Banner(
                symbol: "checkmark.circle.fill",
                message: "\(removed). Everything can be undone for \(model.settings.trashRetentionDays) days.",
                actionTitle: "Undo",
                action: {
                    if let id = OverviewInsights.recentActivity(history: model.history, limit: 1).first?.batchID {
                        model.restoreBatch(id)
                    }
                })
        }
        if model.setupIssue == nil, !model.unreadableFolders.isEmpty {
            Banner(
                symbol: "lock.shield",
                message: SetupGuide.partialNotice(model.unreadableFolders),
                actionTitle: "Manage folders",
                action: {
                    model.requestSettingsPane(.folders)
                    openSettings()
                })
        }
        if model.localOnlySummary.items > 0, !dismissedLocalOnlyBanner, model.setupIssue == nil {
            Banner(
                symbol: "icloud.slash",
                message: LocalOnlyKindStyle.headline(model.localOnlySummary) + ".",
                actionTitle: "See what",
                action: { model.route = .onlyHere },
                onDismiss: { dismissedLocalOnlyBanner = true })
        }
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
            VStack(spacing: Theme.Spacing.xl) {
                VStack(spacing: Theme.Spacing.md) {
                    Text(total == 0 ? "Looking for repositories…" : "Scanning \(done) of \(total)…")
                        .font(.title3.weight(.medium))
                    if total > 0 {
                        ProgressView(value: Double(done), total: Double(total))
                            .frame(maxWidth: 320)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                    Text("Nothing is changed while Lopper looks.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 40)
                skeletonGrid(count: max(3, OverviewInsights.skeletonCount(done: done, total: total, limit: 6)))
            }
            .frame(maxWidth: .infinity)
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
                headline: model.isScanning ? "Found so far" : model.heroHeadline,
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
                bars: heroBars,
                action: { model.beginCleanAllSafe() })
            // Cleaning a partial list would leave out whatever has not been read yet.
            .disabled(model.isScanning)
        }
    }

    /// The repositories holding the most to reclaim: by size once it is measured, otherwise by how much is safe.
    private var heroBars: [HeroBar] {
        let withSize = model.summaries.filter { $0.reclaimableBytes > 0 }
        if !withSize.isEmpty {
            return withSize.sorted { $0.reclaimableBytes > $1.reclaimableBytes }.prefix(5).map {
                HeroBar(id: $0.id, name: $0.name, weight: Double($0.reclaimableBytes), label: SizeFormat.string($0.reclaimableBytes))
            }
        }
        return model.summaries
            .map { ($0, $0.safeBranches + $0.safeWorktrees) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { HeroBar(id: $0.0.id, name: $0.0.name, weight: Double($0.1), label: "\($0.1) safe") }
    }

    private func summary(_ totals: Totals) -> String {
        OverviewInsights.safeSummary(
            branches: totals.safeBranches, worktrees: totals.safeWorktrees,
            repositories: model.summaries.filter(\.hasSafeItems).count)
    }

    @ViewBuilder
    private func statStrip(_ totals: Totals) -> some View {
        if case .ready = model.overviewState {
            HStack(spacing: Theme.Spacing.lg) {
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
                StatTile(
                    title: "Repositories", value: "\(totals.repositories)",
                    symbol: "shippingbox", tint: Color.accentColor)
            }
            .statStrip()
        }
    }

    /// What the person's own rules found. Opening one goes to the same review sheet as everything else.
    @ViewBuilder
    private var suggestions: some View {
        let found = model.ruleSuggestions
        if !found.isEmpty && !model.isScanning {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Suggested by your rules").font(.headline)
                    Text("Nothing is removed until you review it.")
                        .font(.caption).foregroundStyle(Theme.metaText)
                    Spacer()
                    OpenSettingsButton(pane: .rules) { Text("Edit rules") }
                        .buttonStyle(.lopperLink)
                }
                VStack(spacing: 0) {
                    ForEach(Array(found.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 { Divider() }
                        HStack(spacing: Theme.Spacing.md) {
                            Image(systemName: suggestion.kind == .untouchedFolders ? "shippingbox" : "arrow.triangle.branch")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 28, height: 28)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(suggestion.title).font(.callout.weight(.medium))
                                Text(suggestion.detail)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Theme.Spacing.md)
                            Button("Review") { model.review(suggestion) }
                                .buttonStyle(.lopperSecondary)
                                .controlSize(.small)
                                .disabled(model.clean != nil || model.diskClear != nil)
                        }
                        .padding(Theme.Spacing.md)
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
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
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))

                let removed = OverviewInsights.lifetimeRemoved(history: model.history)
                if removed > 0 {
                    Text("\(Plural.count(removed, "item")) removed with Lopper so far")
                        .font(.caption)
                        .foregroundStyle(Theme.metaText)
                }
            }
        }
    }

    @ViewBuilder
    private var cards: some View {
        let attention = model.attentionSummaries
        let tidy = model.tidySummaries
        let pending: Int = {
            if case .scanning(let done, let total) = model.phase {
                return OverviewInsights.skeletonCount(done: done, total: total, limit: 3)
            }
            return 0
        }()
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if !attention.isEmpty || pending > 0 {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text("Repositories").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(attention) { summary in
                            RepoRow(
                                summary: summary,
                                onClean: { model.beginCleanSafe(inRepo: summary.id) },
                                action: { model.route = .repo(summary.id) })
                        }
                        ForEach(0..<pending, id: \.self) { _ in RepoSkeletonRow() }
                    }
                    .overlay(alignment: .top) { Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.6)).frame(height: 1) }
                }
            }
            if !tidy.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    // The whole row is the button, so it opens wherever it is clicked.
                    Button {
                        withAnimation(.easeOut(duration: 0.18)) { tidyExpanded.toggle() }
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(tidyExpanded ? 90 : 0))
                                .foregroundStyle(Theme.metaText)
                                .frame(width: 14)
                            Text("\(Plural.count(tidy.count, "repository", "repositories")) already tidy")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, Theme.Spacing.sm)
                        .hoverHighlight(cornerRadius: Theme.controlRadius)
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(tidyExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows or hides the repositories with nothing to do")

                    if tidyExpanded {
                        FlowLayout(spacing: Theme.Spacing.sm) {
                            ForEach(tidy) { summary in
                                Button { model.route = .repo(summary.id) } label: {
                                    Text(summary.name)
                                        .font(.callout)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                }
                                .buttonStyle(.lopperSecondary)
                                .controlSize(.small)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    private func skeletonGrid(count: Int) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.lg)], spacing: Theme.Spacing.lg
        ) {
            ForEach(0..<count, id: \.self) { _ in SkeletonCard() }
        }
    }

    @ViewBuilder
    private func worthALook(_ totals: Totals) -> some View {
        let highlights = OverviewInsights.reviewHighlights(rows: model.rowsToConsider())
        if !highlights.isEmpty {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Text("Worth a look").font(.headline)
                    Text("Not merged anywhere Lopper can see. Nothing here is removed without you.")
                        .font(.caption)
                        .foregroundStyle(Theme.metaText)
                        .lineLimit(1)
                    Spacer()
                    if totals.review > highlights.count, let repo = model.repositoryWithMostToReview {
                        Button("See all \(totals.review)") { model.openRepository(repo.id, showing: .review) }
                            .buttonStyle(.lopperLink)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(Array(highlights.enumerated()), id: \.element.id) { index, highlight in
                        if index > 0 { Divider() }
                        HighlightRow(highlight: highlight) {
                            model.openRepository(highlight.repoID, showing: .review)
                            model.focusedRowID = highlight.id
                        }
                    }
                }
                .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
            }
        }
    }

    @ViewBuilder
    private var staleRow: some View {
        if let insight = OverviewInsights.staleInsight(rows: model.allRows, staleDays: model.settings.staleDays) {
            Label(insight.sentence, systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var foldersFooter: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: "folder")
                .foregroundStyle(Theme.metaText)
            Text(model.foldersSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Divider().frame(height: 14)
            Button("Add folder…") { FolderPicker.choose { model.addRoots($0) } }
                .buttonStyle(.lopperLink)
            OpenSettingsButton(pane: .folders) { Text("Manage") }
                .buttonStyle(.lopperLink)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Color.primary.opacity(0.05), in: Capsule())
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
                Text("Restored").font(.caption).foregroundStyle(Theme.metaText)
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

private struct HighlightRow: View {
    let highlight: ReviewHighlight
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: highlight.kind.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(VerdictKind.review.tint)
                    .frame(width: 28, height: 28)
                    .background(
                        VerdictKind.review.tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(highlight.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(highlight.repoName) · \(highlight.evidence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.md)
                if let date = highlight.lastCommit {
                    Text(AgeFormat.short(from: date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.metaText)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.metaText)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .hoverHighlight(cornerRadius: Theme.cardRadius)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(highlight.title) in \(highlight.repoName). \(highlight.evidence)")
        .accessibilityHint("Opens it in the repository")
    }
}

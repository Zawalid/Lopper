import SwiftUI
import Lopper

/// Everything the details panel offers beyond the verdict itself, one small view each so the panel reads as a
/// list of sections and each can be previewed and tested on its own.

// MARK: Triage

/// "3 of 8" with previous and next, so the Review list can be worked through without going back to the table.
struct TriageControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let position = model.triagePosition, position.total > 1 {
            HStack(spacing: Theme.Spacing.xs) {
                Text("\(position.index) of \(position.total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button { model.focusPreviousRow() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.lopperIcon)
                    .disabled(position.previousID == nil)
                    .help("Previous item (Command-[)")
                    .accessibilityLabel("Previous item")
                Button { model.focusNextRow() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.lopperIcon)
                    .disabled(position.nextID == nil)
                    .help("Next item (Command-])")
                    .accessibilityLabel("Next item")
            }
        }
    }
}

// MARK: Pull request

/// The pull request for this branch, when there is one. An open one is drawn as a caution.
struct PullRequestCard: View {
    let pullRequest: PullRequestStatus

    var body: some View {
        let summary = InspectorInsights.pullRequestSummary(pullRequest)
        let tint: Color = summary.tone == .caution ? .blue : .secondary
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            GitHubMarkView(size: 15).foregroundStyle(tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline).font(.callout.weight(.medium))
                Text(pullRequest.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let detail = summary.detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let url = pullRequest.url {
                Button { OpenActions.open(url) } label: { Image(systemName: "arrow.up.right") }
                    .buttonStyle(.lopperIcon)
                    .help("Open on GitHub")
                    .accessibilityLabel("Open pull request on GitHub")
            }
        }
        .padding(Theme.Spacing.md)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(tint.opacity(0.25)))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Snooze

/// Puts an item aside for a while. Nothing about it changes; it just stops asking for attention.
struct SnoozeMenu: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        if let until = model.snoozedUntil(row), model.isSnoozed(row) {
            Button { model.wake(row) } label: {
                ActionLabel(title: "Snoozed until \(until.formatted(.dateTime.month(.abbreviated).day())). Wake now") {
                    Image(systemName: "bell.slash")
                }
            }
            .buttonStyle(.lopperSecondary)
        } else if row.verdict != .protected {
            Menu {
                ForEach(SnoozeDuration.allCases) { duration in
                    Button(duration.title) { model.snooze(row, for: duration) }
                }
            } label: {
                ActionLabel(title: "Snooze") { Image(systemName: "clock") }
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .help("Stop asking about this item for a while (Option-Command-S)")
        }
    }
}

// MARK: Actions

/// Everything you can do with the item besides removing it, laid out as one tidy block: the main open action
/// across the full width, two equal buttons under it, and the keep toggle as its own row.
struct InspectorActions: View {
    let row: CleanupRow

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            OpenWithMenu(row: row)
            HStack(spacing: Theme.Spacing.sm) {
                GitHubMenu(row: row)
                CopyMenu(row: row)
            }
            KeepBranchButton(row: row)
            SnoozeMenu(row: row)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The label every action button shares: icon, title, and room to stretch so equal columns line up.
private struct ActionLabel<Icon: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            icon().frame(width: 16, height: 16)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: Open with

/// A split button: the main part opens in the person's own editor, the arrow lists every installed app.
struct OpenWithMenu: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    private var folder: URL { row.path ?? row.repoRoot }

    var body: some View {
        let apps = OpenWithApps.available(
            isInstalled: { OpenActions.installed($0) }, preferredEditor: model.preferences.editorBundleID)
        if let first = apps.first {
            Menu {
                ForEach(OpenWithApp.Category.allCases, id: \.self) { category in
                    let group = apps.filter { $0.category == category }
                    if !group.isEmpty {
                        Section {
                            ForEach(group) { app in
                                Button { OpenActions.openWith(folder, bundleID: app.bundleID) } label: {
                                    if let icon = OpenActions.icon(forBundleID: app.bundleID) {
                                        Label { Text(app.name) } icon: { Image(nsImage: icon) }
                                    } else {
                                        Text(app.name)
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button("Reveal in Finder") { OpenActions.reveal(folder) }
            } label: {
                ActionLabel(title: "Open in \(first.name)") {
                    AppIconView(bundleID: first.bundleID, fallbackSymbol: "arrow.up.forward.app", size: 16)
                }
            } primaryAction: {
                OpenActions.openWith(folder, bundleID: first.bundleID)
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .help("Open \(row.path == nil ? "the repository" : "this worktree") in \(first.name), or pick another app")
        } else {
            Button { OpenActions.reveal(folder) } label: {
                ActionLabel(title: "Reveal in Finder") { Image(systemName: "folder") }
            }
            .buttonStyle(.lopperSecondary)
        }
    }
}

// MARK: GitHub

/// Links to the same item on GitHub. Absent for any other host, rather than pointing somewhere wrong.
struct GitHubMenu: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        let remote = model.remoteURL(for: row)
        let main = row.facts.defaultBranch
        let branchURL = RemoteLinks.branch(remoteURL: remote, name: row.title)
        let compareURL = main.flatMap { RemoteLinks.compare(remoteURL: remote, base: $0, branch: row.title) }
        let commitURL = row.facts.tip.flatMap { RemoteLinks.commit(remoteURL: remote, hash: $0) }

        if branchURL != nil || row.prURL != nil {
            Menu {
                if let url = row.prURL {
                    Button { OpenActions.open(url) } label: {
                        Label("Pull request", systemImage: "arrow.triangle.pull")
                    }
                }
                if let url = compareURL {
                    Button { OpenActions.open(url) } label: {
                        Label("Compare with \(main ?? "main")", systemImage: "arrow.left.arrow.right")
                    }
                }
                if let url = branchURL {
                    Button { OpenActions.open(url) } label: { Label("Branch page", systemImage: "arrow.triangle.branch") }
                }
                if let url = commitURL {
                    Button { OpenActions.open(url) } label: { Label("Latest commit", systemImage: "number") }
                }
            } label: {
                ActionLabel(title: "GitHub") { GitHubMarkView(size: 15) }
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Copy

struct CopyMenu: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button("Branch name") { model.copy(row.title, confirming: "Copied branch name") }
            if let tip = row.facts.tip {
                Button("Commit hash") { model.copy(tip, confirming: "Copied commit hash") }
            }
            if let path = row.path {
                Button("Path") { model.copy(path.path, confirming: "Copied path") }
            }
            if row.kind == .branch {
                Button("git switch command") {
                    model.copy("git switch \(row.title)", confirming: "Copied git switch command")
                }
            }
            if let url = row.prURL {
                Button("Pull request link") { model.copy(url.absoluteString, confirming: "Copied pull request link") }
            }
        } label: {
            ActionLabel(title: "Copy") { Image(systemName: "doc.on.doc") }
        }
        .menuStyle(.button)
        .buttonStyle(.lopperSecondary)
        .frame(maxWidth: .infinity)
    }
}

// MARK: Keep

/// Settles a Review item for good: the branch joins the repository's own protected list.
struct KeepBranchButton: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        if row.verdict != .protected || model.isKeptBranch(row.title, in: row.repoRoot) {
            let kept = model.isKeptBranch(row.title, in: row.repoRoot)
            Button {
                if kept {
                    model.stopKeepingBranch(row.title, in: row.repoRoot)
                } else {
                    model.keepBranch(row.title, in: row.repoRoot)
                }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: kept ? "lock.fill" : "lock")
                        .foregroundStyle(kept ? Color.accentColor : Color.secondary)
                        .frame(width: 16, height: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kept ? "Kept" : "Keep this branch").lineLimit(1)
                        Text(kept ? "Lopper will not remove it. Click to undo." : "Never offer to remove it")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.lopperSecondary)
            .help(kept
                ? "Let Lopper judge this branch by the usual rules again"
                : "Protect this branch so Lopper never offers to remove it")
        }
    }
}

// MARK: What would be lost

/// The commits that exist only on this item, so deciding does not need a terminal.
struct UniqueWorkSection: View {
    let row: CleanupRow
    @Environment(AppModel.self) private var model
    @State private var showsAll = false

    /// A long branch would push everything else out of the panel, so four commits show until asked for more.
    private static let collapsedCount = 4

    var body: some View {
        let history = model.branchHistory(for: row)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title(history)).font(.headline)
                if let diff = history?.diff { DiffChips(diff: diff) }
            }
            content(history)
        }
        .task(id: row.id) { await model.loadHistory(for: row) }
    }

    private func title(_ history: BranchHistory?) -> String {
        guard let history, let main = history.comparedTo else { return "Recent commits" }
        return history.totalCommits == 0 ? "Nothing only on this branch" : "Only on this branch, not in \(main)"
    }

    @ViewBuilder
    private func content(_ history: BranchHistory?) -> some View {
        if let history {
            if history.commits.isEmpty {
                Text(history.comparedTo == nil
                    ? "Lopper could not read this item's commits."
                    : "Every commit is already in \(history.comparedTo ?? "the default branch"), so removing it loses no work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let visible = showsAll ? history.commits : Array(history.commits.prefix(Self.collapsedCount))
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, commit in
                        if index > 0 { Divider() }
                        CommitRow(commit: commit, row: row)
                    }
                    if history.commits.count > Self.collapsedCount {
                        Divider()
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { showsAll.toggle() }
                        } label: {
                            Text(showsAll
                                ? "Show fewer"
                                : "Show \(history.commits.count - Self.collapsedCount) more")
                                .font(.caption.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Spacing.sm)
                                .hoverHighlight(cornerRadius: 6)
                        }
                        .buttonStyle(.plain)
                    }
                    if history.isTruncated && showsAll {
                        Divider()
                        Text("and \(history.totalCommits - history.commits.count) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.sm)
                    }
                }
                .background(
                    Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.cardRadius))
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Color(nsColor: .separatorColor)))
            }
        } else {
            HStack(spacing: Theme.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Reading commits…").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct DiffChips: View {
    let diff: DiffSummary

    var body: some View {
        HStack(spacing: 6) {
            Text("\(diff.files) \(diff.files == 1 ? "file" : "files")").foregroundStyle(.secondary)
            Text("+\(diff.insertions)").foregroundStyle(.green)
            Text("\u{2212}\(diff.deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(diff.files) files changed, \(diff.insertions) added, \(diff.deletions) removed")
    }
}

private struct CommitRow: View {
    let commit: CommitSummary
    let row: CleanupRow
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.copy(commit.hash, confirming: "Copied commit hash") } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(InspectorInsights.shortHash(commit.hash)).font(.caption.monospaced())
                    Text("·")
                    Text(commit.author)
                    Text("·")
                    Text(commit.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: 6)
        }
        .buttonStyle(.plain)
        .help("Copy commit hash")
        .accessibilityLabel("\(commit.subject), \(commit.author)")
        .accessibilityHint("Copies the commit hash")
    }
}

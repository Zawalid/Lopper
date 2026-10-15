import SwiftUI
import Lopper

/// Everything the details panel offers beyond the verdict itself, one small view each so the panel reads as a
/// list of sections and each can be previewed and tested on its own.

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
                Label("Open with \(first.name)", systemImage: "arrow.up.forward.app")
            } primaryAction: {
                OpenActions.openWith(folder, bundleID: first.bundleID)
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
            .help("Open \(row.path == nil ? "the repository" : "this worktree") in an app")
        } else {
            Button { OpenActions.reveal(folder) } label: { Label("Reveal in Finder", systemImage: "folder") }
                .buttonStyle(.lopperSecondary)
                .controlSize(.small)
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
                Label("GitHub", systemImage: "arrow.up.right.square")
            }
            .menuStyle(.button)
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
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
            Label("Copy", systemImage: "doc.on.doc")
        }
        .menuStyle(.button)
        .buttonStyle(.lopperSecondary)
        .controlSize(.small)
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
                Label(kept ? "Stop keeping" : "Keep this branch", systemImage: kept ? "lock.open" : "lock")
            }
            .buttonStyle(.lopperSecondary)
            .controlSize(.small)
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

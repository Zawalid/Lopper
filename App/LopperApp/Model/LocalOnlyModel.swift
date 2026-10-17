import Foundation
import Lopper

struct LocalOnlySummary: Equatable {
    var items = 0
    var repositories = 0
    var unpushedCommits = 0
}

struct LocalOnlyGroup: Identifiable, Equatable {
    var id: String { repoRoot.path }
    let repoRoot: URL
    let repoName: String
    let items: [LocalOnlyItem]
}

enum LocalOnlyPageState: Equatable {
    case needsFolders
    case scanning
    case allBackedUp(repositories: Int)
    case ready
}

extension AppModel {
    var localOnlySummary: LocalOnlySummary {
        LocalOnlySummary(
            items: localOnly.count,
            repositories: Set(localOnly.map(\.repoRoot)).count,
            unpushedCommits: localOnly.filter { $0.kind == .unpushedCommits }.reduce(0) { $0 + $1.count })
    }

    /// Repositories with something at risk, in the order the engine sorted them.
    var localOnlyGroups: [LocalOnlyGroup] {
        var groups: [LocalOnlyGroup] = []
        for item in localOnly {
            if let index = groups.firstIndex(where: { $0.repoRoot == item.repoRoot }) {
                groups[index] = LocalOnlyGroup(
                    repoRoot: item.repoRoot, repoName: item.repoName, items: groups[index].items + [item])
            } else {
                groups.append(LocalOnlyGroup(repoRoot: item.repoRoot, repoName: item.repoName, items: [item]))
            }
        }
        return groups
    }

    var localOnlyPageState: LocalOnlyPageState {
        if settings.roots.isEmpty { return .needsFolders }
        if !localOnlyLoaded { return .scanning }
        return localOnly.isEmpty ? .allBackedUp(repositories: summaries.count) : .ready
    }

    /// What exists only on this Mac for one branch or worktree row, for the inspector.
    func localOnlyItems(for row: CleanupRow) -> [LocalOnlyItem] {
        localOnly.filter { item in
            guard item.repoRoot == row.repoRoot else { return false }
            switch row.kind {
            case .branch: return item.branch == row.title && item.path == nil && item.kind != .stash
            case .worktree: return item.path?.canonicalized.path == row.path?.canonicalized.path
                || (item.branch == row.title && item.kind == .unpushedCommits)
            }
        }
    }

    /// One push command per unpushed branch in the repository, as lines for a terminal. Nothing is run.
    func copyPushCommands(_ section: LocalOnlySection) {
        let commands = section.pushCommands
        guard !commands.isEmpty else { return }
        copyHandler(commands.joined(separator: "\n"))
        confirm("Copied \(Plural.count(commands.count, "push command")) for \(section.repoName)")
    }

    /// A plain-text list of everything on the page, for a note or an issue.
    func copyLocalOnlyReport(_ sections: [LocalOnlySection]) {
        guard !sections.isEmpty else { return }
        copyHandler(LocalOnlyPresenter.report(of: sections))
        confirm("Copied the list")
    }

    func copyText(_ text: String, confirmation: String) {
        copyHandler(text)
        confirm(confirmation)
    }

    func copyPushCommand(_ item: LocalOnlyItem) {
        guard let command = item.pushCommand else { return }
        copyHandler(command)
        confirm("Copied the push command")
    }
}

enum LocalOnlyKindStyle {
    static func symbol(_ kind: LocalOnlyItem.Kind) -> String {
        switch kind {
        case .unpushedCommits: "arrow.up.circle"
        case .uncommittedChanges: "pencil.circle"
        case .stash: "tray"
        case .detachedCommits: "arrow.triangle.branch"
        case .operationInProgress: "exclamationmark.arrow.triangle.2.circlepath"
        }
    }

    static func label(_ kind: LocalOnlyItem.Kind) -> String {
        switch kind {
        case .unpushedCommits: "Not pushed"
        case .uncommittedChanges: "Uncommitted"
        case .stash: "Stash"
        case .detachedCommits: "No branch"
        case .operationInProgress: "Half done"
        }
    }

    /// Whether opening the row can show more than its one-line detail.
    static func hasDetail(_ kind: LocalOnlyItem.Kind) -> Bool { kind != .operationInProgress }

    /// The heading over the list inside an opened row.
    static func detailTitle(_ kind: LocalOnlyItem.Kind) -> String {
        switch kind {
        case .unpushedCommits: "Commits no remote has"
        case .detachedCommits: "Commits no branch holds"
        case .uncommittedChanges: "Files at risk"
        case .stash: "Files in this stash"
        case .operationInProgress: ""
        }
    }

    /// What it means, and what protects it, in one or two sentences.
    static func guidance(_ item: LocalOnlyItem) -> String {
        switch item.kind {
        case .unpushedCommits:
            item.pushCommand == nil
                ? "These commits exist only in this repository's folder, and it has no remote to push them to. Add a remote, or copy the folder, to back them up."
                : "These commits exist only in this Mac's copy. Pushing the branch puts them on the remote, which is the backup."
        case .detachedCommits:
            "No branch, tag or remote points at these commits, so git will eventually clean them up. Create a branch here to keep them, then push it."
        case .uncommittedChanges:
            item.hasTrackedChanges
                ? "These changes were never committed, so git cannot bring them back if the folder is lost. Commit them, then push."
                : "Git has never seen these files, so no commit or push includes them. Add and commit them if they matter."
        case .stash:
            "A stash lives only in this repository's folder and is never pushed. Apply it to a branch and commit it to keep the work."
        case .operationInProgress:
            "A rebase, merge or similar is half done in this folder. Finish it or abort it there, then check this page again."
        }
    }

    static func headline(_ summary: LocalOnlySummary) -> String {
        "\(Plural.count(summary.items, "item")) in \(Plural.count(summary.repositories, "repository", "repositories")) \(summary.items == 1 ? "exists" : "exist") only on this Mac"
    }
}

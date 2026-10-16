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

    static func headline(_ summary: LocalOnlySummary) -> String {
        "\(Plural.count(summary.items, "item")) in \(Plural.count(summary.repositories, "repository", "repositories")) \(summary.items == 1 ? "exists" : "exist") only on this Mac"
    }
}

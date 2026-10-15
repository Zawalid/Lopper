import Foundation

/// How the repository list in the sidebar is organised. A person's choice, remembered between launches.
enum SidebarGrouping: String, CaseIterable, Identifiable {
    case attention, folder, flat

    var id: Self { self }

    var title: String {
        switch self {
        case .attention: "Needs attention"
        case .folder: "Folder"
        case .flat: "Single list"
        }
    }

    var symbol: String {
        switch self {
        case .attention: "exclamationmark.circle"
        case .folder: "folder"
        case .flat: "list.bullet"
        }
    }
}

struct SidebarSection: Identifiable, Equatable {
    let id: String
    let title: String
    let repos: [RepoSummary]
    /// The collapsed-by-default group of repositories with nothing to do.
    let isTidy: Bool
}

extension RepoSummary {
    /// Something to act on, or something that went wrong and should be seen.
    var needsAttention: Bool { failure != nil || safe + review > 0 }

    /// Most safe items first, then most to review, then by name.
    static func attentionBefore(_ lhs: RepoSummary, _ rhs: RepoSummary) -> Bool {
        if lhs.safe != rhs.safe { return lhs.safe > rhs.safe }
        if lhs.review != rhs.review { return lhs.review > rhs.review }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

/// Turns the scanned repositories into the sections the sidebar shows. Pure, so every rule is unit tested.
enum SidebarLayout {
    /// Below this many repositories a search field is clutter.
    static let searchThreshold = 8

    static func showsSearch(repositoryCount: Int) -> Bool { repositoryCount > searchThreshold }

    static func sections(
        summaries: [RepoSummary], grouping: SidebarGrouping, folders: [URL], query: String
    ) -> [SidebarSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching = needle.isEmpty
            ? summaries
            : summaries.filter { $0.name.localizedCaseInsensitiveContains(needle) }

        let result: [SidebarSection]
        switch grouping {
        case .attention: result = byAttention(matching)
        case .folder: result = byFolder(matching, folders: folders)
        case .flat:
            result = [SidebarSection(id: "all", title: "Repositories", repos: ordered(matching), isTidy: false)]
        }
        return result.filter { !$0.repos.isEmpty }
    }

    private static func ordered(_ summaries: [RepoSummary]) -> [RepoSummary] {
        let busy = summaries.filter(\.needsAttention).sorted(by: RepoSummary.attentionBefore)
        let tidy = summaries.filter { !$0.needsAttention }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return busy + tidy
    }

    private static func byAttention(_ summaries: [RepoSummary]) -> [SidebarSection] {
        let busy = summaries.filter(\.needsAttention).sorted(by: RepoSummary.attentionBefore)
        let tidy = summaries.filter { !$0.needsAttention }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [
            SidebarSection(id: "attention", title: "Needs attention", repos: busy, isTidy: false),
            SidebarSection(id: "tidy", title: "Tidy", repos: tidy, isTidy: true),
        ]
    }

    private static func byFolder(_ summaries: [RepoSummary], folders: [URL]) -> [SidebarSection] {
        let canonical = folders.map { $0.canonicalized.path }
        var buckets: [Int: [RepoSummary]] = [:]
        var strays: [RepoSummary] = []

        for summary in summaries {
            let path = summary.root.canonicalized.path
            // The most specific folder wins, so a nested root keeps its own group.
            let best = canonical.enumerated()
                .filter { path == $0.element || path.hasPrefix($0.element + "/") }
                .max { $0.element.count < $1.element.count }
            if let best { buckets[best.offset, default: []].append(summary) } else { strays.append(summary) }
        }

        let names = folders.map(\.lastPathComponent)
        var sections = folders.indices.compactMap { index -> SidebarSection? in
            guard let repos = buckets[index] else { return nil }
            let duplicated = names.filter { $0 == names[index] }.count > 1
            let title = duplicated ? RowMapper.abbreviated(folders[index]) : names[index]
            return SidebarSection(
                id: canonical[index], title: title, repos: ordered(repos), isTidy: false)
        }
        if !strays.isEmpty {
            sections.append(SidebarSection(id: "other", title: "Other", repos: ordered(strays), isTidy: false))
        }
        return sections
    }
}

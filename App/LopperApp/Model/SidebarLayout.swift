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

/// The order of repositories inside a group.
enum SidebarSort: String, CaseIterable, Identifiable {
    case attention, name, size

    var id: Self { self }

    var title: String {
        switch self {
        case .attention: "Most to clean"
        case .name: "Name"
        case .size: "Size"
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

    /// One line of detail under the repository name: where it lives, how much is in it, what it would free.
    func detailLine(includingFolder: Bool) -> String {
        if failure != nil { return "Could not be read" }
        var parts: [String] = []
        if includingFolder { parts.append(root.deletingLastPathComponent().lastPathComponent) }
        parts.append(total == 0 ? "No extra branches" : Plural.count(total, "item"))
        if reclaimableBytes > 0 { parts.append(SizeFormat.string(reclaimableBytes)) }
        return parts.joined(separator: " · ")
    }

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
        summaries: [RepoSummary], grouping: SidebarGrouping, folders: [URL], query: String,
        sort: SidebarSort = .attention, showsTidy: Bool = true
    ) -> [SidebarSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var matching = needle.isEmpty
            ? summaries
            : summaries.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        // Hiding the tidy repositories must not make a search for one come back empty.
        if !showsTidy && needle.isEmpty { matching = matching.filter(\.needsAttention) }

        let result: [SidebarSection]
        switch grouping {
        case .attention: result = byAttention(matching, sort: sort)
        case .folder: result = byFolder(matching, folders: folders, sort: sort)
        case .flat:
            result = [SidebarSection(
                id: "all", title: "Repositories", repos: ordered(matching, sort: sort), isTidy: false)]
        }
        return result.filter { !$0.repos.isEmpty }
    }

    private static func byName(_ lhs: RepoSummary, _ rhs: RepoSummary) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func comparator(for sort: SidebarSort) -> (RepoSummary, RepoSummary) -> Bool {
        switch sort {
        case .attention: return RepoSummary.attentionBefore
        case .name: return byName
        case .size:
            return { lhs, rhs in
                if lhs.reclaimableBytes != rhs.reclaimableBytes { return lhs.reclaimableBytes > rhs.reclaimableBytes }
                return byName(lhs, rhs)
            }
        }
    }

    /// Busy repositories in the chosen order, then the tidy ones by name.
    private static func ordered(_ summaries: [RepoSummary], sort: SidebarSort) -> [RepoSummary] {
        summaries.filter(\.needsAttention).sorted(by: comparator(for: sort))
            + summaries.filter { !$0.needsAttention }.sorted(by: byName)
    }

    private static func byAttention(_ summaries: [RepoSummary], sort: SidebarSort) -> [SidebarSection] {
        [
            SidebarSection(
                id: "attention", title: "Needs attention",
                repos: summaries.filter(\.needsAttention).sorted(by: comparator(for: sort)), isTidy: false),
            SidebarSection(
                id: "tidy", title: "Tidy",
                repos: summaries.filter { !$0.needsAttention }.sorted(by: byName), isTidy: true),
        ]
    }

    private static func byFolder(
        _ summaries: [RepoSummary], folders: [URL], sort: SidebarSort
    ) -> [SidebarSection] {
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
                id: canonical[index], title: title, repos: ordered(repos, sort: sort), isTidy: false)
        }
        if !strays.isEmpty {
            sections.append(SidebarSection(
                id: "other", title: "Other", repos: ordered(strays, sort: sort), isTidy: false))
        }
        return sections
    }
}

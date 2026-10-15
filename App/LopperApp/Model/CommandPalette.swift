import Foundation

struct PaletteItem: Identifiable, Equatable {
    enum Kind: Int, Equatable {
        case page, action, repository, item, folder

        var heading: String {
            switch self {
            case .page: "Pages"
            case .action: "Actions"
            case .repository: "Repositories"
            case .item: "Branches and worktrees"
            case .folder: "Generated folders"
            }
        }
    }

    enum Action: Equatable {
        case rescan, cleanAllSafe, clearGeneratedFolders, clearUntouched, deleteTrashed, addFolder, undoLast
    }

    enum Target: Equatable {
        case route(Route)
        case repository(String)
        case row(id: String, repoID: String)
        case folder(String)
        case action(Action)
    }

    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let kind: Kind
    let target: Target
}

/// Finding things by typing. Pure, so the ranking is unit tested.
enum CommandPalette {
    /// With nothing typed only pages and actions are offered, so the palette opens short instead of listing
    /// every branch on the machine.
    static func search(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else {
            return items.filter { $0.kind == .page || $0.kind == .action }
        }
        return items
            .compactMap { item -> (PaletteItem, Int)? in
                guard let score = score(item, needle: needle) else { return nil }
                return (item, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                if $0.0.kind != $1.0.kind { return $0.0.kind.rawValue < $1.0.kind.rawValue }
                return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
            }
            .map(\.0)
    }

    private static func score(_ item: PaletteItem, needle: String) -> Int? {
        let title = item.title.lowercased()
        if title.hasPrefix(needle) { return 100 }
        if wordStarts(in: title).contains(where: { $0.hasPrefix(needle) }) { return 80 }
        if title.contains(needle) { return 60 }
        if item.subtitle.lowercased().contains(needle) { return 40 }
        if isSubsequence(needle, of: title) { return 20 }
        return nil
    }

    private static func wordStarts(in text: String) -> [Substring] {
        var starts: [Substring] = []
        var index = text.startIndex
        var atStart = true
        while index < text.endIndex {
            let character = text[index]
            if atStart, character.isLetter || character.isNumber { starts.append(text[index...]) }
            atStart = !(character.isLetter || character.isNumber)
            index = text.index(after: index)
        }
        return starts
    }

    private static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var remaining = needle[...]
        for character in text where remaining.first == character {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}

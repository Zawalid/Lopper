import Foundation

struct OpenWithApp: Identifiable, Equatable {
    /// Declared in the order the menu shows them.
    enum Category: Int, CaseIterable {
        case editor, terminal, gitClient
    }

    let name: String
    let bundleID: String
    let category: Category

    var id: String { bundleID }
}

/// The apps worth offering for opening a worktree or repository, filtered to what is installed.
enum OpenWithApps {
    static let catalog: [OpenWithApp] =
        EditorChoice.allCases.map { OpenWithApp(name: $0.name, bundleID: $0.rawValue, category: .editor) }
        + [
            OpenWithApp(name: "Sublime Text", bundleID: "com.sublimetext.4", category: .editor),
            OpenWithApp(name: "WebStorm", bundleID: "com.jetbrains.WebStorm", category: .editor),
            OpenWithApp(name: "IntelliJ IDEA", bundleID: "com.jetbrains.intellij", category: .editor),
        ]
        + TerminalChoice.allCases.map { OpenWithApp(name: $0.name, bundleID: $0.rawValue, category: .terminal) }
        + [
            OpenWithApp(name: "Fork", bundleID: "com.DanPristupov.Fork", category: .gitClient),
            OpenWithApp(name: "Tower", bundleID: "com.fournova.Tower3", category: .gitClient),
            OpenWithApp(name: "GitHub Desktop", bundleID: "com.github.GitHubClient", category: .gitClient),
            OpenWithApp(name: "Sourcetree", bundleID: "com.torusknot.SourceTreeNotMAS", category: .gitClient),
            OpenWithApp(name: "GitKraken", bundleID: "com.axosoft.gitkraken", category: .gitClient),
        ]

    /// Installed apps, editors first, then terminals, then Git clients; the person's own editor leads the list.
    static func available(isInstalled: (String) -> Bool, preferredEditor: String? = nil) -> [OpenWithApp] {
        let installed = catalog.filter { isInstalled($0.bundleID) }
        let grouped = installed.sorted { $0.category.rawValue < $1.category.rawValue }
        guard let preferredEditor, let index = grouped.firstIndex(where: { $0.bundleID == preferredEditor }) else {
            return grouped
        }
        var result = grouped
        result.insert(result.remove(at: index), at: 0)
        return result
    }
}

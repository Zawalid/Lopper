import Foundation

/// A folder worth scanning, with how many repositories it holds.
public struct DiscoveredFolder: Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public let path: URL
    public let repoCount: Int
    /// A few repository names, to show what is inside.
    public let sampleNames: [String]

    public init(path: URL, repoCount: Int, sampleNames: [String]) {
        self.path = path
        self.repoCount = repoCount
        self.sampleNames = sampleNames
    }
}

public enum SystemScanEvent: Sendable, Equatable {
    case progress(folders: Int, repos: Int)
    case finished([DiscoveredFolder])
}

/// Looks through the home folder for git repositories and returns the folders that hold them. Read only: it
/// lists directories and checks for `.git`, nothing else.
public struct SystemScanner: Sendable {
    /// Places that never hold the projects a person wants cleaned, or are too big to be worth walking.
    public static let skipNames: Set<String> = RepoScanner.defaultSkipNames.union([
        "Library", ".Trash", "Applications", "Movies", "Music", "Pictures", "Public",
        ".cache", ".npm", ".cargo", ".rustup", ".gradle", ".nvm", ".pnpm-store", ".yarn", ".m2", ".pyenv",
        ".local", ".docker", ".vscode", ".cursor", ".codex", ".claude", ".Spotlight-V100", ".fseventsd",
        "site-packages", "__pycache__", ".venv", "venv",
    ])

    private let maxDepth: Int

    public init(maxDepth: Int = 5) {
        self.maxDepth = maxDepth
    }

    public func scan(home: URL) -> AsyncStream<SystemScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                // One spelling of every path (/var and /private/var are the same place), or grouping breaks.
                let root = home.resolvingSymlinksInPath()
                var walker = Walker(maxDepth: maxDepth, home: root)
                walker.walk(root, depth: 0) { folders, repos in
                    continuation.yield(.progress(folders: folders, repos: repos))
                }
                continuation.yield(.finished(Self.group(walker.repos, home: root)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Walker {
        let maxDepth: Int
        let home: URL
        var repos: [URL] = []
        var visited = 0

        mutating func walk(_ directory: URL, depth: Int, progress: (Int, Int) -> Void) {
            if Task.isCancelled { return }
            visited += 1
            if visited % 40 == 0 || depth == 0 { progress(visited, repos.count) }

            let dotGit = directory.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if directory != home, FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    repos.append(directory.resolvingSymlinksInPath())
                    progress(visited, repos.count)
                } else if let linked = RepoScanner.mainRoot(ofLinkedWorktreeAt: dotGit) {
                    let main = linked.resolvingSymlinksInPath()
                    if !repos.contains(main) { repos.append(main) }
                    progress(visited, repos.count)
                }
                return
            }
            guard depth < maxDepth,
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [])
            else { return }
            for child in children.sorted(by: { $0.path < $1.path }) {
                let name = child.lastPathComponent
                if SystemScanner.skipNames.contains(name) { continue }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                // Hidden folders are skipped except a repository's own, which is checked above, so dot-folders
                // like ~/.config are never entered.
                if name.hasPrefix(".") { continue }
                walk(child, depth: depth + 1, progress: progress)
            }
        }
    }

    /// One entry per folder to scan: repositories grouped by the folder holding them, nested groups folded into
    /// the folder above, and repositories sitting directly in the home folder offered one by one.
    static func group(_ repos: [URL], home: URL) -> [DiscoveredFolder] {
        var groups: [String: [URL]] = [:]
        for repo in repos {
            let parent = repo.deletingLastPathComponent().standardizedFileURL
            let key = parent == home ? repo.path : parent.path
            groups[key, default: []].append(repo)
        }
        // Shortest paths first, so an ancestor group is kept before the groups inside it.
        var kept: [(path: String, repos: [URL])] = []
        for (path, members) in groups.sorted(by: { $0.key.count < $1.key.count }) {
            if let index = kept.firstIndex(where: { path.hasPrefix($0.path + "/") && $0.path != home.path }) {
                kept[index].repos += members
            } else {
                kept.append((path, members))
            }
        }
        return kept
            .map { entry in
                DiscoveredFolder(
                    path: URL(fileURLWithPath: entry.path, isDirectory: true),
                    repoCount: entry.repos.count,
                    sampleNames: entry.repos.map(\.lastPathComponent).sorted().prefix(3).map { $0 })
            }
            .sorted { $0.repoCount != $1.repoCount ? $0.repoCount > $1.repoCount : $0.path.path < $1.path.path }
    }
}

/// The usual places people keep projects, for one-click setup.
public struct FolderSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { path.path }
    public let path: URL
    public let repoCount: Int
    public var hasRepos: Bool { repoCount > 0 }

    public init(path: URL, repoCount: Int) {
        self.path = path
        self.repoCount = repoCount
    }
}

public enum FolderSuggestions {
    static let names = [
        "Developer", "Projects", "Code", "dev", "src", "workspace", "work", "repos",
        "Documents/GitHub", "Documents/Projects", "Sites", "GitHub",
    ]

    /// The suggested folders that exist, in a stable order, each with a quick repository count.
    public static func find(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [FolderSuggestion] {
        var found: [FolderSuggestion] = []
        for name in names {
            let url = home.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
            else { continue }
            let count = await Task.detached(priority: .utility) {
                RepoScanner().findRepos(in: [url], maxDepth: 3).count
            }.value
            found.append(FolderSuggestion(path: url, repoCount: count))
        }
        return found
    }
}

import Foundation

/// Finds main repository roots under user-chosen folders. Synchronous: call from a background task.
public struct RepoScanner: Sendable {
    public static let defaultSkipNames: Set<String> = [
        "node_modules", "Pods", "DerivedData", "vendor", "build", "dist", "target",
    ]

    private let skipNames: Set<String>
    private let excludePatterns: [String]

    /// `excludePatterns` are directory-name globs (for example `legacy-*`) that are never entered.
    public init(skipNames: Set<String> = RepoScanner.defaultSkipNames, excludePatterns: [String] = []) {
        self.skipNames = skipNames
        self.excludePatterns = excludePatterns
    }

    private func isExcluded(_ name: String) -> Bool {
        skipNames.contains(name) || excludePatterns.contains { GlobMatcher.matches(pattern: $0, name: name) }
    }

    public func findRepos(in roots: [URL], maxDepth: Int) -> [URL] {
        var found = Set<String>()
        for root in roots {
            walk(root.canonicalized, depth: 0, maxDepth: maxDepth, into: &found)
        }
        return found.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func walk(_ directory: URL, depth: Int, maxDepth: Int, into found: inout Set<String>) {
        let fileManager = FileManager.default
        let dotGit = directory.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                found.insert(directory.path)
            } else if let main = Self.mainRoot(ofLinkedWorktreeAt: dotGit) {
                found.insert(main.path)
            }
            // Repos are never descended into; submodules (".git" file under /modules/) are ignored.
            return
        }
        guard depth < maxDepth,
            let children = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }
        for child in children where !isExcluded(child.lastPathComponent) {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                walk(child, depth: depth + 1, maxDepth: maxDepth, into: &found)
            }
        }
    }

    /// A linked worktree's `.git` file reads `gitdir: /main/.git/worktrees/<name>`.
    static func mainRoot(ofLinkedWorktreeAt dotGitFile: URL) -> URL? {
        guard let text = try? String(contentsOf: dotGitFile, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let rawPath = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = URL(
            fileURLWithPath: rawPath, relativeTo: dotGitFile.deletingLastPathComponent()
        ).standardizedFileURL
        guard let range = gitDir.path.range(of: "/.git/worktrees/") else { return nil }
        let root = URL(fileURLWithPath: String(gitDir.path[..<range.lowerBound]), isDirectory: true)
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
            ? root.canonicalized : nil
    }
}

import Foundation

enum WorktreeMetadata {
    /// When a linked worktree was created: the creation date of its entry in the repository's git directory
    /// (`.git/worktrees/<name>`), else of the folder itself. Nil when neither can be read.
    static func createdAt(ofWorktreeAt worktree: URL) -> Date? {
        let dotGit = worktree.appendingPathComponent(".git")
        if let text = try? String(contentsOf: dotGit, encoding: .utf8),
            let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:")
        {
            let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            let gitDir = URL(fileURLWithPath: raw, relativeTo: worktree).standardizedFileURL
            if let date = creationDate(of: gitDir) { return date }
        }
        return creationDate(of: worktree)
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}

import Foundation

/// What Lopper found about the command line tools it relies on.
struct ToolStatus: Equatable, Sendable {
    enum GitHubCLI: Equatable, Sendable {
        case notInstalled
        case installed(version: String, path: String)
    }

    var gitVersion: String?
    var gitHubCLI: GitHubCLI

    static let unknown = ToolStatus(gitVersion: nil, gitHubCLI: .notInstalled)

    /// `git version 2.54.0 (Apple Git-157)` gives `2.54.0 (Apple Git-157)`.
    static func parseGitVersion(_ output: String) -> String? {
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "git version "
        guard line.hasPrefix(prefix) else { return nil }
        let version = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return version.isEmpty ? nil : version
    }

    /// `gh version 2.98.0 (2026-08-20)` gives `2.98.0`.
    static func parseGitHubVersion(_ output: String) -> String? {
        let line = output.split(separator: "\n").first.map(String.init) ?? ""
        let prefix = "gh version "
        guard line.hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
    }
}

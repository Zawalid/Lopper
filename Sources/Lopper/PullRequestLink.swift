import Foundation

public enum PullRequestLink {
    /// The pull request page for a GitHub remote, or nil for any other host or an unparsable remote.
    /// Accepts `git@github.com:owner/repo(.git)`, `https://github.com/owner/repo(.git)` and `ssh://git@github.com/owner/repo`.
    public static func url(remoteURL: String?, number: Int) -> URL? {
        guard let remote = remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else {
            return nil
        }
        var path: String
        if remote.hasPrefix("git@github.com:") {
            path = String(remote.dropFirst("git@github.com:".count))
        } else if let range = remote.range(of: "github.com/") {
            path = String(remote[range.upperBound...])
        } else {
            return nil
        }
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])/pull/\(number)")
    }
}

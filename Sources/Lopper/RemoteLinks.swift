import Foundation

/// Web pages for a repository's GitHub remote. Any other host, or a remote that cannot be parsed, gives nil:
/// a link that points at the wrong place is worse than no link.
public enum RemoteLinks {
    /// `https://github.com/owner/repo`. Accepts `git@github.com:owner/repo(.git)`,
    /// `https://github.com/owner/repo(.git)` and `ssh://git@github.com/owner/repo`.
    public static func repository(remoteURL: String?) -> URL? {
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
        return URL(string: "https://github.com/\(parts[0])/\(parts[1])")
    }

    public static func branch(remoteURL: String?, name: String) -> URL? {
        page(remoteURL, "tree/" + escapedRef(name))
    }

    public static func compare(remoteURL: String?, base: String, branch: String) -> URL? {
        page(remoteURL, "compare/\(escapedRef(base))...\(escapedRef(branch))")
    }

    public static func commit(remoteURL: String?, hash: String) -> URL? {
        page(remoteURL, "commit/" + hash)
    }

    public static func pullRequest(remoteURL: String?, number: Int) -> URL? {
        page(remoteURL, "pull/\(number)")
    }

    private static func page(_ remoteURL: String?, _ path: String) -> URL? {
        repository(remoteURL: remoteURL).flatMap { URL(string: $0.absoluteString + "/" + path) }
    }

    /// Branch names keep their slashes; everything else that is not safe in a URL path is escaped.
    private static func escapedRef(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?/"))) ?? String($0) }
            .joined(separator: "/")
    }
}

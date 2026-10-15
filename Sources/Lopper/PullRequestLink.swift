import Foundation

public enum PullRequestLink {
    /// The pull request page for a GitHub remote, or nil for any other host or an unparsable remote.
    /// Accepts `git@github.com:owner/repo(.git)`, `https://github.com/owner/repo(.git)` and `ssh://git@github.com/owner/repo`.
    public static func url(remoteURL: String?, number: Int) -> URL? {
        RemoteLinks.pullRequest(remoteURL: remoteURL, number: number)
    }
}

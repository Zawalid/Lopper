import Foundation

public enum GlobMatcher {
    /// Shell-style match where `*` also crosses `/`, so `release/*` matches `release/1.2/hotfix`.
    public static func matches(pattern: String, name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }
}

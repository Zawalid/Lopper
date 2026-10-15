import Foundation

extension URL {
    /// The path as git reports it: symlinks resolved with `realpath`, including `/var` -> `/private/var`.
    /// Foundation's `resolvingSymlinksInPath()` deliberately strips `/private`, so it cannot be used here.
    ///
    /// A path that does not exist (a worktree folder that was deleted) is resolved through its deepest
    /// existing ancestor, so it still compares equal to the path git recorded for it.
    public var canonicalized: URL {
        var existing = path
        var missing: [String] = []
        while !existing.isEmpty, existing != "/" {
            if let resolved = Self.realPath(existing) {
                let full = missing.reversed().reduce(resolved) { ($0 as NSString).appendingPathComponent($1) }
                return URL(fileURLWithPath: full, isDirectory: hasDirectoryPath)
            }
            missing.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return self
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

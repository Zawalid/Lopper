import Foundation

extension URL {
    /// The path as git reports it: symlinks resolved with `realpath`, including `/var` -> `/private/var`.
    /// Foundation's `resolvingSymlinksInPath()` deliberately strips `/private`, so it cannot be used here.
    public var canonicalized: URL {
        guard let resolved = realpath(path, nil) else { return self }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: hasDirectoryPath)
    }
}

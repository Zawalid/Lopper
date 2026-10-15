import Foundation

public struct DiskUsage: Sendable, Equatable {
    /// Allocated bytes on disk for everything under the directory.
    public let total: Int64
    /// The part of `total` that sits under a disposable directory (node_modules, build output, ...).
    public let disposable: Int64
    /// Newest modification time of any regular file outside disposable folders and `.git`: the last time
    /// anyone edited something here. Nil when there is no such file.
    public let newestModification: Date?

    public init(total: Int64, disposable: Int64, newestModification: Date? = nil) {
        self.total = total
        self.disposable = disposable
        self.newestModification = newestModification
    }
}

public enum SizeCalculator {
    /// Measures a directory off the cooperative thread pool. Symlinks are not followed.
    /// `excluding` lists folders inside `directory` that are not counted, such as worktrees nested in a main folder.
    public static func measure(
        _ directory: URL, disposableNames: Set<String>, excluding: [URL] = []
    ) async -> DiskUsage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: measureSync(directory, disposableNames: disposableNames, excluding: excluding))
            }
        }
    }

    static func measureSync(_ directory: URL, disposableNames: Set<String>, excluding: [URL] = []) -> DiskUsage {
        let skipped = Set(excluding.map { $0.standardizedFileURL.path })
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [])
        else { return DiskUsage(total: 0, disposable: 0) }
        let baseCount = directory.standardizedFileURL.pathComponents.count
        var total: Int64 = 0
        var disposable: Int64 = 0
        var newest: Date?
        for case let url as URL in enumerator {
            if !skipped.isEmpty, skipped.contains(url.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let size = values.totalFileAllocatedSize
            else { continue }
            total += Int64(size)
            // Includes the file name itself, so a disposable file (.DS_Store, *.tsbuildinfo) counts too.
            let relative = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            if relative.contains(where: { GitParsers.matchesDisposable($0, disposableNames) }) {
                disposable += Int64(size)
            } else if relative.last != ".git", let modified = values.contentModificationDate {
                if newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        return DiskUsage(total: total, disposable: disposable, newestModification: newest)
    }
}

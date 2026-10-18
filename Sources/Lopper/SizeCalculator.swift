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

/// A flag a walk on another thread can read, set when the task that asked for the measurement is cancelled.
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }
}

public enum SizeCalculator {
    /// How many folders are measured at once. Walking a project with a million files keeps a core busy, so a handful at
    /// a time was enough to slow the whole Mac down while hundreds of repositories were measured.
    public static let concurrentMeasurements = 2

    /// Measures a directory off the cooperative thread pool. Symlinks are not followed.
    /// `excluding` lists folders inside `directory` that are not counted, such as worktrees nested in a main folder.
    /// When the calling task is cancelled the walk stops within a moment and returns what it had counted so far, which
    /// the caller must discard.
    public static func measure(
        _ directory: URL, disposableNames: Set<String>, excluding: [URL] = []
    ) async -> DiskUsage {
        let flag = StopFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(
                        returning: measureSync(
                            directory, disposableNames: disposableNames, excluding: excluding,
                            shouldStop: { flag.isStopped }))
                }
            }
        } onCancel: {
            flag.stop()
        }
    }

    static func measureSync(
        _ directory: URL, disposableNames: Set<String>, excluding: [URL] = [], shouldStop: () -> Bool = { false }
    ) -> DiskUsage {
        let skipped = Set(excluding.map { $0.standardizedFileURL.path })
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .contentModificationDateKey]
        let keySet = Set(keys)
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [])
        else { return DiskUsage(total: 0, disposable: 0) }
        var total: Int64 = 0
        var disposable: Int64 = 0
        var newest: Date?
        // The walk is depth first, so everything deeper than a disposable entry is inside it. Tracking that is far
        // cheaper than splitting every file's path to look for a disposable name, which dominated the cost.
        var disposableLevel = Int.max
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited & 0xFF == 0, shouldStop() { break }
            let level = enumerator.level
            if level <= disposableLevel { disposableLevel = .max }
            if !skipped.isEmpty, skipped.contains(url.standardizedFileURL.path) {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent
            // Includes the file name itself, so a disposable file (.DS_Store, *.tsbuildinfo) counts too.
            if disposableLevel == .max, GitParsers.matchesDisposable(name, disposableNames) { disposableLevel = level }
            guard let values = try? url.resourceValues(forKeys: keySet),
                values.isRegularFile == true,
                let size = values.totalFileAllocatedSize
            else { continue }
            total += Int64(size)
            if disposableLevel != .max {
                disposable += Int64(size)
            } else if name != ".git", let modified = values.contentModificationDate {
                if newest.map({ modified > $0 }) ?? true { newest = modified }
            }
        }
        return DiskUsage(total: total, disposable: disposable, newestModification: newest)
    }
}

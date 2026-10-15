import Foundation

public struct DiskUsage: Sendable, Equatable {
    /// Allocated bytes on disk for everything under the directory.
    public let total: Int64
    /// The part of `total` that sits under a disposable directory (node_modules, build output, ...).
    public let disposable: Int64

    public init(total: Int64, disposable: Int64) {
        self.total = total
        self.disposable = disposable
    }
}

public enum SizeCalculator {
    /// Measures a directory off the cooperative thread pool. Symlinks are not followed.
    public static func measure(_ directory: URL, disposableNames: Set<String>) async -> DiskUsage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: measureSync(directory, disposableNames: disposableNames))
            }
        }
    }

    static func measureSync(_ directory: URL, disposableNames: Set<String>) -> DiskUsage {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [])
        else { return DiskUsage(total: 0, disposable: 0) }
        let baseCount = directory.standardizedFileURL.pathComponents.count
        var total: Int64 = 0
        var disposable: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.isRegularFile == true,
                let size = values.totalFileAllocatedSize
            else { continue }
            total += Int64(size)
            // Includes the file name itself, so a disposable file (.DS_Store, *.tsbuildinfo) counts too.
            let relative = url.standardizedFileURL.pathComponents.dropFirst(baseCount)
            if relative.contains(where: { GitParsers.matchesDisposable($0, disposableNames) }) {
                disposable += Int64(size)
            }
        }
        return DiskUsage(total: total, disposable: disposable)
    }
}

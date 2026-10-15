import Foundation

/// How much room a volume has, for the bar at the top of the Disk page.
public struct VolumeSpace: Sendable, Equatable {
    public let total: Int64
    public let available: Int64

    public var used: Int64 { total - available }

    public init(total: Int64, available: Int64) {
        self.total = total
        self.available = available
    }

    public static func read(at url: URL) -> VolumeSpace? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return VolumeSpace(total: Int64(total), available: min(available, Int64(total)))
    }
}

/// Folders tools keep in the home folder that they rebuild on their own. The catalog is a short, spelled-out
/// list: Lopper clears a path only when it is exactly one of these.
public enum DeveloperCaches {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let path: URL
        public let regenerate: String
    }

    /// History groups these under one made-up repository name.
    public static let historyRepoPath = "/Developer caches"

    public static func catalog(home: URL) -> [Entry] {
        func entry(_ name: String, _ relative: String, _ how: String) -> Entry {
            Entry(name: name, path: home.appendingPathComponent(relative, isDirectory: true), regenerate: how)
        }
        return [
            entry("Xcode build data", "Library/Developer/Xcode/DerivedData", "your next Xcode build"),
            entry("Simulator caches", "Library/Developer/CoreSimulator/Caches", "the next simulator launch"),
            entry("Homebrew downloads", "Library/Caches/Homebrew", "the next brew install"),
            entry("CocoaPods cache", "Library/Caches/CocoaPods", "pod install"),
            entry("npm cache", ".npm/_cacache", "the next npm install"),
            entry("Yarn cache", "Library/Caches/Yarn", "the next yarn install"),
            entry("pnpm store", "Library/pnpm/store", "pnpm install"),
            entry("pip cache", "Library/Caches/pip", "the next pip install"),
            entry("uv cache", ".cache/uv", "the next uv sync"),
            entry("Cargo downloads", ".cargo/registry/cache", "the next cargo build"),
            entry("Gradle caches", ".gradle/caches", "your next gradle run"),
        ]
    }

    /// Caches that exist and hold something, biggest first, as artifacts so the same sheet clears them.
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> [DiskArtifact] {
        var found: [DiskArtifact] = []
        for entry in catalog(home: home) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory else { continue }
            let usage = await SizeCalculator.measure(entry.path, disposableNames: [])
            guard usage.total > 0 else { continue }
            found.append(DiskArtifact(
                path: entry.path, name: entry.name, kind: .cache, bytes: usage.total,
                newestModification: usage.newestModification, projectDirectory: entry.path.deletingLastPathComponent(),
                checkoutRoot: home, repoRoot: URL(fileURLWithPath: historyRepoPath), location: .developerCache,
                removal: .offered(regenerate: entry.regenerate)))
        }
        return found.sorted { $0.bytes > $1.bytes }
    }
}

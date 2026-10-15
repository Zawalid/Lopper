import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var roots: [URL]
    public var scanDepth: Int
    public var protectedPatterns: [String]
    public var staleDays: Int
    public var disposableNames: [String]
    public var trashRetentionDays: Int
    public var defaultBranchOverrides: [String: String]
    /// Extra throwaway names or patterns per repository path, for project-specific files such as a
    /// copied `.env.test` or a test-generated `media/` folder.
    public var repoDisposableNames: [String: [String]]

    public static let defaultProtectedPatterns = ["main", "master", "develop", "release/*", "hotfix/*"]
    public static let defaultDisposableNames = [
        "node_modules", ".next", ".nuxt", ".turbo", ".cache", "dist", "build", "out",
        "target", "DerivedData", "Pods", ".gradle", ".venv", "__pycache__",
        ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox", ".eslintcache", ".parcel-cache",
        ".svelte-kit", ".vite", ".angular", "coverage",
        ".DS_Store", "Thumbs.db", "*.tsbuildinfo", "*.pyc",
    ]

    public init(
        roots: [URL] = [],
        scanDepth: Int = 4,
        protectedPatterns: [String] = Settings.defaultProtectedPatterns,
        staleDays: Int = 30,
        disposableNames: [String] = Settings.defaultDisposableNames,
        trashRetentionDays: Int = 30,
        defaultBranchOverrides: [String: String] = [:],
        repoDisposableNames: [String: [String]] = [:]
    ) {
        self.roots = roots
        self.scanDepth = scanDepth
        self.protectedPatterns = protectedPatterns
        self.staleDays = staleDays
        self.disposableNames = disposableNames
        self.trashRetentionDays = trashRetentionDays
        self.defaultBranchOverrides = defaultBranchOverrides
        self.repoDisposableNames = repoDisposableNames
    }

    /// Decodes with defaults for every key, so a file written by an older build still loads and a new
    /// release never silently resets what the user configured.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        roots = try container.decodeIfPresent([URL].self, forKey: .roots) ?? defaults.roots
        scanDepth = try container.decodeIfPresent(Int.self, forKey: .scanDepth) ?? defaults.scanDepth
        protectedPatterns = try container.decodeIfPresent([String].self, forKey: .protectedPatterns)
            ?? defaults.protectedPatterns
        staleDays = try container.decodeIfPresent(Int.self, forKey: .staleDays) ?? defaults.staleDays
        disposableNames = try container.decodeIfPresent([String].self, forKey: .disposableNames)
            ?? defaults.disposableNames
        trashRetentionDays = try container.decodeIfPresent(Int.self, forKey: .trashRetentionDays)
            ?? defaults.trashRetentionDays
        defaultBranchOverrides = try container.decodeIfPresent([String: String].self, forKey: .defaultBranchOverrides)
            ?? defaults.defaultBranchOverrides
        repoDisposableNames = try container.decodeIfPresent([String: [String]].self, forKey: .repoDisposableNames)
            ?? defaults.repoDisposableNames
    }

    public static func load(from url: URL) -> Settings {
        guard let data = try? Data(contentsOf: url),
            let settings = try? JSONDecoder().decode(Settings.self, from: data)
        else { return Settings() }
        return settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public var disposableSet: Set<String> { Set(disposableNames) }

    /// Global allowlist plus this repository's own additions.
    public func disposableSet(for repoRoot: URL) -> Set<String> {
        disposableSet.union(repoDisposableNames[repoRoot.path] ?? [])
    }
}

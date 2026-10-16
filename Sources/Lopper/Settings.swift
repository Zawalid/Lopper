import Foundation

/// One folder the user asked Lopper to look in.
public struct FolderSetting: Codable, Sendable, Equatable, Hashable {
    public var path: URL
    public var isEnabled: Bool
    /// Directory names or globs that are never entered while looking for repositories in this folder.
    public var excludePatterns: [String]

    public init(path: URL, isEnabled: Bool = true, excludePatterns: [String] = []) {
        self.path = path
        self.isEnabled = isEnabled
        self.excludePatterns = excludePatterns
    }

    private enum CodingKeys: String, CodingKey { case path, isEnabled, excludePatterns }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(URL.self, forKey: .path)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        excludePatterns = try container.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
    }
}

/// Settings that apply to one repository only.
public struct RepoOverrides: Codable, Sendable, Equatable {
    /// Replaces the detected default branch.
    public var defaultBranch: String?
    /// Replaces the global protected patterns for this repository; nil means inherit.
    public var protectedPatterns: [String]?
    /// Added to the global throwaway names for this repository.
    public var disposableNames: [String]
    /// The repository is hidden: never scanned, never listed.
    public var isIgnored: Bool

    public init(
        defaultBranch: String? = nil, protectedPatterns: [String]? = nil,
        disposableNames: [String] = [], isIgnored: Bool = false
    ) {
        self.defaultBranch = defaultBranch
        self.protectedPatterns = protectedPatterns
        self.disposableNames = disposableNames
        self.isIgnored = isIgnored
    }

    private enum CodingKeys: String, CodingKey { case defaultBranch, protectedPatterns, disposableNames, isIgnored }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultBranch = try container.decodeIfPresent(String.self, forKey: .defaultBranch)
        protectedPatterns = try container.decodeIfPresent([String].self, forKey: .protectedPatterns)
        disposableNames = try container.decodeIfPresent([String].self, forKey: .disposableNames) ?? []
        isIgnored = try container.decodeIfPresent(Bool.self, forKey: .isIgnored) ?? false
    }

    var isEmpty: Bool {
        defaultBranch == nil && protectedPatterns == nil && disposableNames.isEmpty && !isIgnored
    }
}

public struct Settings: Sendable, Equatable {
    /// Rules only ever suggest. They find things worth cleaning and say so; nothing is removed without the
    /// person reviewing it first.
    public struct Rules: Codable, Sendable, Equatable {
        public struct Rule: Codable, Sendable, Equatable {
            public var isEnabled: Bool
            public var days: Int

            public init(isEnabled: Bool = false, days: Int) {
                self.isEnabled = isEnabled
                self.days = Rule.clamped(days)
            }

            static func clamped(_ days: Int) -> Int { min(max(days, 1), 365) }

            fileprivate enum CodingKeys: String, CodingKey { case isEnabled, days }

            public init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
                // The default is filled in by `Rules`, which knows which rule this is.
                days = Rule.clamped(try container.decodeIfPresent(Int.self, forKey: .days) ?? 0)
            }
        }

        /// Offer to clear generated folders in projects nobody has edited for this many days.
        public var untouchedFolders: Rule
        /// Offer to remove branches that are merged and have had no commit for this many days.
        public var oldMergedBranches: Rule

        public init(
            untouchedFolders: Rule = Rule(days: 30), oldMergedBranches: Rule = Rule(days: 14)
        ) {
            self.untouchedFolders = untouchedFolders
            self.oldMergedBranches = oldMergedBranches
        }

        private enum CodingKeys: String, CodingKey { case untouchedFolders, oldMergedBranches }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = Rules()
            func rule(_ key: CodingKeys, fallback: Rule) throws -> Rule {
                guard var rule = try container.decodeIfPresent(Rule.self, forKey: key) else { return fallback }
                // A rule written without `days` keeps its own default, not the clamp's minimum.
                let nested = try? container.nestedContainer(keyedBy: Rule.CodingKeys.self, forKey: key)
                if nested?.contains(.days) != true { rule.days = fallback.days }
                return rule
            }
            untouchedFolders = try rule(.untouchedFolders, fallback: defaults.untouchedFolders)
            oldMergedBranches = try rule(.oldMergedBranches, fallback: defaults.oldMergedBranches)
        }
    }

    /// The schema this build reads and writes. Older files are migrated in memory on load.
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var folders: [FolderSetting]
    public var scanDepth: Int
    public var protectedPatterns: [String]
    public var staleDays: Int
    public var disposableNames: [String]
    public var trashRetentionDays: Int
    /// How long an agent worktree must be untouched before it counts as finished. Zero disables the grace.
    public var agentFinishedGraceMinutes: Int
    /// Per-repository settings, keyed by the repository's path.
    public var repos: [String: RepoOverrides]
    public var rules = Rules()
    /// Top-level keys written by a newer build, preserved untouched.
    public var unknownKeys: [String: JSONValue]

    public static let defaultAgentFinishedGraceMinutes = 120
    public static let defaultProtectedPatterns = ["main", "master", "develop", "release/*", "hotfix/*"]
    public static let defaultDisposableNames = [
        "node_modules", ".next", ".nuxt", ".turbo", ".cache", "dist", "build", "out",
        "target", "DerivedData", "Pods", ".gradle", ".venv", "__pycache__",
        ".pytest_cache", ".ruff_cache", ".mypy_cache", ".tox", ".eslintcache", ".parcel-cache",
        ".svelte-kit", ".vite", ".angular", "coverage",
        ".DS_Store", "Thumbs.db", "*.tsbuildinfo", "*.pyc",
    ]

    public init(
        folders: [FolderSetting],
        scanDepth: Int = 4,
        protectedPatterns: [String] = Settings.defaultProtectedPatterns,
        staleDays: Int = 30,
        disposableNames: [String] = Settings.defaultDisposableNames,
        trashRetentionDays: Int = 30,
        repos: [String: RepoOverrides] = [:],
        agentFinishedGraceMinutes: Int = Settings.defaultAgentFinishedGraceMinutes
    ) {
        self.schemaVersion = Settings.currentSchemaVersion
        self.folders = folders
        self.scanDepth = scanDepth
        self.protectedPatterns = protectedPatterns
        self.staleDays = staleDays
        self.disposableNames = disposableNames
        self.trashRetentionDays = trashRetentionDays
        self.repos = repos
        self.agentFinishedGraceMinutes = agentFinishedGraceMinutes
        self.unknownKeys = [:]
    }

    /// Source-compatible initializer used throughout the app and tests: folders given as plain paths.
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
        self.init(
            folders: roots.map { FolderSetting(path: $0) }, scanDepth: scanDepth,
            protectedPatterns: protectedPatterns, staleDays: staleDays, disposableNames: disposableNames,
            trashRetentionDays: trashRetentionDays)
        self.defaultBranchOverrides = defaultBranchOverrides
        self.repoDisposableNames = repoDisposableNames
    }

    // MARK: Compatibility views

    /// The enabled folders' paths. Setting it keeps the flags of folders that remain, adds new ones enabled,
    /// and drops the rest.
    public var roots: [URL] {
        get { folders.filter(\.isEnabled).map(\.path) }
        set {
            let existing = Dictionary(folders.map { ($0.path.path, $0) }, uniquingKeysWith: { first, _ in first })
            var result: [FolderSetting] = []
            for url in newValue {
                result.append(existing[url.path] ?? FolderSetting(path: url))
            }
            // Paused folders are not part of `roots`, so setting roots must not forget them.
            let kept = Set(result.map(\.path.path))
            result += folders.filter { !$0.isEnabled && !kept.contains($0.path.path) }
            folders = result
        }
    }

    public var defaultBranchOverrides: [String: String] {
        get { repos.compactMapValues(\.defaultBranch) }
        set {
            for key in repos.keys where newValue[key] == nil { repos[key]?.defaultBranch = nil }
            for (path, branch) in newValue { repos[path, default: RepoOverrides()].defaultBranch = branch }
            prune()
        }
    }

    public var repoDisposableNames: [String: [String]] {
        get { repos.compactMapValues { $0.disposableNames.isEmpty ? nil : $0.disposableNames } }
        set {
            for key in repos.keys where newValue[key] == nil { repos[key]?.disposableNames = [] }
            for (path, names) in newValue { repos[path, default: RepoOverrides()].disposableNames = names }
            prune()
        }
    }

    private mutating func prune() {
        repos = repos.filter { !$0.value.isEmpty }
    }

    // MARK: Per-repository lookups

    public func defaultBranchOverride(for repoRoot: URL) -> String? {
        repos[repoRoot.path]?.defaultBranch
    }

    public func protectedPatterns(for repoRoot: URL) -> [String] {
        repos[repoRoot.path]?.protectedPatterns ?? protectedPatterns
    }

    public func isIgnored(_ repoRoot: URL) -> Bool {
        repos[repoRoot.path]?.isIgnored ?? false
    }

    public var disposableSet: Set<String> { Set(disposableNames) }

    /// Global allowlist plus this repository's own additions.
    public func disposableSet(for repoRoot: URL) -> Set<String> {
        disposableSet.union(repos[repoRoot.path]?.disposableNames ?? [])
    }

    /// A copy with `name` added to this repository's throwaway list (no duplicates).
    public func addingRepoDisposable(_ name: String, for repoRoot: URL) -> Settings {
        var copy = self
        var overrides = copy.repos[repoRoot.path] ?? RepoOverrides()
        if !overrides.disposableNames.contains(name) { overrides.disposableNames.append(name) }
        copy.repos[repoRoot.path] = overrides
        return copy
    }

    /// Exclude patterns of every enabled folder, for the repository scanner.
    public var excludePatterns: [String] {
        Array(Set(folders.filter(\.isEnabled).flatMap(\.excludePatterns))).sorted()
    }

    // MARK: Change rules

    /// True when switching from `previous` to this value changes what Lopper finds or how it decides, so
    /// the app must scan again. Retention, the stale threshold and unknown keys do not.
    public func requiresRescan(comparedTo previous: Settings) -> Bool {
        folders.filter(\.isEnabled) != previous.folders.filter(\.isEnabled)
            || scanDepth != previous.scanDepth
            || protectedPatterns != previous.protectedPatterns
            || disposableNames != previous.disposableNames
            || repos != previous.repos
    }

    // MARK: Persistence

    /// Loads, migrating and recovering as needed. Use `SettingsLoader` when the outcome matters.
    public static func load(from url: URL) -> Settings {
        SettingsLoader.load(from: url).settings
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: Codable

private struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension Settings: Codable {
    private static let knownKeys: Set<String> = [
        "schemaVersion", "folders", "scanDepth", "protectedPatterns", "staleDays", "disposableNames",
        "trashRetentionDays", "repos", "agentFinishedGraceMinutes", "rules",
    ]
    /// Version 1 keys, read for migration and never written again.
    private static let legacyKeys: Set<String> = ["roots", "defaultBranchOverrides", "repoDisposableNames"]

    /// Decodes with defaults for every key, so a file written by any earlier build still loads and a new
    /// release never silently resets what the user configured.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let defaults = Settings()
        func value<T: Decodable>(_ key: String, as type: T.Type) throws -> T? {
            try container.decodeIfPresent(type, forKey: AnyKey(key))
        }

        let version = try value("schemaVersion", as: Int.self) ?? 1
        schemaVersion = max(version, Settings.currentSchemaVersion)
        scanDepth = try value("scanDepth", as: Int.self) ?? defaults.scanDepth
        protectedPatterns = try value("protectedPatterns", as: [String].self) ?? defaults.protectedPatterns
        staleDays = try value("staleDays", as: Int.self) ?? defaults.staleDays
        disposableNames = try value("disposableNames", as: [String].self) ?? defaults.disposableNames
        trashRetentionDays = try value("trashRetentionDays", as: Int.self) ?? defaults.trashRetentionDays
        agentFinishedGraceMinutes = max(
            0, try value("agentFinishedGraceMinutes", as: Int.self) ?? defaults.agentFinishedGraceMinutes)

        rules = try value("rules", as: Rules.self) ?? Rules()

        if let folders = try value("folders", as: [FolderSetting].self) {
            self.folders = folders
        } else {
            self.folders = (try value("roots", as: [URL].self) ?? []).map { FolderSetting(path: $0) }
        }

        var repos = try value("repos", as: [String: RepoOverrides].self) ?? [:]
        for (path, branch) in try value("defaultBranchOverrides", as: [String: String].self) ?? [:] {
            repos[path, default: RepoOverrides()].defaultBranch = branch
        }
        for (path, names) in try value("repoDisposableNames", as: [String: [String]].self) ?? [:] {
            var merged = repos[path, default: RepoOverrides()].disposableNames
            for name in names where !merged.contains(name) { merged.append(name) }
            repos[path, default: RepoOverrides()].disposableNames = merged
        }
        self.repos = repos.filter { !$0.value.isEmpty }

        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys
        where !Settings.knownKeys.contains(key.stringValue) && !Settings.legacyKeys.contains(key.stringValue) {
            unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unknownKeys = unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        // Unknown keys first, so a known key always wins if a newer build ever reuses a name.
        for (key, value) in unknownKeys { try container.encode(value, forKey: AnyKey(key)) }
        try container.encode(schemaVersion, forKey: AnyKey("schemaVersion"))
        try container.encode(folders, forKey: AnyKey("folders"))
        try container.encode(scanDepth, forKey: AnyKey("scanDepth"))
        try container.encode(protectedPatterns, forKey: AnyKey("protectedPatterns"))
        try container.encode(staleDays, forKey: AnyKey("staleDays"))
        try container.encode(disposableNames, forKey: AnyKey("disposableNames"))
        try container.encode(trashRetentionDays, forKey: AnyKey("trashRetentionDays"))
        try container.encode(repos, forKey: AnyKey("repos"))
        try container.encode(agentFinishedGraceMinutes, forKey: AnyKey("agentFinishedGraceMinutes"))
        try container.encode(rules, forKey: AnyKey("rules"))
    }
}

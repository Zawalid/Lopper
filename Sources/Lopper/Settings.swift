import Foundation

public struct Settings: Codable, Sendable, Equatable {
    public var roots: [URL]
    public var scanDepth: Int
    public var protectedPatterns: [String]
    public var staleDays: Int
    public var disposableNames: [String]
    public var trashRetentionDays: Int
    public var defaultBranchOverrides: [String: String]

    public static let defaultProtectedPatterns = ["main", "master", "develop", "release/*", "hotfix/*"]
    public static let defaultDisposableNames = [
        "node_modules", ".next", ".nuxt", ".turbo", ".cache", "dist", "build", "out",
        "target", "DerivedData", "Pods", ".gradle", ".venv", "__pycache__",
    ]

    public init(
        roots: [URL] = [],
        scanDepth: Int = 4,
        protectedPatterns: [String] = Settings.defaultProtectedPatterns,
        staleDays: Int = 30,
        disposableNames: [String] = Settings.defaultDisposableNames,
        trashRetentionDays: Int = 30,
        defaultBranchOverrides: [String: String] = [:]
    ) {
        self.roots = roots
        self.scanDepth = scanDepth
        self.protectedPatterns = protectedPatterns
        self.staleDays = staleDays
        self.disposableNames = disposableNames
        self.trashRetentionDays = trashRetentionDays
        self.defaultBranchOverrides = defaultBranchOverrides
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
}

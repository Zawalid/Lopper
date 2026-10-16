import Foundation

public enum SettingsLoadOutcome: Sendable, Equatable {
    /// There was no file; defaults are in use and nothing was written.
    case created
    case loaded
    /// An older file was upgraded in memory. `backup` is a byte-for-byte copy of the original.
    case migrated(backup: URL)
    /// The file could not be read. `backup` holds its bytes; defaults are in use.
    case recoveredFromCorruption(backup: URL)
    /// The file was written by a newer build. Known fields are used, unknown ones preserved; `backup` is a copy.
    case newerVersion(backup: URL)
    /// The file exists but could not be read at all (permissions, a transient error). Defaults are in use, nothing was
    /// copied, and nothing must be saved over it: the person's settings may be perfectly fine.
    case unreadable
}

public struct SettingsLoadResult: Sendable, Equatable {
    public let settings: Settings
    public let outcome: SettingsLoadOutcome
}

/// Reads the settings file without ever being the reason a user loses their configuration.
public enum SettingsLoader {
    public static func load(from url: URL, now: Date = Date()) -> SettingsLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SettingsLoadResult(settings: Settings(), outcome: .created)
        }
        guard let data = try? Data(contentsOf: url) else {
            return SettingsLoadResult(settings: Settings(), outcome: .unreadable)
        }
        guard let settings = try? JSONDecoder().decode(Settings.self, from: data) else {
            return recovered(from: url, now: now)
        }
        if !settings.damagedKeys.isEmpty {
            // Most of the file is fine, so it is used; the parts that were not are named by `damagedKeys`.
            return recovered(from: url, now: now, keeping: settings)
        }
        let version = fileVersion(in: data)
        if version > Settings.currentSchemaVersion {
            let backup = backupURL(for: url, label: "v\(version)-backup")
            copyIfMissing(url, to: backup)
            return SettingsLoadResult(settings: settings, outcome: .newerVersion(backup: backup))
        }
        if version < Settings.currentSchemaVersion {
            let backup = backupURL(for: url, label: "v\(version)-backup")
            copyIfMissing(url, to: backup)
            return SettingsLoadResult(settings: settings, outcome: .migrated(backup: backup))
        }
        return SettingsLoadResult(settings: settings, outcome: .loaded)
    }

    private static func recovered(from url: URL, now: Date, keeping settings: Settings? = nil) -> SettingsLoadResult {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let backup = backupURL(for: url, label: "broken-\(formatter.string(from: now))")
        copyIfMissing(url, to: backup)
        return SettingsLoadResult(settings: settings ?? Settings(), outcome: .recoveredFromCorruption(backup: backup))
    }

    /// The `schemaVersion` the file declares; files from before versioning count as 1.
    private static func fileVersion(in data: Data) -> Int {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = object["schemaVersion"] as? Int
        else { return 1 }
        return version
    }

    private static func backupURL(for url: URL, label: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(label)")
    }

    /// Never overwrites an existing backup: the first copy is the original.
    private static func copyIfMissing(_ source: URL, to destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }
}

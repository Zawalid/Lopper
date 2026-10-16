import Foundation

/// Whether Lopper can read a folder it was asked to look in.
public enum FolderAccess: Equatable, Sendable {
    case ok
    /// macOS or file permissions refuse the read: Desktop, Documents, Downloads, external drives.
    case denied
    /// The folder was moved, deleted, or sits on a drive that is not connected.
    case missing
    /// The path exists but is a file.
    case notAFolder

    public var isReadable: Bool { self == .ok }
}

public enum FolderProbe {
    /// Opens the folder the way a scan would. Cheap, and exact: the error code says why it failed, which
    /// `isReadableFile` does not (it also cannot see the macOS privacy prompts).
    public static func check(_ folder: URL) -> FolderAccess {
        guard let handle = opendir(folder.path) else {
            switch errno {
            case ENOENT: return .missing
            case ENOTDIR: return .notAFolder
            default: return .denied
            }
        }
        closedir(handle)
        return .ok
    }

    public static func check(_ folders: [URL]) -> [String: FolderAccess] {
        Dictionary(folders.map { ($0.canonicalized.path, check($0)) }, uniquingKeysWith: { first, _ in first })
    }
}

public enum GitAvailability {
    /// True when the Apple command line tools (or Xcode) are installed. `/usr/bin/git` is a stub without
    /// them, and running it opens Apple's installer, so this asks `xcode-select` first and never runs git.
    public static func isInstalled(
        developerDirectory: () -> String? = Self.activeDeveloperDirectory,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        guard let directory = developerDirectory() else { return false }
        return fileExists(directory + "/usr/bin/git")
    }

    public static func activeDeveloperDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

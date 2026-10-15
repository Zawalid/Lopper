import Foundation

/// Where Lopper keeps its own files: the settings file and the undo log.
public enum LopperSupport {
    /// `~/Library/Application Support/Lopper`, or the absolute folder named by `LOPPER_SUPPORT_DIR`. The override
    /// exists so tests and manual acceptance runs can use a throwaway folder and can never touch real settings
    /// or real undo history. A relative or empty value is ignored, so nothing is ever written next to the
    /// working directory by accident.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let override = environment["LOPPER_SUPPORT_DIR"], override.hasPrefix("/") {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lopper", isDirectory: true)
    }
}

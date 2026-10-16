import Foundation
import Lopper

/// The words for the setup screens, kept apart from the views so they can be tested.
enum SetupGuide {
    static func title(for issue: SetupIssue, folders: [(FolderSetting, FolderAccess)]) -> String {
        switch issue {
        case .gitMissing: "Lopper needs git"
        case .foldersUnreadable:
            folders.contains { $0.1 == .denied } ? "Lopper cannot open your folders" : "Your folders are gone"
        }
    }

    static func message(for issue: SetupIssue, folders: [(FolderSetting, FolderAccess)]) -> String {
        switch issue {
        case .gitMissing:
            "git comes with Apple's command line tools. Install them, then come back and Lopper picks up where it left off."
        case .foldersUnreadable:
            if folders.contains(where: { $0.1 == .denied }) {
                "macOS blocks apps from reading some folders until you allow it. Allow Lopper in Privacy settings, then check again. Lopper only reads them."
            } else {
                "The folders you chose were moved, deleted, or sit on a drive that is not connected. Reconnect the drive, or choose where your projects live now."
            }
        }
    }

    static func reason(for access: FolderAccess) -> String {
        switch access {
        case .ok: "Readable"
        case .denied: "No access"
        case .missing: "Not found"
        case .notAFolder: "Not a folder"
        }
    }

    /// One line for the banner shown when only some folders are blocked.
    static func partialNotice(_ blocked: [FolderSetting]) -> String {
        let names = blocked.prefix(2).map { $0.path.lastPathComponent }.joined(separator: " and ")
        let rest = blocked.count - 2
        let list = rest > 0 ? "\(names) and \(rest) more" : names
        return blocked.count == 1
            ? "Lopper cannot read \(list), so it was skipped."
            : "Lopper cannot read \(list), so they were skipped."
    }
}

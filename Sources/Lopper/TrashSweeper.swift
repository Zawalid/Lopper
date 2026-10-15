import Foundation

/// Folders Lopper moved to the Trash still use disk until the Trash is emptied. This finds them and, when the
/// person asks, deletes exactly those, never anything else in the Trash.
public struct TrashSweeper: Sendable {
    public struct Totals: Sendable, Equatable {
        public var folders = 0
        public var bytes: Int64 = 0
    }

    public struct Failure: Sendable, Equatable {
        public let record: UndoRecord
        public let message: String

        public init(record: UndoRecord, message: String) {
            self.record = record
            self.message = message
        }
    }

    public struct Result: Sendable {
        public let deleted: [UndoRecord]
        public let failures: [Failure]

        public init(deleted: [UndoRecord], failures: [Failure]) {
            self.deleted = deleted
            self.failures = failures
        }
    }

    private let undoLog: UndoLog

    public init(undoLog: UndoLog) {
        self.undoLog = undoLog
    }

    /// Cleared folders that are still sitting in the Trash.
    public static func pending(in records: [UndoRecord]) -> [UndoRecord] {
        records.filter { record in
            guard record.action == .trashFolder, record.status == .completed,
                  let path = record.trashedPath else { return false }
            // `fileExists` follows links; a dangling link is not something worth reporting.
            return (try? FileManager.default.attributesOfItem(atPath: path)) != nil
        }
    }

    public static func totals(of records: [UndoRecord]) -> Totals {
        Totals(folders: records.count, bytes: records.reduce(0) { $0 + ($1.bytes ?? 0) })
    }

    /// A path counts as "in the Trash" only when one of its folders is a Trash folder: `~/.Trash`, or
    /// `<volume>/.Trashes/<uid>`.
    static func isInTrash(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard components.count > 2 else { return false }
        let folders = components.dropLast()
        return folders.contains(".Trash") || folders.contains(".Trashes")
    }

    public func deleteForGood(_ records: [UndoRecord], now: Date = Date()) async -> Result {
        var deleted: [UndoRecord] = []
        var failures: [Failure] = []
        for record in records {
            guard record.action == .trashFolder, let path = record.trashedPath else {
                failures.append(Failure(record: record, message: "This is not a folder Lopper trashed"))
                continue
            }
            guard Self.isInTrash(path) else {
                failures.append(Failure(record: record, message: "This is not inside the Trash, so it was left alone"))
                continue
            }
            do {
                // Removing a link removes the link itself; its target is never touched.
                try FileManager.default.removeItem(atPath: path)
            } catch {
                if (try? FileManager.default.attributesOfItem(atPath: path)) != nil {
                    failures.append(Failure(record: record, message: UserMessage.describe(error)))
                    continue
                }
            }
            var updated = record
            updated.status = .expired
            updated.detail = "Deleted from the Trash"
            try? await undoLog.append(updated)
            deleted.append(updated)
        }
        return Result(deleted: deleted, failures: failures)
    }
}

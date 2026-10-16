import Foundation

public enum UndoAction: String, Codable, Sendable, Equatable {
    case deleteBranch
    case removeWorktree
    /// A generated folder (node_modules, .next, ...) moved to the macOS Trash.
    case trashFolder
}

public enum UndoStatus: String, Codable, Sendable, Equatable {
    case pending
    case completed
    case failed
    case restored
    case expired
}

public struct UndoRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let repoPath: String
    public let action: UndoAction
    /// Branch deleted, or the branch checked out in the removed worktree (nil when detached).
    public let branch: String?
    public let tip: String
    public let upstream: String?
    public let worktreePath: String?
    public let trashRef: String
    public var status: UndoStatus
    public var detail: String?
    /// Records created by one user action share a batch, so the whole action can be undone at once.
    public let batchID: UUID?
    /// Why removal was safe at the time, in the words shown in the app ("Merged via PR #54"). Absent in records
    /// written before this field existed.
    public let reason: String?
    /// How much disk the removal freed, when the caller knew. Absent for branches and for older records.
    public var bytes: Int64?
    /// Where a trashed folder ended up inside the Trash, so it can be put back. Only set for `.trashFolder`.
    public var trashedPath: String?
    /// Who the trashed folder was (device and inode), so a different folder that later takes the same name in the Trash
    /// is never mistaken for it. Absent in records written before this field existed.
    public var trashedIdentity: String?

    public init(
        id: UUID = UUID(), timestamp: Date, repoPath: String, action: UndoAction, branch: String?,
        tip: String, upstream: String?, worktreePath: String?, trashRef: String,
        status: UndoStatus, detail: String? = nil, batchID: UUID? = nil,
        reason: String? = nil, bytes: Int64? = nil, trashedPath: String? = nil, trashedIdentity: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.repoPath = repoPath
        self.action = action
        self.branch = branch
        self.tip = tip
        self.upstream = upstream
        self.worktreePath = worktreePath
        self.trashRef = trashRef
        self.status = status
        self.detail = detail
        self.batchID = batchID
        self.reason = reason
        self.bytes = bytes
        self.trashedPath = trashedPath
        self.trashedIdentity = trashedIdentity
    }

    /// `device:inode` of what is at `path` now, without following links. Nil when nothing is there.
    public static func identity(ofItemAt path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber
        else { return nil }
        return "\(device):\(inode)"
    }
}

/// Append-only JSON Lines log. A record's status changes by appending a new line with the same id;
/// reading keeps the latest line per id.
public actor UndoLog {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL { url(in: LopperSupport.directory()) }

    static func url(in directory: URL) -> URL {
        directory.appendingPathComponent("undo-log.jsonl")
    }

    /// Appends one line. The file is opened with O_APPEND, so two processes (the app and `lop`) can never overwrite
    /// each other, locked while writing, and a half-written last line left by a crash gets a newline first so the new
    /// record is never glued onto it. Throws when the line could not be written in full: callers rely on "did not
    /// throw" meaning "recorded".
    public func append(_ record: UndoRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)

        let descriptor = open(url.path, O_RDWR | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }

        let size = lseek(descriptor, 0, SEEK_END)
        if size > 0 {
            var last: UInt8 = 0x0A
            if pread(descriptor, &last, 1, size - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Latest state of every record, newest first. A line this build cannot read is skipped, but a record whose latest
    /// line is unreadable (a newer build changed its state) is left out entirely rather than shown in an older state:
    /// showing it as restorable again could mislead.
    public func all() -> [UndoRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var latest: [UUID: UndoRecord] = [:]
        for line in data.split(separator: 0x0A) {
            if let record = try? decoder.decode(UndoRecord.self, from: Data(line)) {
                latest[record.id] = record
            } else if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                let text = object["id"] as? String, let id = UUID(uuidString: text) {
                latest.removeValue(forKey: id)
            }
        }
        return latest.values.sorted { $0.timestamp > $1.timestamp }
    }
}

import Foundation

public enum UndoAction: String, Codable, Sendable, Equatable {
    case deleteBranch
    case removeWorktree
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

    public init(
        id: UUID = UUID(), timestamp: Date, repoPath: String, action: UndoAction, branch: String?,
        tip: String, upstream: String?, worktreePath: String?, trashRef: String,
        status: UndoStatus, detail: String? = nil, batchID: UUID? = nil,
        reason: String? = nil, bytes: Int64? = nil
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

    public func append(_ record: UndoRecord) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(record)
        line.append(0x0A)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: url, options: .atomic)
        }
    }

    /// Latest state of every record, newest first.
    public func all() -> [UndoRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var latest: [UUID: UndoRecord] = [:]
        for line in data.split(separator: 0x0A) {
            if let record = try? decoder.decode(UndoRecord.self, from: Data(line)) {
                latest[record.id] = record
            }
        }
        return latest.values.sorted { $0.timestamp > $1.timestamp }
    }
}

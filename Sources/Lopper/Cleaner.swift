import Foundation

public enum CleanOutcome: Sendable, Equatable {
    case removed(UndoRecord)
    case skipped(reason: String)
    case failed(message: String)
}

public enum RestoreOutcome: Sendable, Equatable {
    case restored(UndoRecord)
    case failed(message: String)
}

/// Performs destructive actions. Every action re-verifies the item against fresh repository state,
/// writes a keep-alive ref and an undo record, and only then runs the git command.
public struct Cleaner: Sendable {
    private let git: GitRunner
    private let inspector: RepoInspector
    private let undoLog: UndoLog
    private let gate: RepoGate
    /// Test seam: runs after re-verification and before any destructive step, to simulate a change
    /// made by someone else in that window.
    var afterVerifyHook: (@Sendable () async -> Void)?

    public init(git: GitRunner = GitRunner(), inspector: RepoInspector, undoLog: UndoLog, gate: RepoGate = RepoGate()) {
        self.git = git
        self.inspector = inspector
        self.undoLog = undoLog
        self.gate = gate
    }

    // MARK: Delete branch

    /// `approved` is the verdict the user saw. The action runs only if the item is still at least as safe.
    public func deleteBranch(
        repoRoot: URL, name: String, approved: VerdictKind, batchID: UUID? = nil, now: Date = Date()
    ) async -> CleanOutcome {
        await serialized(repoRoot) {
            let found: BranchEntry?
            do { found = try await inspector.inspectBranch(repoRoot: repoRoot, name: name) } catch {
                return .failed(message: "Could not read this repository. \(UserMessage.describe(error))")
            }
            guard let entry = found else {
                return .skipped(reason: "Branch \(name) no longer exists")
            }
            if let skip = Self.skipReason(verdict: entry.verdict, approved: approved) {
                return .skipped(reason: skip)
            }
            await afterVerifyHook?()
            let trashRef = Self.trashRef(now: now, label: name)
            var record = UndoRecord(
                timestamp: now, repoPath: repoRoot.path, action: .deleteBranch, branch: name,
                tip: entry.tip, upstream: entry.upstream, worktreePath: nil,
                trashRef: trashRef, status: .pending, batchID: batchID, reason: entry.evidence.summary)
            return await execute(record: &record, repoRoot: repoRoot) {
                try await deleteBranchIfUnchanged(name: name, expectedTip: entry.tip, repoRoot: repoRoot)
            }
        }
    }

    // MARK: Remove worktree

    /// `refuseFolderOnlyWork` is for callers that promised the user nothing exists only in the folder (the
    /// Agents page): the fresh check then also refuses uncommitted, untracked and ignored files, which a Review
    /// verdict alone would let through even though removing the folder deletes them.
    public func removeWorktree(
        repoRoot: URL, path: URL, approved: VerdictKind, refuseFolderOnlyWork: Bool = false,
        batchID: UUID? = nil, bytes: Int64? = nil, now: Date = Date()
    ) async -> CleanOutcome {
        await serialized(repoRoot) {
            let found: WorktreeEntry?
            do { found = try await inspector.inspectWorktree(repoRoot: repoRoot, path: path) } catch {
                return .failed(message: "Could not read this repository. \(UserMessage.describe(error))")
            }
            guard let entry = found else {
                return .skipped(reason: "Worktree \(path.path) no longer exists")
            }
            if entry.isMain { return .skipped(reason: "The main working directory is never removed") }
            if let skip = Self.skipReason(verdict: entry.verdict, approved: approved) {
                return .skipped(reason: skip)
            }
            if refuseFolderOnlyWork,
                entry.status.isDirty || !entry.status.extraFiles.isEmpty || entry.operationInProgress
                    || entry.verdict.reasons.contains(.worktreeUnreadable)
            {
                return .skipped(reason: "Work that exists only in this folder appeared after you reviewed it")
            }
            await afterVerifyHook?()
            let label = entry.branch ?? "detached-\(entry.head.prefix(8))"
            var record = UndoRecord(
                timestamp: now, repoPath: repoRoot.path, action: .removeWorktree, branch: entry.branch,
                tip: entry.head, upstream: nil, worktreePath: entry.path.path,
                trashRef: Self.trashRef(now: now, label: label), status: .pending, batchID: batchID,
                reason: entry.evidence.summary, bytes: bytes)
            let folderGone = entry.isPrunable && !FileManager.default.fileExists(atPath: entry.path.path)
            return await execute(record: &record, repoRoot: repoRoot) {
                if folderGone {
                    // Nothing on disk is left to lose: dropping the registration is all that remains.
                    return try await git.runChecked(["worktree", "prune"], in: repoRoot)
                }
                // The worktree must still be at the commit that was verified: anything committed since
                // then (a detached HEAD has no branch to keep it) would be orphaned by the removal.
                let current = try await git.runChecked(["rev-parse", "HEAD"], in: entry.path)
                guard current == entry.head else { throw CleanError.movedAfterVerification(entry.path.path) }
                // A detached HEAD has no branch to keep its commits. Give them one before the folder goes,
                // and take it back if git then refuses the removal, so a refusal leaves nothing behind.
                var savedRef: String?
                if entry.branch == nil && entry.verdict.kind != .safe {
                    let name = Self.savedBranchName(forWorktreeAt: entry.path, head: entry.head)
                    let ref = "refs/heads/\(name)"
                    let existing = try await git.run(["rev-parse", "--verify", "--quiet", ref], in: repoRoot)
                    if existing.succeeded {
                        // Someone (an earlier removal) already saved this commit under this name: keep it and
                        // never roll it back. A different commit under the name is never overwritten.
                        let at = existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard at == entry.head else { throw CleanError.savedBranchTaken(name) }
                    } else {
                        // The empty old value makes the update create-only.
                        try await git.runChecked(["update-ref", ref, entry.head, ""], in: repoRoot)
                        savedRef = ref
                    }
                }
                do {
                    // Never --force: git itself refuses to remove a worktree with local changes.
                    return try await git.runChecked(["worktree", "remove", entry.path.path], in: repoRoot)
                } catch {
                    if let savedRef {
                        _ = try? await git.run(["update-ref", "-d", savedRef, entry.head], in: repoRoot)
                    }
                    throw error
                }
            }
        }
    }

    /// Drops registrations whose folder is gone. Loses nothing: branches and commits are untouched.
    public func pruneWorktreeRegistrations(repoRoot: URL) async throws {
        try await gate.run(key: repoRoot.path) {
            _ = try await git.runChecked(["worktree", "prune"], in: repoRoot)
        }
    }

    // MARK: Restore

    public func restore(_ record: UndoRecord, now: Date = Date()) async -> RestoreOutcome {
        guard record.status == .completed else {
            return .failed(message: "Only completed removals can be restored (status: \(record.status.rawValue))")
        }
        let repoRoot = URL(fileURLWithPath: record.repoPath)
        do {
            let outcome: RestoreOutcome = try await gate.run(key: repoRoot.path) {
                switch record.action {
                case .deleteBranch:
                    let name = try await restoreBranch(record, in: repoRoot)
                    return try await finishRestore(record, detail: "Restored branch \(name)", repoRoot: repoRoot)
                case .removeWorktree:
                    try await restoreWorktree(record, in: repoRoot)
                    return try await finishRestore(
                        record, detail: "Restored worktree \(record.worktreePath ?? "")", repoRoot: repoRoot)
                case .trashFolder:
                    let path = try restoreFolder(record)
                    return try await finishRestore(record, detail: "Put back \(path)", repoRoot: repoRoot)
                }
            }
            return outcome
        } catch {
            return .failed(message: UserMessage.describe(error))
        }
    }

    /// Restores every completed removal of one batch. Branches come back first so that worktrees
    /// removed in the same batch can be re-attached to them.
    public func restoreBatch(_ batchID: UUID, now: Date = Date()) async -> [RestoreOutcome] {
        let records = await undoLog.all().filter { $0.batchID == batchID && $0.status == .completed }
        let ordered = records.filter { $0.action == .deleteBranch }
            + records.filter { $0.action == .removeWorktree }
            + records.filter { $0.action == .trashFolder }
        var outcomes: [RestoreOutcome] = []
        for record in ordered {
            outcomes.append(await restore(record, now: now))
        }
        return outcomes
    }

    /// Removes keep-alive refs older than the retention window and marks their records expired.
    @discardableResult
    public func expireTrash(retentionDays: Int, now: Date = Date()) async -> Int {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays) * 86_400)
        var expired = 0
        for record in await undoLog.all() where record.status == .completed && record.timestamp < cutoff {
            if record.action == .trashFolder {
                // The Trash is the person's: only note that a folder is gone once it really is.
                if let trashed = record.trashedPath, FileManager.default.fileExists(atPath: trashed) { continue }
            } else {
                let repoRoot = URL(fileURLWithPath: record.repoPath)
                _ = try? await git.run(["update-ref", "-d", record.trashRef], in: repoRoot)
            }
            var updated = record
            updated.status = .expired
            try? await undoLog.append(updated)
            expired += 1
        }
        return expired
    }

    // MARK: Internals

    private func serialized(_ repoRoot: URL, _ body: @escaping @Sendable () async -> CleanOutcome) async -> CleanOutcome {
        do {
            return try await gate.run(key: repoRoot.path) { await body() }
        } catch {
            return .failed(message: UserMessage.describe(error))
        }
    }

    static func skipReason(verdict: Verdict, approved: VerdictKind) -> String? {
        if verdict.kind == .protected {
            return "Protected: " + verdict.reasons.map(\.text).joined(separator: "; ")
        }
        if verdict.kind > approved {
            return "Verdict changed since it was approved (\(approved.rawValue) -> \(verdict.kind.rawValue)): "
                + verdict.reasons.map(\.text).joined(separator: "; ")
        }
        return nil
    }

    /// Branch name that keeps the commits of a detached worktree reachable once its folder is gone.
    /// Stable for one commit, ASCII only, and free of anything git rejects in a ref name.
    public static func savedBranchName(forWorktreeAt path: URL, head: String) -> String {
        var cleaned = ""
        var lastWasDash = true
        // Fold accents first: macOS hands back decomposed names, which would otherwise leave stray dashes.
        let folded = path.lastPathComponent.folding(options: .diacriticInsensitive, locale: nil)
        for scalar in folded.unicodeScalars {
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "_")
            if allowed {
                cleaned.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                cleaned.append("-")
                lastWasDash = true
            }
        }
        while cleaned.hasSuffix("-") { cleaned.removeLast() }
        if cleaned.isEmpty { cleaned = "worktree" }
        return "lopper/saved/\(cleaned)-\(head.prefix(8))"
    }

    static func trashRef(now: Date, label: String) -> String {
        "refs/lopper/trash/\(Int(now.timeIntervalSince1970))/\(label)"
    }

    /// Order matters: keep-alive ref, then undo record, then the destructive command.
    private func execute(
        record: inout UndoRecord, repoRoot: URL, command: () async throws -> String
    ) async -> CleanOutcome {
        do {
            try await git.runChecked(["update-ref", record.trashRef, record.tip], in: repoRoot)
        } catch {
            return .failed(message: "Nothing was changed. \(UserMessage.describe(error))")
        }
        do {
            try await undoLog.append(record)
        } catch {
            _ = try? await git.run(["update-ref", "-d", record.trashRef], in: repoRoot)
            return .failed(message: "Nothing was changed because the undo log could not be written.")
        }
        do {
            _ = try await command()
            record.status = .completed
            try? await undoLog.append(record)
            return .removed(record)
        } catch {
            record.status = .failed
            record.detail = String(describing: error)
            try? await undoLog.append(record)
            return .failed(message: UserMessage.describe(error))
        }
    }

    /// Deletes `refs/heads/<name>` only while it still points at `expectedTip` and no worktree has it
    /// checked out. The final `update-ref -d <ref> <old>` is a compare-and-delete, so a commit that
    /// lands between verification and deletion can never be orphaned.
    private func deleteBranchIfUnchanged(name: String, expectedTip: String, repoRoot: URL) async throws -> String {
        let ref = "refs/heads/\(name)"
        let probe = try await git.runChecked(
            ["for-each-ref", "--format=%(objectname) %(worktreepath)", ref], in: repoRoot)
        let parts = probe.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == expectedTip else { throw CleanError.movedAfterVerification(name) }
        if parts.count > 1 { throw CleanError.checkedOut(parts[1]) }
        try await git.runChecked(["update-ref", "-d", ref, expectedTip], in: repoRoot)
        // Deleting through the branch command also drops tracking configuration; update-ref does not.
        _ = try? await git.run(["config", "--remove-section", "branch.\(name)"], in: repoRoot)
        return ""
    }

    private func restoreBranch(_ record: UndoRecord, in repoRoot: URL) async throws -> String {
        let base = record.branch ?? "restored-\(record.tip.prefix(8))"
        var name = base
        let exists = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"], in: repoRoot)
        if exists.succeeded { name = base + "-restored" }
        try await git.runChecked(["branch", name, record.tip], in: repoRoot)
        if let upstream = record.upstream {
            let remote = try await git.run(
                ["rev-parse", "--verify", "--quiet", "refs/remotes/\(upstream)"], in: repoRoot)
            if remote.succeeded {
                _ = try await git.run(["branch", "--set-upstream-to=\(upstream)", name], in: repoRoot)
            }
        }
        return name
    }

    private func restoreWorktree(_ record: UndoRecord, in repoRoot: URL) async throws {
        guard let path = record.worktreePath else {
            throw CleanError.restoreBlocked("the record has no worktree path")
        }
        if FileManager.default.fileExists(atPath: path) {
            throw CleanError.restoreBlocked("\(path) already exists")
        }
        guard let branch = record.branch else {
            try await git.runChecked(["worktree", "add", "--detach", path, record.tip], in: repoRoot)
            return
        }
        let exists = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)
        if exists.succeeded {
            try await git.runChecked(["worktree", "add", path, branch], in: repoRoot)
        } else {
            try await git.runChecked(["worktree", "add", "-b", branch, path, record.tip], in: repoRoot)
        }
    }

    /// Moves a trashed folder back where it came from. Never replaces something that has appeared there since.
    private func restoreFolder(_ record: UndoRecord) throws -> String {
        guard let original = record.worktreePath, let trashed = record.trashedPath else {
            throw CleanError.restoreBlocked("the record does not say where the folder was")
        }
        let manager = FileManager.default
        guard manager.fileExists(atPath: trashed) else {
            throw CleanError.restoreBlocked("it is no longer in the Trash")
        }
        if manager.fileExists(atPath: original) {
            throw CleanError.restoreBlocked("\(original) already exists")
        }
        let parent = URL(fileURLWithPath: original).deletingLastPathComponent().path
        guard manager.fileExists(atPath: parent) else {
            throw CleanError.restoreBlocked("the folder it was in no longer exists")
        }
        try manager.moveItem(atPath: trashed, toPath: original)
        return original
    }

    private func finishRestore(_ record: UndoRecord, detail: String, repoRoot: URL) async throws -> RestoreOutcome {
        if !record.trashRef.isEmpty {
            _ = try? await git.run(["update-ref", "-d", record.trashRef], in: repoRoot)
        }
        var updated = record
        updated.status = .restored
        updated.detail = detail
        try await undoLog.append(updated)
        return .restored(updated)
    }
}

/// Why an action was refused at the last moment, after the verdict had already been approved.
enum CleanError: Error, Equatable {
    case movedAfterVerification(String)
    case checkedOut(String)
    case restoreBlocked(String)
    case savedBranchTaken(String)
}

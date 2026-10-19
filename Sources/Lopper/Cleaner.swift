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
    private let trash: TrashProvider
    /// Where Lopper keeps its copy of git's record of a worktree whose folder went to the Trash.
    private let registrationBackups: URL
    /// Test seam: runs after re-verification and before any destructive step, to simulate a change
    /// made by someone else in that window.
    var afterVerifyHook: (@Sendable () async -> Void)?

    public init(
        git: GitRunner = GitRunner(), inspector: RepoInspector, undoLog: UndoLog, gate: RepoGate = RepoGate(),
        trash: TrashProvider = SystemTrash(), registrationBackups: URL = Cleaner.defaultRegistrationBackups
    ) {
        self.git = git
        self.inspector = inspector
        self.undoLog = undoLog
        self.gate = gate
        self.trash = trash
        self.registrationBackups = registrationBackups
    }

    public static var defaultRegistrationBackups: URL {
        LopperSupport.directory().appendingPathComponent("worktree-records", isDirectory: true)
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
            return await execute(record: &record, repoRoot: repoRoot) { _ in
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
            if folderGone {
                // A folder that is missing together with the one it sat in is usually a drive that is not connected,
                // not a deleted worktree: its files may be intact. A locked one is held by the person who locked it.
                let parent = entry.path.deletingLastPathComponent().path
                guard FileManager.default.fileExists(atPath: parent) else {
                    return .skipped(reason: "The folder is missing and so is the one it was in. Its drive may not be connected")
                }
                if entry.isLocked { return .skipped(reason: "The worktree is locked") }
            }
            return await execute(record: &record, repoRoot: repoRoot) { _ in
                if !folderGone {
                    // The worktree must still be at the commit that was verified: anything committed since
                    // then (a detached HEAD has no branch to keep it) would be orphaned by the removal.
                    let current = try await git.runChecked(["rev-parse", "HEAD"], in: entry.path)
                    guard current == entry.head else { throw CleanError.movedAfterVerification(entry.path.path) }
                }
                // A detached HEAD has no branch to keep its commits. Give them one before the folder goes,
                // and take it back if git then refuses the removal, so a refusal leaves nothing behind.
                let savedRef = try await saveDetachedHead(
                    path: entry.path, head: entry.head, branch: entry.branch, isSafe: entry.verdict.kind == .safe,
                    repoRoot: repoRoot)
                do {
                    if folderGone {
                        // Nothing on disk is left to lose. Only this worktree's registration goes: `git worktree prune`
                        // would also drop every other missing worktree, including ones holding commits no branch has.
                        try await removeRegistration(of: entry.path, repoRoot: repoRoot)
                        return ""
                    }
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

    /// For a worktree whose folder holds changes git refuses to discard. Nothing is deleted: the whole folder moves to
    /// the macOS Trash, git's record of the worktree is dropped (its branch stays), and History can put both back.
    /// Meant for one worktree at a time, after the person has seen the files. It checks everything the normal removal
    /// does and refuses a locked or protected worktree, one with an operation half done, and one with another
    /// worktree inside it.
    public func removeWorktreeKeepingCopy(
        repoRoot: URL, path: URL, approved: VerdictKind, batchID: UUID? = nil, bytes: Int64? = nil, now: Date = Date()
    ) async -> CleanOutcome {
        await serialized(repoRoot) {
            let found: WorktreeEntry?
            do { found = try await inspector.inspectWorktree(repoRoot: repoRoot, path: path) } catch {
                return .failed(message: "Could not read this repository. \(UserMessage.describe(error))")
            }
            guard let entry = found else { return .skipped(reason: "Worktree \(path.path) no longer exists") }
            if entry.isMain { return .skipped(reason: "The main working directory is never removed") }
            if let skip = Self.skipReason(verdict: entry.verdict, approved: approved) { return .skipped(reason: skip) }
            if entry.isLocked { return .skipped(reason: "The worktree is locked") }
            if entry.operationInProgress {
                return .skipped(reason: "A rebase, merge or similar operation is half done in this folder")
            }
            if entry.verdict.reasons.contains(.worktreeUnreadable) {
                return .skipped(reason: "Lopper could not read this folder, so it was left alone")
            }
            guard !entry.isPrunable, FileManager.default.fileExists(atPath: entry.path.path) else {
                return .skipped(reason: "The folder is already gone, so there is nothing to keep")
            }
            if let inside = try? await worktrees(insideFolderOf: entry.path, repoRoot: repoRoot), !inside.isEmpty {
                return .skipped(reason: "Another worktree is inside this folder, so it was left alone")
            }
            await afterVerifyHook?()
            let label = entry.branch ?? "detached-\(entry.head.prefix(8))"
            var record = UndoRecord(
                timestamp: now, repoPath: repoRoot.path, action: .trashWorktree, branch: entry.branch,
                tip: entry.head, upstream: nil, worktreePath: entry.path.path,
                trashRef: Self.trashRef(now: now, label: label), status: .pending, batchID: batchID,
                reason: entry.evidence.summary, bytes: bytes)
            return await execute(record: &record, repoRoot: repoRoot) { record in
                let current = try await git.runChecked(["rev-parse", "HEAD"], in: entry.path)
                guard current == entry.head else { throw CleanError.movedAfterVerification(entry.path.path) }
                let savedRef = try await saveDetachedHead(
                    path: entry.path, head: entry.head, branch: entry.branch, isSafe: entry.verdict.kind == .safe,
                    repoRoot: repoRoot)
                let manager = FileManager.default
                var backupRoot: URL?
                do {
                    let registration = try await registrationFolder(of: entry.path, repoRoot: repoRoot)
                    // git's record holds the index and HEAD of this worktree. Without a copy, a restored folder
                    // would be a plain folder again, with its staged changes gone.
                    let root = registrationBackups.appendingPathComponent(record.id.uuidString, isDirectory: true)
                    backupRoot = root
                    try manager.createDirectory(at: root, withIntermediateDirectories: true)
                    let backup = root.appendingPathComponent(registration.lastPathComponent, isDirectory: true)
                    try manager.copyItem(at: registration, to: backup)
                    record.registrationBackup = backup.path

                    let identity = UndoRecord.identity(ofItemAt: entry.path.path)
                    let trashed = try trash.moveToTrash(entry.path)
                    record.trashedPath = trashed.path
                    record.trashedIdentity = identity
                    do {
                        try manager.removeItem(at: registration)
                    } catch {
                        // Nothing may be half done: the folder goes back where it was, and git's record is rebuilt
                        // from the copy, because a failed delete can still have removed some of its files.
                        try? manager.moveItem(at: trashed, to: entry.path)
                        Self.fillIn(registration, from: backup)
                        throw error
                    }
                    return ""
                } catch {
                    if let backupRoot { try? manager.removeItem(at: backupRoot) }
                    record.registrationBackup = nil
                    record.trashedPath = nil
                    record.trashedIdentity = nil
                    if let savedRef {
                        _ = try? await git.run(["update-ref", "-d", savedRef, entry.head], in: repoRoot)
                    }
                    throw error
                }
            }
        }
    }

    /// Copies back whatever of `source` is missing from `folder`, so a record that a failed delete left partly empty
    /// is whole again. Never overwrites a file that is still there.
    private static func fillIn(_ folder: URL, from source: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in (try? manager.contentsOfDirectory(atPath: source.path)) ?? [] {
            let destination = folder.appendingPathComponent(name)
            if !manager.fileExists(atPath: destination.path) {
                try? manager.copyItem(at: source.appendingPathComponent(name), to: destination)
            }
        }
    }

    /// Other registered worktrees whose folder is inside `folder`.
    private func worktrees(insideFolderOf folder: URL, repoRoot: URL) async throws -> [String] {
        let listing = try await git.runChecked(["worktree", "list", "--porcelain", "-z"], in: repoRoot)
        let prefix = folder.canonicalized.path + "/"
        return GitParsers.parseWorktreeList(listing).map(\.path).filter {
            URL(fileURLWithPath: $0).canonicalized.path.hasPrefix(prefix)
        }
    }

    /// Drops registrations whose folder is gone, one at a time, saving detached commits first. Loses nothing:
    /// branches and commits are untouched, and a detached head gets a branch before its registration goes.
    public func pruneWorktreeRegistrations(repoRoot: URL) async throws {
        try await gate.run(key: repoRoot.path) {
            let listing = try await git.runChecked(["worktree", "list", "--porcelain", "-z"], in: repoRoot)
            for entry in GitParsers.parseWorktreeList(listing) where entry.isPrunable && !entry.isLocked && !entry.isBare {
                let url = URL(fileURLWithPath: entry.path)
                guard !FileManager.default.fileExists(atPath: url.path),
                    FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path)
                else { continue }
                _ = try await saveDetachedHead(
                    path: url, head: entry.head, branch: entry.branch, isSafe: false, repoRoot: repoRoot)
                try await removeRegistration(of: url, repoRoot: repoRoot)
            }
        }
    }

    /// For a detached worktree whose commit no branch holds: a create-only branch at that commit. Returns the ref it
    /// made, so a failure later can take it back; nil when nothing was needed or an earlier removal already made it.
    private func saveDetachedHead(path: URL, head: String, branch: String?, isSafe: Bool, repoRoot: URL) async throws -> String? {
        guard branch == nil, !isSafe else { return nil }
        let name = Self.savedBranchName(forWorktreeAt: path, head: head)
        let ref = "refs/heads/\(name)"
        let existing = try await git.run(["rev-parse", "--verify", "--quiet", ref], in: repoRoot)
        if existing.succeeded {
            // Someone (an earlier removal) already saved this commit under this name: keep it and
            // never roll it back. A different commit under the name is never overwritten.
            let at = existing.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard at == head else { throw CleanError.savedBranchTaken(name) }
            return nil
        }
        // The empty old value makes the update create-only.
        try await git.runChecked(["update-ref", ref, head, ""], in: repoRoot)
        return ref
    }

    /// Deletes git's bookkeeping folder for exactly this worktree (`<common dir>/worktrees/<id>`), found through its
    /// `gitdir` file. Refuses when none matches, so a registration for another worktree is never taken by mistake.
    private func removeRegistration(of worktree: URL, repoRoot: URL) async throws {
        try FileManager.default.removeItem(at: try await registrationFolder(of: worktree, repoRoot: repoRoot))
    }

    private func registrationFolder(of worktree: URL, repoRoot: URL) async throws -> URL {
        let registrations = try await registrationsDirectory(repoRoot: repoRoot)
        let wanted = worktree.canonicalized.path
        let names = (try? FileManager.default.contentsOfDirectory(atPath: registrations.path)) ?? []
        for name in names {
            let folder = registrations.appendingPathComponent(name)
            guard let text = try? String(contentsOf: folder.appendingPathComponent("gitdir"), encoding: .utf8) else { continue }
            let recorded = URL(fileURLWithPath: text.trimmingCharacters(in: .whitespacesAndNewlines)).deletingLastPathComponent()
            if recorded.canonicalized.path == wanted || recorded.standardizedFileURL.path == worktree.standardizedFileURL.path {
                return folder
            }
        }
        throw CleanError.movedAfterVerification(worktree.path)
    }

    private func registrationsDirectory(repoRoot: URL) async throws -> URL {
        let common = try await git.runChecked(["rev-parse", "--git-common-dir"], in: repoRoot)
        let commonDirectory = (common.hasPrefix("/") ? URL(fileURLWithPath: common) : URL(fileURLWithPath: common, relativeTo: repoRoot))
            .standardizedFileURL
        return commonDirectory.appendingPathComponent("worktrees")
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
                case .trashWorktree:
                    let path = try await restoreTrashedWorktree(record, in: repoRoot)
                    return try await finishRestore(record, detail: "Restored worktree \(path)", repoRoot: repoRoot)
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
            + records.filter { $0.action == .trashWorktree }
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
        // A retention of zero or less, or a clock that jumped forward, must not wipe the safety net of recent removals.
        let cutoff = now.addingTimeInterval(-TimeInterval(max(retentionDays, 1)) * 86_400)
        var expired = 0
        for record in await undoLog.all()
        where record.status == .completed && record.timestamp < cutoff && record.timestamp <= now {
            // The Trash is the person's: only note that a folder is gone once it really is. Until then the entry can
            // still be restored, so everything it needs stays.
            if record.action == .trashFolder || record.action == .trashWorktree,
                let trashed = record.trashedPath, FileManager.default.fileExists(atPath: trashed) { continue }
            if record.action != .trashFolder {
                let repoRoot = URL(fileURLWithPath: record.repoPath)
                // Only Lopper's own keep-alive refs are ever deleted, whatever a damaged log says.
                if Self.isKeepAliveRef(record.trashRef) {
                    let deleted = try? await git.run(["update-ref", "-d", record.trashRef], in: repoRoot)
                    guard deleted?.succeeded == true else { continue }
                }
            }
            if record.action == .trashWorktree { removeRegistrationBackup(of: record) }
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

    /// True only for refs under Lopper's own namespace, so a tampered or damaged undo log can never make Lopper delete
    /// a branch or a tag.
    static func isKeepAliveRef(_ ref: String) -> Bool {
        ref.hasPrefix("refs/lopper/trash/") && !ref.contains("..")
    }

    static func trashRef(now: Date, label: String) -> String {
        "refs/lopper/trash/\(Int(now.timeIntervalSince1970))/\(label)"
    }

    /// Order matters: keep-alive ref, then undo record, then the destructive command.
    private func execute(
        record: inout UndoRecord, repoRoot: URL, command: (inout UndoRecord) async throws -> String
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
            _ = try await command(&record)
        } catch {
            record.status = .failed
            record.detail = String(describing: error)
            try? await undoLog.append(record)
            return .failed(message: UserMessage.describe(error))
        }
        // The removal happened. If the log cannot say so, say that plainly instead of reporting a clean success.
        record.status = .completed
        do {
            try await undoLog.append(record)
            return .removed(record)
        } catch {
            return .failed(message: "It was removed, but the history entry could not be saved, so Undo may not list it. "
                + "The commit is kept at \(record.trashRef): git branch <name> \(record.tip)")
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
        if let expected = record.trashedIdentity, UndoRecord.identity(ofItemAt: trashed) != expected {
            throw CleanError.restoreBlocked("something else is in the Trash under that name now")
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

    /// Puts a trashed worktree back: the folder returns to where it was, git's record returns from Lopper's copy, and
    /// the branch is checked out in it again. Every check that can fail runs before anything moves, and a failure
    /// after the move puts the folder back in the Trash.
    private func restoreTrashedWorktree(_ record: UndoRecord, in repoRoot: URL) async throws -> String {
        guard let original = record.worktreePath, let trashed = record.trashedPath,
            let backupPath = record.registrationBackup
        else { throw CleanError.restoreBlocked("the record does not say where the folder and its git record are") }
        let manager = FileManager.default
        let backup = URL(fileURLWithPath: backupPath)
        guard manager.fileExists(atPath: backup.path) else {
            throw CleanError.restoreBlocked("Lopper's saved copy of git's record is missing")
        }
        let slot = try await registrationsDirectory(repoRoot: repoRoot).appendingPathComponent(backup.lastPathComponent)
        if manager.fileExists(atPath: slot.path) {
            throw CleanError.restoreBlocked("git already has a worktree record with the same name")
        }
        if let branch = record.branch {
            let probe = try await git.runChecked(
                ["for-each-ref", "--format=%(worktreepath)", "refs/heads/\(branch)"], in: repoRoot)
            if !probe.isEmpty { throw CleanError.restoreBlocked("branch \(branch) is checked out in \(probe)") }
        }
        // The folder checks (still in the Trash, same folder, nothing at the old place) live with the move itself.
        _ = try restoreFolder(record)
        var madeBranch = false
        do {
            try manager.createDirectory(at: slot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try manager.copyItem(at: backup, to: slot)
            if let branch = record.branch {
                let exists = try await git.run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: repoRoot)
                if !exists.succeeded {
                    try await git.runChecked(["branch", branch, record.tip], in: repoRoot)
                    madeBranch = true
                }
            }
            _ = try? await git.run(["worktree", "repair", original], in: repoRoot)
            let listing = try await git.runChecked(["worktree", "list", "--porcelain", "-z"], in: repoRoot)
            let target = URL(fileURLWithPath: original).canonicalized.path
            guard GitParsers.parseWorktreeList(listing).contains(where: {
                URL(fileURLWithPath: $0.path).canonicalized.path == target
            }) else { throw CleanError.restoreBlocked("git did not take the worktree back") }
        } catch {
            try? manager.removeItem(at: slot)
            if madeBranch, let branch = record.branch {
                _ = try? await git.run(["update-ref", "-d", "refs/heads/\(branch)", record.tip], in: repoRoot)
            }
            try? manager.moveItem(atPath: original, toPath: trashed)
            throw error
        }
        removeRegistrationBackup(of: record)
        return original
    }

    private func removeRegistrationBackup(of record: UndoRecord) {
        guard let path = record.registrationBackup else { return }
        let root = URL(fileURLWithPath: path).deletingLastPathComponent()
        // Only ever a folder directly inside Lopper's own backup location, whatever a damaged log says.
        guard root.deletingLastPathComponent().standardizedFileURL.path == registrationBackups.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private func finishRestore(_ record: UndoRecord, detail: String, repoRoot: URL) async throws -> RestoreOutcome {
        if Self.isKeepAliveRef(record.trashRef) {
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

import Foundation

/// Where removed folders go. The app uses the macOS Trash so Finder's "Put Back" works too.
public protocol TrashProvider: Sendable {
    /// Moves `url` to the trash and returns where it ended up.
    func moveToTrash(_ url: URL) throws -> URL
}

public struct SystemTrash: TrashProvider {
    public init() {}

    public func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let trashed = result as URL? else {
            throw CleanError.restoreBlocked("the system did not say where the folder went")
        }
        return trashed
    }
}

/// Moves generated folders to the Trash. Like every destructive action it re-verifies against the disk and git
/// at the last moment, and writes an undo record before and after.
public struct ArtifactCleaner: Sendable {
    private let undoLog: UndoLog
    private let trash: TrashProvider
    private let git: GitRunner
    private let gate: RepoGate
    private let home: URL

    public init(
        undoLog: UndoLog, trash: TrashProvider = SystemTrash(), git: GitRunner = GitRunner(),
        gate: RepoGate = RepoGate(), home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.undoLog = undoLog
        self.trash = trash
        self.git = git
        self.gate = gate
        self.home = home
    }

    public func clear(
        _ artifact: DiskArtifact, names: Set<String>, batchID: UUID? = nil, now: Date = Date()
    ) async -> CleanOutcome {
        do {
            return try await gate.run(key: artifact.repoRoot.path) {
                if artifact.location == .developerCache {
                    return await performCache(artifact, batchID: batchID, now: now)
                }
                return await perform(artifact, names: names, batchID: batchID, now: now)
            }
        } catch {
            return .failed(message: UserMessage.describe(error))
        }
    }

    private func perform(_ artifact: DiskArtifact, names: Set<String>, batchID: UUID?, now: Date) async -> CleanOutcome {
        if case .blocked(let reason) = artifact.removal { return .skipped(reason: reason) }

        let manager = FileManager.default
        let path = artifact.path.standardizedFileURL
        let checkout = artifact.checkoutRoot.standardizedFileURL

        // The folder must be the named kind, inside its checkout, and not the checkout itself.
        guard path.lastPathComponent == artifact.name, GitParsers.matchesDisposable(artifact.name, names) else {
            return .skipped(reason: "This is not a folder Lopper clears")
        }
        guard path != checkout else { return .skipped(reason: "The project folder itself is never cleared") }
        let resolvedParent = path.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolvedCheckout = checkout.resolvingSymlinksInPath().path
        guard resolvedParent == resolvedCheckout || resolvedParent.hasPrefix(resolvedCheckout + "/") else {
            return .skipped(reason: "This folder is outside the project, so it was left alone")
        }

        // Read the type without following links: a path that became a symlink is never touched.
        guard let attributes = try? manager.attributesOfItem(atPath: path.path) else {
            return .skipped(reason: "This folder no longer exists")
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return .skipped(reason: "This is no longer a plain folder, so it was left alone")
        }

        // The rule that offered it must still hold: a lockfile that vanished means it could not be rebuilt.
        let project = path.deletingLastPathComponent()
        let evaluation = ArtifactRules.evaluate(
            name: artifact.name, projectDirectory: project, checkoutRoot: checkout,
            fileExists: { manager.fileExists(atPath: $0.path) },
            readText: { try? String(contentsOf: $0, encoding: .utf8) })
        if case .blocked(let reason) = evaluation.removal { return .skipped(reason: reason) }

        // Git must still call it generated: nothing tracked inside, nothing untracked-but-not-ignored.
        let relative = String(path.path.dropFirst(checkout.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty else { return .skipped(reason: "The project folder itself is never cleared") }
        do {
            let tracked = try await git.run(["ls-files", "-z", "--", relative], in: checkout)
            if !tracked.succeeded { return .failed(message: "Could not ask git about this folder. Nothing was changed.") }
            if !tracked.stdout.isEmpty {
                return .skipped(reason: "Part of this folder is tracked by git, so it was left alone")
            }
            let ignored = try await git.run(["check-ignore", "-q", "--", relative], in: checkout)
            guard ignored.succeeded else {
                return .skipped(reason: "This folder is no longer ignored by git, so it may hold source files")
            }
            let loose = try await git.run(
                ["ls-files", "-z", "--others", "--exclude-standard", "--", relative], in: checkout)
            if !loose.stdout.isEmpty {
                return .skipped(reason: "This folder holds files git does not ignore, so it was left alone")
            }
        } catch {
            return .failed(message: "Could not ask git about this folder. \(UserMessage.describe(error))")
        }

        var record = UndoRecord(
            timestamp: now, repoPath: artifact.repoRoot.path, action: .trashFolder, branch: nil, tip: "",
            upstream: nil, worktreePath: artifact.path.path, trashRef: "", status: .pending, batchID: batchID,
            reason: evaluation.kind.title, bytes: artifact.bytes)
        do {
            try await undoLog.append(record)
        } catch {
            return .failed(message: "Nothing was changed because the undo log could not be written.")
        }
        do {
            let trashed = try trash.moveToTrash(path)
            record.trashedPath = trashed.path
            record.status = .completed
            try? await undoLog.append(record)
            return .removed(record)
        } catch {
            record.status = .failed
            record.detail = String(describing: error)
            try? await undoLog.append(record)
            return .failed(message: "Could not move the folder to the Trash. \(UserMessage.describe(error))")
        }
    }

    /// A tool cache is cleared only when it is exactly one of the folders in the catalog: no search, no
    /// patterns, and never a path that is not spelled out there.
    private func performCache(_ artifact: DiskArtifact, batchID: UUID?, now: Date) async -> CleanOutcome {
        let manager = FileManager.default
        let known = DeveloperCaches.catalog(home: home)
        guard let entry = known.first(where: {
            $0.path.standardizedFileURL.path == artifact.path.standardizedFileURL.path
        }) else {
            return .skipped(reason: "This is not a cache Lopper knows how to clear")
        }
        guard let attributes = try? manager.attributesOfItem(atPath: entry.path.path) else {
            return .skipped(reason: "This folder no longer exists")
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            return .skipped(reason: "This is no longer a plain folder, so it was left alone")
        }
        var record = UndoRecord(
            timestamp: now, repoPath: DeveloperCaches.historyRepoPath, action: .trashFolder, branch: nil, tip: "",
            upstream: nil, worktreePath: entry.path.path, trashRef: "", status: .pending, batchID: batchID,
            reason: "\(entry.name). Comes back with \(entry.regenerate).", bytes: artifact.bytes)
        do {
            try await undoLog.append(record)
        } catch {
            return .failed(message: "Nothing was changed because the undo log could not be written.")
        }
        do {
            let trashed = try trash.moveToTrash(entry.path)
            record.trashedPath = trashed.path
            record.status = .completed
            try? await undoLog.append(record)
            return .removed(record)
        } catch {
            record.status = .failed
            record.detail = String(describing: error)
            try? await undoLog.append(record)
            return .failed(message: "Could not move the folder to the Trash. \(UserMessage.describe(error))")
        }
    }
}

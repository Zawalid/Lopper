import Foundation

/// Everything one scan produces, in the shape the app's pages and the command line both consume.
public struct WorkspaceScan: Sendable {
    public struct Failure: Sendable, Equatable {
        public let root: URL
        public let message: String
    }

    public let results: [RepoScanResult]
    public let sizes: [String: DiskUsage]
    /// Every branch and worktree row, safe first, oldest work first inside each group.
    public let rows: [CleanupRow]
    public let failures: [Failure]

    public var snapshots: [RepoSnapshot] {
        results.compactMap { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
    }
}

/// The engine's front door for scanning, removing and restoring: the same orchestration the app uses, so the
/// command line behaves exactly like the app and they share one settings file and one undo log.
public struct Workspace: Sendable {
    public let settings: Settings
    private let git: GitRunner
    private let prProvider: PRProvider?
    private let undoLog: UndoLog
    private let trash: TrashProvider
    private let gate = RepoGate()
    private let now: @Sendable () -> Date

    public init(
        settings: Settings, prProvider: PRProvider? = GhCliProvider(), undoLog: UndoLog = UndoLog(url: UndoLog.defaultURL),
        git: GitRunner = GitRunner(), trash: TrashProvider = SystemTrash(), now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.settings = settings
        self.prProvider = prProvider
        self.undoLog = undoLog
        self.git = git
        self.trash = trash
        self.now = now
    }

    private var inspector: RepoInspector {
        RepoInspector(git: git, settings: settings, prProvider: prProvider)
    }

    private var cleaner: Cleaner {
        Cleaner(git: git, inspector: inspector, undoLog: undoLog, gate: gate, trash: trash)
    }

    /// Finds the repositories under the configured folders, classifies every branch and worktree, and (unless
    /// told not to) measures the folders of worktrees so agent worktrees can be judged finished or in use.
    public func scan(measureSizes: Bool = true) async -> WorkspaceScan {
        let service = ScanService(
            inspector: inspector, scanner: RepoScanner(excludePatterns: settings.excludePatterns), gate: gate)
        let results = await service.scan(roots: settings.roots, maxDepth: settings.scanDepth)
            .sorted { $0.repoRoot.path < $1.repoRoot.path }

        let snapshots = results.compactMap { result -> RepoSnapshot? in
            if case .snapshot(let snapshot) = result { snapshot } else { nil }
        }
        let sizes = measureSizes ? await measure(snapshots) : [:]
        let policy = AgentPolicy(settings: settings)
        let moment = now()
        let rows = snapshots
            .flatMap { RowMapper.rows(for: $0, sizes: sizes, policy: policy, now: moment) }
            .sorted(by: RowMapper.defaultOrder)
        let failures = results.compactMap { result -> WorkspaceScan.Failure? in
            if case .failure(let root, let message) = result { .init(root: root, message: message) } else { nil }
        }
        return WorkspaceScan(results: results, sizes: sizes, rows: rows, failures: failures)
    }

    /// Reads only these repositories, for refreshing them after something changed inside them. Hidden repositories are
    /// left out, and nothing is discovered: the caller already knows which repositories it means.
    public func scanRepositories(_ roots: [URL]) async -> [RepoScanResult] {
        let service = ScanService(
            inspector: inspector, scanner: RepoScanner(excludePatterns: settings.excludePatterns), gate: gate)
        return await service.inspect(repos: roots.filter { !inspector.isIgnored($0) })
            .sorted { $0.repoRoot.path < $1.repoRoot.path }
    }

    /// Work in the scanned repositories that exists only on this Mac: unpushed commits, uncommitted changes, stashes.
    public func localOnlyWork(in scan: WorkspaceScan) async -> [LocalOnlyItem] {
        await LocalWorkScanner(git: git).scan(scan.snapshots)
    }

    /// Every worktree, and every main folder without the worktrees nested inside it (those count under their own name).
    private func measure(_ snapshots: [RepoSnapshot]) async -> [String: DiskUsage] {
        let targets = snapshots.flatMap { snapshot -> [(path: URL, disposable: Set<String>, excluding: [URL])] in
            let disposable = settings.disposableSet(for: snapshot.repo.root)
            let live = snapshot.worktrees.filter { !$0.isPrunable }
            return live.map { entry in
                let nested = entry.isMain
                    ? live.filter { !$0.isMain && $0.path.path.hasPrefix(entry.path.path + "/") }.map(\.path)
                    : []
                return (path: entry.path, disposable: disposable, excluding: nested)
            }
        }
        var sizes: [String: DiskUsage] = [:]
        await withTaskGroup(of: (String, DiskUsage).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    (target.path.path,
                     await SizeCalculator.measure(target.path, disposableNames: target.disposable, excluding: target.excluding))
                }
            }
            for _ in 0..<SizeCalculator.concurrentMeasurements { addNext() }
            while let (path, usage) = await group.next() {
                sizes[path] = usage
                addNext()
            }
        }
        return sizes
    }

    /// Removes exactly these rows, worktrees before branches, re-verifying each against fresh state first.
    /// Worktree rows are strict: if work that exists only in the folder appeared since the scan, they are refused.
    public func clean(_ rows: [CleanupRow], control: BatchControl? = nil) -> AsyncStream<BatchEvent> {
        let items = rows.compactMap(\.cleanupItem)
        let strict = Set(items.filter { if case .worktree = $0 { true } else { false } }.map(\.id))
        var hints: [String: Int64] = [:]
        var heldBack: [String: String] = [:]
        for row in rows {
            guard let item = row.cleanupItem else { continue }
            if let size = row.size { hints[item.id] = size }
            // Whatever the caller chose, a worktree an agent may still be using is never removed from here.
            if let reason = row.agentHeldBackReason { heldBack[item.id] = reason }
        }
        return BatchCleaner(cleaner: cleaner).run(
            items: items, now: now(), control: control, strictItemIDs: strict, sizeHints: hints, heldBack: heldBack)
    }

    /// Moves one worktree's whole folder to the Trash and drops git's record of it, for a folder that holds changes git
    /// will not discard. The branch stays and History can undo it. No size is recorded as freed: the folder sits in the
    /// Trash until it is emptied. One row at a time, never part of a batch of
    /// removals: the person has to have seen this folder's files. A branch, a Protected row and a worktree an agent
    /// may still be using are refused here, whatever the caller allowed.
    public func removeKeepingCopy(_ row: CleanupRow, batchID: UUID = UUID()) async -> CleanOutcome {
        if let refusal = row.keepCopyRefusal { return .skipped(reason: refusal) }
        guard let path = row.path else { return .skipped(reason: "Only a worktree's folder can be moved to the Trash") }
        return await cleaner.removeWorktreeKeepingCopy(
            repoRoot: row.repoRoot, path: path, approved: row.verdict, batchID: batchID,
            bytes: nil, now: now())
    }

    /// The files that stand in the way of removing this row's folder. Read only.
    public func blockingChanges(of row: CleanupRow) async -> WorktreeChanges {
        guard row.kind == .worktree, let path = row.path else { return .none }
        return await WorktreeChanges.read(at: path, git: git)
    }

    public func history() async -> [UndoRecord] {
        await undoLog.all()
    }

    public func restore(_ record: UndoRecord) async -> RestoreOutcome {
        await cleaner.restore(record, now: now())
    }

    public func restoreBatch(_ id: UUID) async -> [RestoreOutcome] {
        await cleaner.restoreBatch(id, now: now())
    }

    // MARK: Generated folders

    /// The generated folders (node_modules, build output, ...) git ignores inside every working folder of a scan.
    public func artifacts(for scan: WorkspaceScan) async -> [DiskArtifact] {
        struct Target: Sendable {
            let root: URL
            let repoRoot: URL
            let location: ArtifactLocation
            let names: Set<String>
        }
        let targets = scan.snapshots.flatMap { snapshot -> [Target] in
            let names = settings.disposableSet(for: snapshot.repo.root)
            return snapshot.worktrees.filter { !$0.isPrunable }.map { entry in
                Target(
                    root: entry.path, repoRoot: snapshot.repo.root,
                    location: entry.isMain ? .mainCheckout : .worktree(branch: entry.branch), names: names)
            }
        }
        let git = self.git
        var found: [DiskArtifact] = []
        await withTaskGroup(of: [DiskArtifact].self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    await ArtifactScanner(git: git).scan(
                        root: target.root, repoRoot: target.repoRoot, names: target.names, location: target.location)
                }
            }
            for _ in 0..<4 { addNext() }
            while let items = await group.next() {
                found.append(contentsOf: items)
                addNext()
            }
        }
        return found.sorted { $0.bytes > $1.bytes }
    }

    /// Tool caches in the home folder (Xcode build data, the npm cache, ...), as clearable folders.
    public func developerCaches() async -> [DiskArtifact] {
        await DeveloperCaches.scan()
    }

    /// Moves each folder to the Trash after re-checking it, as one batch the undo log can restore together.
    public func clear(_ artifacts: [DiskArtifact]) async -> [CleanOutcome] {
        let cleaner = ArtifactCleaner(undoLog: undoLog, trash: trash, git: git, gate: gate)
        let batch = UUID()
        var outcomes: [CleanOutcome] = []
        for artifact in artifacts {
            let names = settings.disposableSet(for: artifact.repoRoot)
            outcomes.append(await cleaner.clear(artifact, names: names, batchID: batch, now: now()))
        }
        return outcomes
    }
}

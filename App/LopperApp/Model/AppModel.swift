import Foundation
import Observation
import Lopper

enum Route: Hashable {
    case overview
    case history
    case repo(String)
}

enum ScanPhase: Equatable {
    case idle
    case scanning(done: Int, total: Int)
    case ready(Date)
}

enum VerdictFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case safe = "Safe"
    case review = "Review"
    case protected = "Protected"

    var id: String { rawValue }

    func matches(_ kind: VerdictKind) -> Bool {
        switch self {
        case .all: true
        case .safe: kind == .safe
        case .review: kind == .review
        case .protected: kind == .protected
        }
    }
}

enum KindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case branches = "Branches"
    case worktrees = "Worktrees"

    var id: String { rawValue }

    func matches(_ kind: CleanupRow.Kind) -> Bool {
        switch self {
        case .all: true
        case .branches: kind == .branch
        case .worktrees: kind == .worktree
        }
    }
}

struct ItemOutcome: Identifiable, Equatable {
    enum Status: Equatable { case removed, skipped, failed }
    let id: String
    let title: String
    let status: Status
    let message: String?
}

struct CleanState: Equatable {
    enum Phase: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished
    }

    var rows: [CleanupRow]
    var excluded: Set<String> = []
    var phase: Phase = .review
    var outcomes: [ItemOutcome] = []
    var reclaimedBytes: Int64 = 0
    var batchID: UUID?

    var includedRows: [CleanupRow] { rows.filter { !excluded.contains($0.id) } }
    var includedBytes: Int64 { includedRows.reduce(0) { $0 + ($1.size ?? 0) } }
    var removedCount: Int { outcomes.filter { $0.status == .removed }.count }
    var problemCount: Int { outcomes.filter { $0.status != .removed }.count }
}

struct UndoToast: Equatable, Identifiable {
    let id: UUID
    let removed: Int
    let reclaimed: Int64
}

struct Totals: Equatable {
    var repositories = 0
    var safeBranches = 0
    var safeWorktrees = 0
    var review = 0
    var protected = 0
    var reclaimableBytes: Int64 = 0

    var safe: Int { safeBranches + safeWorktrees }
}

@MainActor
@Observable
final class AppModel {
    let client: any EngineClient
    private let store: SettingsStore

    private(set) var settings: Settings
    private(set) var phase: ScanPhase = .idle
    private(set) var results: [RepoScanResult] = []
    private(set) var sizes: [String: DiskUsage] = [:]
    private(set) var history: [UndoRecord] = []

    var route: Route = .overview
    var checked: Set<String> = []
    var focusedRowID: String?
    var verdictFilter: VerdictFilter = .all
    var kindFilter: KindFilter = .all
    var searchText = ""
    var showInspector = true
    var clean: CleanState?
    var toast: UndoToast?

    private var scanTask: Task<Void, Never>?
    private var cleanTask: Task<Void, Never>?

    init(client: any EngineClient, store: SettingsStore = .standard, settings: Settings? = nil) {
        self.client = client
        self.store = store
        self.settings = settings ?? store.load()
    }

    var githubCLIAvailable: Bool { client.githubCLIAvailable }
    var isScanning: Bool { if case .scanning = phase { true } else { false } }
    var isCleaning: Bool { if case .running = clean?.phase { true } else { false } }
    var lastScan: Date? { if case .ready(let date) = phase { date } else { nil } }

    // MARK: Derived data

    var snapshots: [RepoSnapshot] {
        results.compactMap { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
    }

    var allRows: [CleanupRow] {
        snapshots.flatMap { RowMapper.rows(for: $0, sizes: sizes) }
    }

    func rows(forRepo id: String) -> [CleanupRow] {
        guard let snapshot = snapshots.first(where: { $0.repo.id == id }) else { return [] }
        return RowMapper.rows(for: snapshot, sizes: sizes)
    }

    /// Rows of one repository after the search text and both filters are applied.
    func visibleRows(forRepo id: String) -> [CleanupRow] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return rows(forRepo: id).filter { row in
            verdictFilter.matches(row.verdict)
                && kindFilter.matches(row.kind)
                && (needle.isEmpty
                    || row.title.lowercased().contains(needle)
                    || row.location.lowercased().contains(needle))
        }
    }

    var summaries: [RepoSummary] {
        results.map { result in
            switch result {
            case .failure(let root, let message):
                return RepoSummary(
                    id: root.path, name: root.lastPathComponent, root: root, safeBranches: 0,
                    safeWorktrees: 0, review: 0, protected: 0, reclaimableBytes: 0,
                    defaultBranch: nil, failure: message)
            case .snapshot(let snapshot):
                let rows = RowMapper.rows(for: snapshot, sizes: sizes)
                let safe = rows.filter { $0.verdict == .safe }
                return RepoSummary(
                    id: snapshot.repo.id, name: snapshot.repo.name, root: snapshot.repo.root,
                    safeBranches: safe.filter { $0.kind == .branch }.count,
                    safeWorktrees: safe.filter { $0.kind == .worktree }.count,
                    review: rows.filter { $0.verdict == .review }.count,
                    protected: rows.filter { $0.verdict == .protected }.count,
                    reclaimableBytes: safe.reduce(0) { $0 + ($1.size ?? 0) },
                    defaultBranch: snapshot.repo.defaultBranch, failure: nil)
            }
        }
    }

    var totals: Totals {
        summaries.reduce(into: Totals()) { totals, summary in
            totals.repositories += 1
            totals.safeBranches += summary.safeBranches
            totals.safeWorktrees += summary.safeWorktrees
            totals.review += summary.review
            totals.protected += summary.protected
            totals.reclaimableBytes += summary.reclaimableBytes
        }
    }

    var focusedRow: CleanupRow? {
        guard let focusedRowID else { return nil }
        return allRows.first { $0.id == focusedRowID }
    }

    var checkedRows: [CleanupRow] {
        allRows.filter { checked.contains($0.id) && $0.isSelectable }
    }

    var prDetectionNote: Bool {
        !snapshots.isEmpty && snapshots.contains { !$0.prDetectionAvailable }
    }

    // MARK: Settings

    func updateSettings(_ change: (inout Settings) -> Void) {
        var copy = settings
        change(&copy)
        settings = copy
        store.save(copy)
    }

    func setRoots(_ roots: [URL]) {
        updateSettings { $0.roots = roots }
        startScan()
    }

    func addThrowaway(name: String, repoRoot: URL) {
        settings = settings.addingRepoDisposable(name, for: repoRoot)
        store.save(settings)
        startScan()
    }

    // MARK: Scanning

    func scanIfStale(maxAge: TimeInterval = 300) {
        guard !isScanning, !isCleaning, !settings.roots.isEmpty else { return }
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge { return }
        startScan()
    }

    func startScan() {
        guard !settings.roots.isEmpty, !isCleaning else { return }
        scanTask?.cancel()
        let progressive = results.isEmpty
        phase = .scanning(done: 0, total: 0)
        let settings = self.settings
        scanTask = Task {
            var collected: [RepoScanResult] = []
            var total = 0
            for await event in client.scan(settings: settings) {
                switch event {
                case .discovered(let count):
                    total = count
                    phase = .scanning(done: 0, total: count)
                case .result(let result):
                    collected.append(result)
                    phase = .scanning(done: collected.count, total: total)
                    if progressive { results = Self.sorted(collected) }
                }
            }
            guard !Task.isCancelled else { return }
            results = Self.sorted(collected)
            phase = .ready(Date())
            history = await client.history()
            await measureSizes()
        }
    }

    private static func sorted(_ results: [RepoScanResult]) -> [RepoScanResult] {
        results.sorted { $0.repoRoot.path < $1.repoRoot.path }
    }

    /// Worktree sizes arrive one by one after the listing is on screen.
    func measureSizes() async {
        let targets = snapshots.flatMap { snapshot in
            snapshot.worktrees
                .filter { !$0.isMain && !$0.isPrunable }
                .map { (path: $0.path, disposable: settings.disposableSet(for: snapshot.repo.root)) }
        }
        let client = self.client
        await withTaskGroup(of: (String, DiskUsage).self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    (target.path.path, await client.measure(target.path, disposable: target.disposable))
                }
            }
            for _ in 0..<4 { addNext() }
            while let (path, usage) = await group.next() {
                sizes[path] = usage
                addNext()
            }
        }
    }

    // MARK: Selection

    func checkAllSafe(inRepo id: String? = nil) {
        let rows = id.map(visibleRows(forRepo:)) ?? allRows
        checked.formUnion(rows.filter { $0.verdict == .safe }.map(\.id))
    }

    func clearChecked() { checked.removeAll() }

    // MARK: Cleaning

    func beginCleanAllSafe() {
        beginClean(rows: allRows.filter { $0.verdict == .safe })
    }

    func beginCleanChecked() {
        beginClean(rows: checkedRows)
    }

    func beginClean(rows: [CleanupRow]) {
        guard !rows.isEmpty, !isCleaning else { return }
        clean = CleanState(rows: rows)
    }

    func dismissClean() {
        guard !isCleaning else { return }
        clean = nil
    }

    func setExcluded(_ id: String, _ excluded: Bool) {
        guard var state = clean, state.phase == .review else { return }
        if excluded { state.excluded.insert(id) } else { state.excluded.remove(id) }
        clean = state
    }

    func runClean() {
        guard var state = clean, state.phase == .review else { return }
        let rowsByItemID = Dictionary(uniqueKeysWithValues: state.includedRows.compactMap { row in
            row.cleanupItem.map { ($0.id, row) }
        })
        let items = state.includedRows.compactMap(\.cleanupItem)
        guard !items.isEmpty else { return }
        state.phase = .running(done: 0, total: items.count)
        clean = state
        scanTask?.cancel()
        let settings = self.settings

        cleanTask = Task {
            for await event in client.clean(items, settings: settings) {
                guard var current = clean else { break }
                switch event {
                case .started(let batchID, let total):
                    current.batchID = batchID
                    current.phase = .running(done: 0, total: total)
                case .itemFinished(_, let item, let outcome):
                    let row = rowsByItemID[item.id]
                    let title = row?.title ?? Self.title(of: item)
                    current.outcomes.append(Self.outcome(id: item.id, title: title, outcome))
                    if case .removed = outcome { current.reclaimedBytes += row?.size ?? 0 }
                    if case .running(_, let total) = current.phase {
                        current.phase = .running(done: current.outcomes.count, total: total)
                    }
                case .finished(let summary):
                    current.phase = .finished
                    current.batchID = summary.batchID
                    if summary.removed > 0 {
                        toast = UndoToast(
                            id: summary.batchID, removed: summary.removed, reclaimed: current.reclaimedBytes)
                    }
                }
                clean = current
            }
            if case .running = clean?.phase { clean?.phase = .finished }
            checked.removeAll()
            history = await client.history()
        }
    }

    func cancelClean() { cleanTask?.cancel() }

    func finishClean() {
        clean = nil
        startScan()
    }

    private static func title(of item: CleanupItem) -> String {
        switch item {
        case .branch(_, let name, _): name
        case .worktree(_, let path, _, _): path.lastPathComponent
        }
    }

    private static func outcome(id: String, title: String, _ outcome: CleanOutcome) -> ItemOutcome {
        switch outcome {
        case .removed: ItemOutcome(id: id, title: title, status: .removed, message: nil)
        case .skipped(let reason): ItemOutcome(id: id, title: title, status: .skipped, message: reason)
        case .failed(let message): ItemOutcome(id: id, title: title, status: .failed, message: message)
        }
    }

    // MARK: Undo and history

    func undoToast() {
        guard let toast else { return }
        self.toast = nil
        Task {
            _ = await client.restoreBatch(toast.id)
            history = await client.history()
            startScan()
        }
    }

    func dismissToast() { toast = nil }

    func restoreBatch(_ id: UUID) {
        Task {
            _ = await client.restoreBatch(id)
            history = await client.history()
            startScan()
        }
    }

    func restore(_ record: UndoRecord) {
        Task {
            _ = await client.restore(record)
            history = await client.history()
            startScan()
        }
    }
}

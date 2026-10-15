import Foundation
import Lopper

enum DiskPageState: Equatable {
    case needsFolders
    case scanning
    case nothingFound(projects: Int)
    case ready
}

extension AppModel {
    // MARK: Derived data

    var diskProjects: [DiskProject] {
        DiskInsights.projects(artifacts: artifacts, sizes: sizes)
    }

    var visibleDiskProjects: [DiskProject] {
        DiskInsights.filter(
            diskProjects, untouchedOnly: diskUntouchedOnly, query: diskSearchText,
            now: clock(), staleDays: settings.staleDays)
    }

    var diskKindGroups: [DiskKindGroup] {
        DiskInsights.kinds(artifacts: visibleDiskProjects.flatMap(\.artifacts))
    }

    /// Totals for the whole machine view, not narrowed by the search or the untouched toggle.
    var diskTotals: DiskTotals {
        DiskInsights.totals(of: diskProjects, now: clock(), staleDays: settings.staleDays)
    }

    var diskPageState: DiskPageState {
        if settings.roots.isEmpty { return .needsFolders }
        if artifacts.isEmpty && developerCaches.isEmpty {
            if isScanning || artifactPhase == .scanning || (results.isEmpty && phase == .idle) { return .scanning }
            return .nothingFound(projects: snapshots.count)
        }
        return .ready
    }

    /// Generated folders Lopper would offer to clear inside one working folder, for the Agents page.
    func clearableArtifacts(inCheckout path: String) -> [DiskArtifact] {
        artifacts.filter { $0.checkoutRoot.standardizedFileURL.path == path && $0.removal.isOffered }
    }

    var trashedTotals: TrashSweeper.Totals { TrashSweeper.totals(of: trashedFolders) }

    /// Deletes the folders Lopper put in the Trash, for good. Only those; the rest of the Trash is the
    /// person's. Undo no longer works for them afterwards, which the confirmation says.
    func deleteTrashedForGood() {
        let records = trashedFolders
        guard !records.isEmpty else { return }
        let client = self.client
        Task {
            let result = await client.deleteTrashed(records)
            await reloadHistory()
            let freed = result.deleted.reduce(Int64(0)) { $0 + ($1.bytes ?? 0) }
            if let failure = result.failures.first {
                notice = "Couldn't delete \(Plural.count(result.failures.count, "folder")) from the Trash. \(failure.message)"
            }
            if !result.deleted.isEmpty {
                confirm("Deleted \(Plural.count(result.deleted.count, "folder")), \(SizeFormat.string(freed)) freed")
            }
        }
    }

    // MARK: Scanning

    /// Looks for generated folders in every working folder, a few at a time.
    func scanArtifacts() async {
        struct Target {
            let root: URL
            let repoRoot: URL
            let location: ArtifactLocation
            let names: Set<String>
        }
        let targets = snapshots.flatMap { snapshot -> [Target] in
            let names = settings.disposableSet(for: snapshot.repo.root)
            return snapshot.worktrees.filter { !$0.isPrunable }.map { entry in
                Target(
                    root: entry.path, repoRoot: snapshot.repo.root,
                    location: entry.isMain ? .mainCheckout : .worktree(branch: entry.branch), names: names)
            }
        }
        artifactPhase = .scanning
        let client = self.client
        var found: [DiskArtifact] = []
        await withTaskGroup(of: [DiskArtifact].self) { group in
            var iterator = targets.makeIterator()
            func addNext() {
                guard let target = iterator.next() else { return }
                group.addTask {
                    await client.artifacts(
                        in: target.root, repoRoot: target.repoRoot, location: target.location, names: target.names)
                }
            }
            for _ in 0..<4 { addNext() }
            while let items = await group.next() {
                found.append(contentsOf: items)
                addNext()
            }
        }
        artifacts = found
        developerCaches = await client.developerCaches()
        volumeSpace = client.volumeSpace()
        artifactPhase = .ready(clock())
    }

    // MARK: Clearing

    func beginClearAllClearable() {
        beginDiskClear(
            visibleDiskProjects.flatMap(\.clearable), title: "Clear generated folders")
    }

    var diskDuplicates: [DiskDuplicate] {
        DiskInsights.duplicates(artifacts: artifacts)
    }

    func beginClear(duplicate: DiskDuplicate) {
        beginDiskClear(
            duplicate.clearableInWorktrees,
            title: "Clear \(duplicate.name) in \(Plural.count(duplicate.clearableInWorktrees.count, "worktree"))")
    }

    func setDiskReinstall(_ enabled: Bool) {
        guard var state = diskClear, state.phase == .review else { return }
        state.reinstall = enabled
        diskClear = state
    }

    func beginClearDeveloperCaches() {
        beginDiskClear(developerCaches, title: "Clear developer caches")
    }

    func beginClearUntouched() {
        let now = clock()
        let stale = diskProjects.filter { $0.isUntouched(now: now, staleDays: settings.staleDays) }
        beginDiskClear(stale.flatMap(\.clearable), title: "Clear folders in untouched projects")
    }

    func beginClear(project id: String) {
        guard let project = diskProjects.first(where: { $0.id == id }) else { return }
        beginDiskClear(project.clearable, title: "Clear folders in \(project.name)")
    }

    func beginClear(kind: ArtifactKind) {
        guard let group = diskKindGroups.first(where: { $0.kind == kind }) else { return }
        beginDiskClear(group.clearable, title: "Clear \(kind.title.lowercased())")
    }

    func beginClear(artifact: DiskArtifact) {
        beginDiskClear([artifact], title: "Clear \(artifact.name)")
    }

    /// The Agents page action: frees the build folders of one worktree and leaves the worktree where it is.
    func beginClearBuildFolders(inWorktree path: String, named name: String) {
        beginDiskClear(clearableArtifacts(inCheckout: path), title: "Clear build folders in \(name)")
    }

    private func beginDiskClear(_ items: [DiskArtifact], title: String) {
        let offered = items.filter { $0.removal.isOffered }
        guard !offered.isEmpty, diskClear == nil, clean == nil else { return }
        diskClear = DiskClearState(title: title, artifacts: offered)
    }

    func setDiskExcluded(_ id: String, _ excluded: Bool) {
        guard var state = diskClear, state.phase == .review else { return }
        if excluded { state.excluded.insert(id) } else { state.excluded.remove(id) }
        diskClear = state
    }

    func dismissDiskClear() {
        guard case .running = diskClear?.phase else {
            diskClear = nil
            return
        }
    }

    func stopDiskClear() {
        guard case .running = diskClear?.phase else { return }
        diskClear?.isStopping = true
    }

    func runDiskClear() {
        guard var state = diskClear, state.phase == .review, !state.included.isEmpty else { return }
        let items = state.included
        let batch = UUID()
        state.batchID = batch
        state.phase = .running(done: 0, total: items.count)
        diskClear = state
        let settings = self.settings
        let client = self.client

        Task {
            for (index, artifact) in items.enumerated() {
                if diskClear?.isStopping == true { break }
                let names = settings.disposableSet(for: artifact.repoRoot)
                let outcome = await client.clearArtifact(artifact, names: names, batchID: batch)
                guard var current = diskClear else { break }
                let title = "\(artifact.name) in \(artifact.checkoutRoot.lastPathComponent)"
                switch outcome {
                case .removed:
                    current.outcomes.append(ItemOutcome(id: artifact.id, title: title, status: .removed, message: nil))
                    current.removed += 1
                    current.reclaimedBytes += artifact.bytes
                case .skipped(let reason):
                    current.outcomes.append(ItemOutcome(id: artifact.id, title: title, status: .skipped, message: reason))
                case .failed(let message):
                    current.outcomes.append(ItemOutcome(id: artifact.id, title: title, status: .failed, message: message))
                }
                current.phase = .running(done: index + 1, total: items.count)
                diskClear = current
            }
            if diskClear?.reinstall == true, diskClear?.isStopping != true {
                let targets = (diskClear?.reinstallTargets ?? []).filter { target in
                    // Only projects whose folder was actually cleared.
                    items.contains { $0.projectDirectory == target.directory } && (diskClear?.removed ?? 0) > 0
                }
                let base = items.count
                for (index, target) in targets.enumerated() {
                    guard diskClear?.isStopping != true else { break }
                    diskClear?.phase = .running(done: base + index, total: base + targets.count)
                    let outcome = await client.reinstall(in: target.directory, how: target.how)
                    switch outcome {
                    case .done:
                        diskClear?.reinstalled += 1
                    case .unsupported:
                        break
                    case .failed(let message):
                        diskClear?.outcomes.append(ItemOutcome(
                            id: "reinstall:\(target.directory.path)",
                            title: "\(target.how) in \(target.directory.lastPathComponent)",
                            status: .failed, message: message))
                    }
                }
            }
            guard var finished = diskClear else { return }
            finished.phase = .finished
            diskClear = finished
            if finished.removed > 0 {
                toast = UndoToast(
                    id: batch, removed: finished.removed, reclaimed: finished.reclaimedBytes, folders: true)
            }
            await reloadHistory()
            // Only the folders that changed need measuring again.
            let touched = Set(items.map { $0.checkoutRoot.path })
            await measureSizes(only: touched)
            await scanArtifacts()
        }
    }

    func finishDiskClear() {
        diskClear = nil
    }
}

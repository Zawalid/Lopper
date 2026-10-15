import Foundation
import Lopper

enum DiskGrouping: String, CaseIterable, Identifiable {
    case project = "By project"
    case kind = "By kind"
    case map = "Map"

    var id: String { rawValue }
}

enum ArtifactScanPhase: Equatable {
    case idle
    case scanning
    case ready(Date)
}

/// One working folder (a main checkout or a worktree) and the generated folders found inside it.
struct DiskProject: Identifiable, Equatable {
    let id: String
    let name: String
    let repoName: String
    let path: URL
    let location: ArtifactLocation
    let artifacts: [DiskArtifact]
    /// Everything on disk under the folder, nil until it has been measured.
    let footprint: Int64?
    /// The last time anyone edited a source file here, nil until measured.
    let lastEdited: Date?

    var isWorktree: Bool {
        if case .worktree = location { true } else { false }
    }

    var buildBytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var clearable: [DiskArtifact] { artifacts.filter { $0.removal.isOffered } }
    var clearableBytes: Int64 { clearable.reduce(0) { $0 + $1.bytes } }
    var blocked: [DiskArtifact] { artifacts.filter { !$0.removal.isOffered } }
    var sourceBytes: Int64? { footprint.map { max(0, $0 - buildBytes) } }

    func isUntouched(now: Date, staleDays: Int) -> Bool {
        guard let lastEdited else { return false }
        return lastEdited < now.addingTimeInterval(-Double(staleDays) * 86_400)
    }

    /// A short word for "build folders" that fits the common case, used in buttons.
    var clearTitle: String {
        let count = clearable.count
        return count == 1 ? "Clear \(clearable[0].name)" : "Clear \(count) folders"
    }
}

/// Generated folders of one kind across every project.
struct DiskKindGroup: Identifiable, Equatable {
    let kind: ArtifactKind
    let artifacts: [DiskArtifact]

    var id: ArtifactKind { kind }
    var bytes: Int64 { artifacts.reduce(0) { $0 + $1.bytes } }
    var clearable: [DiskArtifact] { artifacts.filter { $0.removal.isOffered } }
    var clearableBytes: Int64 { clearable.reduce(0) { $0 + $1.bytes } }

    /// What brings these back, once each: "npm ci, pnpm install".
    var regenerateHint: String {
        var seen: [String] = []
        for artifact in clearable {
            if case .offered(let how) = artifact.removal, !seen.contains(how) { seen.append(how) }
        }
        return seen.joined(separator: ", ")
    }
}

/// The same generated folder repeated across a repository's main folder and its worktrees: the cheapest space
/// to give back, because the main copy stays.
struct DiskDuplicate: Identifiable, Equatable {
    let id: String
    let repoName: String
    let name: String
    let copies: Int
    let totalBytes: Int64
    /// The copies inside worktrees that can be cleared.
    let clearableInWorktrees: [DiskArtifact]

    var freeableBytes: Int64 { clearableInWorktrees.reduce(0) { $0 + $1.bytes } }
}

struct DiskTotals: Equatable {
    var projects = 0
    var folders = 0
    var footprint: Int64 = 0
    var buildBytes: Int64 = 0
    var clearableBytes: Int64 = 0
    /// Clearable bytes in projects nobody has edited for the stale window.
    var untouchedBytes: Int64 = 0
    var untouchedProjects = 0
}

/// What the Disk page shows, derived from the folders the engine found. Pure, so the numbers are unit tested.
enum DiskInsights {
    static func projects(
        artifacts: [DiskArtifact], sizes: [String: DiskUsage], repoNames: [String: String] = [:]
    ) -> [DiskProject] {
        Dictionary(grouping: artifacts, by: { $0.checkoutRoot.standardizedFileURL.path })
            .map { path, items in
                let first = items[0]
                let repoName = repoNames[first.repoRoot.path] ?? first.repoRoot.lastPathComponent
                let name: String
                switch first.location {
                case .mainCheckout:
                    name = repoName
                case .worktree(let branch):
                    let label = branch ?? first.checkoutRoot.lastPathComponent
                    name = "\(repoName) / \(label)"
                case .developerCache:
                    name = "Developer caches"
                }
                let sorted = items.sorted { $0.bytes > $1.bytes }
                let generated = sorted.reduce(Int64(0)) { $0 + $1.bytes }
                let usage = sizes[first.checkoutRoot.path] ?? sizes[path]
                // A folder cannot be smaller than the folders inside it: a smaller number means the
                // measurement is stale or incomplete, and a wrong split is worse than none.
                let footprint = usage.flatMap { $0.total >= generated ? $0.total : nil }
                return DiskProject(
                    id: path, name: name, repoName: repoName, path: first.checkoutRoot, location: first.location,
                    artifacts: sorted, footprint: footprint, lastEdited: usage?.newestModification)
            }
            .sorted {
                if $0.buildBytes != $1.buildBytes { return $0.buildBytes > $1.buildBytes }
                return $0.name < $1.name
            }
    }

    static func kinds(artifacts: [DiskArtifact]) -> [DiskKindGroup] {
        Dictionary(grouping: artifacts, by: \.kind)
            .map { DiskKindGroup(kind: $0.key, artifacts: $0.value.sorted { $0.bytes > $1.bytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    /// Folders with the same name repeated in at least three places of one repository, biggest saving first.
    static func duplicates(artifacts: [DiskArtifact]) -> [DiskDuplicate] {
        let repository = artifacts.filter { $0.location != .developerCache }
        return Dictionary(grouping: repository) { "\($0.repoRoot.path)|\($0.name)" }
            .compactMap { key, items -> DiskDuplicate? in
                let clearable = items.filter { item in
                    if case .worktree = item.location, item.removal.isOffered { return true }
                    return false
                }
                guard items.count >= 3, clearable.count >= 2 else { return nil }
                return DiskDuplicate(
                    id: key, repoName: items[0].repoRoot.lastPathComponent, name: items[0].name,
                    copies: items.count, totalBytes: items.reduce(0) { $0 + $1.bytes },
                    clearableInWorktrees: clearable.sorted { $0.bytes > $1.bytes })
            }
            .sorted { $0.freeableBytes > $1.freeableBytes }
    }

    static func totals(of projects: [DiskProject], now: Date, staleDays: Int) -> DiskTotals {
        var totals = DiskTotals()
        for project in projects {
            totals.projects += 1
            totals.folders += project.artifacts.count
            totals.footprint += project.footprint ?? project.buildBytes
            totals.buildBytes += project.buildBytes
            totals.clearableBytes += project.clearableBytes
            if project.isUntouched(now: now, staleDays: staleDays), project.clearableBytes > 0 {
                totals.untouchedBytes += project.clearableBytes
                totals.untouchedProjects += 1
            }
        }
        return totals
    }

    static func filter(
        _ projects: [DiskProject], untouchedOnly: Bool, query: String, now: Date, staleDays: Int
    ) -> [DiskProject] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return projects.filter { project in
            if untouchedOnly, !project.isUntouched(now: now, staleDays: staleDays) { return false }
            guard !needle.isEmpty else { return true }
            return project.name.lowercased().contains(needle)
                || project.artifacts.contains { $0.name.lowercased().contains(needle) }
        }
    }
}

/// The review sheet's state for clearing generated folders.
struct DiskClearState: Equatable {
    enum Phase: Equatable {
        case review
        case running(done: Int, total: Int)
        case finished
    }

    var title: String
    var artifacts: [DiskArtifact]
    var excluded: Set<String> = []
    var phase: Phase = .review
    var outcomes: [ItemOutcome] = []
    var removed = 0
    var reclaimedBytes: Int64 = 0
    var batchID: UUID?
    var isStopping = false
    /// Run the lockfile install again in each project once its folder is cleared.
    var reinstall = false
    var reinstalled = 0

    var included: [DiskArtifact] { artifacts.filter { !excluded.contains($0.id) } }
    var includedBytes: Int64 { included.reduce(0) { $0 + $1.bytes } }
    var problemCount: Int { outcomes.filter { $0.status != .removed }.count }

    /// Folders in the list whose install command Lopper knows how to run again: one per project and command.
    var reinstallTargets: [(directory: URL, how: String)] {
        var seen = Set<String>()
        var targets: [(directory: URL, how: String)] = []
        for artifact in included {
            guard case .offered(let how) = artifact.removal, Reinstaller.isSupported(how) else { continue }
            let key = "\(artifact.projectDirectory.path)|\(how)"
            if seen.insert(key).inserted { targets.append((artifact.projectDirectory, how)) }
        }
        return targets
    }
}

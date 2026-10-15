import Foundation
import Lopper

enum DiskGrouping: String, CaseIterable, Identifiable {
    case project = "By project"
    case kind = "By kind"

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
                }
                let usage = sizes[first.checkoutRoot.path] ?? sizes[path]
                return DiskProject(
                    id: path, name: name, repoName: repoName, path: first.checkoutRoot, location: first.location,
                    artifacts: items.sorted { $0.bytes > $1.bytes },
                    footprint: usage?.total, lastEdited: usage?.newestModification)
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

    var included: [DiskArtifact] { artifacts.filter { !excluded.contains($0.id) } }
    var includedBytes: Int64 { included.reduce(0) { $0 + $1.bytes } }
    var problemCount: Int { outcomes.filter { $0.status != .removed }.count }
}

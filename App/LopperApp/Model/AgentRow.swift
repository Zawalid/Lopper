import Foundation
import Lopper

/// One row of the Agents page: the ordinary cleanup row plus the engine's assessment of it.
struct AgentRow: Identifiable, Equatable, Sendable {
    let row: CleanupRow
    let assessment: AgentAssessment

    var id: String { row.id }
    var title: String { row.title }
    var activitySort: Date { assessment.lastActivity ?? .distantPast }
    var ageSort: Date { assessment.createdAt ?? .distantPast }
    var sizeSort: Int64 { row.sizeSort }
    var stateSort: Int { assessment.state.displayRank }
}

extension AgentState {
    /// Loudest first: work that is not merged, then what can be reclaimed, then what is in use.
    var displayRank: Int {
        switch self {
        case .unmerged: 0
        case .abandoned: 1
        case .finished: 2
        case .active: 3
        case .protected: 4
        }
    }

    var label: String {
        switch self {
        case .finished: "Finished"
        case .active: "Active"
        case .unmerged: "Not merged"
        case .abandoned: "Abandoned"
        case .protected: "Protected"
        }
    }

    var symbol: String {
        switch self {
        case .finished: "checkmark.circle"
        case .active: "clock"
        case .unmerged: "exclamationmark.triangle"
        case .abandoned: "moon.zzz"
        case .protected: "lock"
        }
    }
}

enum AgentStateFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case finished = "Finished"
    case active = "Active"
    case notMerged = "Not merged"
    case abandoned = "Abandoned"

    var id: String { rawValue }

    func matches(_ state: AgentState) -> Bool {
        switch self {
        case .all: true
        case .finished: state == .finished
        case .active: state == .active
        case .notMerged: state == .unmerged
        case .abandoned: state == .abandoned
        }
    }
}

struct AgentsSummary: Equatable {
    var total = 0
    /// Rows "Reclaim finished" would remove, and their size.
    var reclaimable = 0
    var reclaimableBytes: Int64 = 0
    /// Abandoned rows that can be removed after the Review step, keeping their branches.
    var abandonedReclaimable = 0
    var abandonedBytes: Int64 = 0
    /// Not merged plus abandoned: the loud counter.
    var notMerged = 0
    /// Rows holding work that exists only in the folder.
    var folderOnly = 0
    var active = 0
    var protected = 0
    /// Rows still waiting for their folder to be measured.
    var measuring = 0
}

enum AgentsPageState: Equatable {
    case needsFolders
    case scanning
    case noAgents(repositories: Int)
    case nothingToReclaim
    case ready
}

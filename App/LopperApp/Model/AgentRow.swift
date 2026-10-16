import Foundation
import Lopper

extension AgentState {
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

import Foundation

/// One row of the Agents page: the ordinary cleanup row plus the engine's assessment of it.
public struct AgentRow: Identifiable, Equatable, Sendable {
    public let row: CleanupRow
    public let assessment: AgentAssessment

    public init(row: CleanupRow, assessment: AgentAssessment) {
        self.row = row
        self.assessment = assessment
    }

    public var id: String { row.id }
    public var title: String { row.title }
    public var activitySort: Date { assessment.lastActivity ?? .distantPast }
    public var ageSort: Date { assessment.createdAt ?? .distantPast }
    public var sizeSort: Int64 { row.sizeSort }
    public var stateSort: Int { assessment.state.displayRank }
}

extension AgentState {
    /// Loudest first: work that is not merged, then what can be reclaimed, then what is in use.
    public var displayRank: Int {
        switch self {
        case .unmerged: 0
        case .abandoned: 1
        case .finished: 2
        case .active: 3
        case .protected: 4
        }
    }

    public var label: String {
        switch self {
        case .finished: "Finished"
        case .active: "Active"
        case .unmerged: "Not merged"
        case .abandoned: "Abandoned"
        case .protected: "Protected"
        }
    }
}

/// What one tool's worktrees add up to, for the totals row on the Agents page and `lop agents`.
public struct AgentToolTotal: Identifiable, Equatable, Sendable {
    public let tool: AgentTool
    public let count: Int
    public let bytes: Int64

    public init(tool: AgentTool, count: Int, bytes: Int64) {
        self.tool = tool
        self.count = count
        self.bytes = bytes
    }

    public var id: AgentTool { tool }

    public static func totals(of rows: [AgentRow]) -> [AgentToolTotal] {
        Dictionary(grouping: rows.map { ($0.assessment.detection.tool, $0) }, by: \.0)
            .map { tool, pairs in
                AgentToolTotal(tool: tool, count: pairs.count, bytes: pairs.reduce(0) { $0 + ($1.1.row.size ?? 0) })
            }
            .sorted { ($0.bytes, $0.count) > ($1.bytes, $1.count) }
    }
}

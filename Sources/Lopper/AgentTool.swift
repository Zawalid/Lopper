import Foundation

/// An AI coding tool known to create git worktrees.
public enum AgentTool: String, Sendable, Equatable, Codable, CaseIterable {
    case claudeCode
    case cursor
    case codex
    case conductor

    public var label: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .cursor: "Cursor"
        case .codex: "Codex"
        case .conductor: "Conductor"
        }
    }
}

/// Which tool a worktree appears to come from, and how sure that is. Informational: a detection never
/// changes a verdict, so a wrong guess costs a wrong label and nothing else.
public struct AgentDetection: Sendable, Equatable {
    public enum Basis: String, Sendable, Equatable {
        /// The folder sits in the tool's own worktree location.
        case path
        /// Only the branch name looks like the tool's naming.
        case branch
    }

    public let tool: AgentTool
    public let basis: Basis

    public init(tool: AgentTool, basis: Basis) {
        self.tool = tool
        self.basis = basis
    }

    public var label: String {
        basis == .path ? tool.label : "Probably \(tool.label)"
    }
}

public enum AgentDetector {
    /// Folder conventions. Only the Claude Code one is confirmed on a real install; the others come from the
    /// tools' documented behaviour and must be re-checked against real installs.
    static let pathMarkers: [(marker: String, tool: AgentTool)] = [
        ("/.claude/worktrees/", .claudeCode),
        ("/.cursor/worktrees/", .cursor),
        ("/.codex/worktrees/", .codex),
        ("/conductor/workspaces/", .conductor),
    ]

    static let branchPrefixes: [(prefix: String, tool: AgentTool)] = [
        ("claude/", .claudeCode),
        ("worktree-", .claudeCode),
        ("cursor/", .cursor),
        ("codex/", .codex),
    ]

    public static func detect(path: String, branch: String?) -> AgentDetection? {
        for (marker, tool) in pathMarkers where path.contains(marker) {
            return AgentDetection(tool: tool, basis: .path)
        }
        guard let branch else { return nil }
        for (prefix, tool) in branchPrefixes where branch.hasPrefix(prefix) {
            return AgentDetection(tool: tool, basis: .branch)
        }
        return nil
    }
}

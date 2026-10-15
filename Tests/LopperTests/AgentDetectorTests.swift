import XCTest
@testable import Lopper

final class AgentDetectorTests: XCTestCase {
    func testPathConventionsAreStrongEvidence() {
        let cases: [(String, AgentTool)] = [
            ("/Users/me/code/api/.claude/worktrees/fix-login", .claudeCode),
            ("/Users/me/.cursor/worktrees/api/ab12", .cursor),
            ("/Users/me/.codex/worktrees/1a2b/api", .codex),
            ("/Users/me/conductor/workspaces/api/berlin", .conductor),
        ]
        for (path, tool) in cases {
            let detection = AgentDetector.detect(path: path, branch: nil)
            XCTAssertEqual(detection?.tool, tool, path)
            XCTAssertEqual(detection?.basis, .path, path)
        }
    }

    func testBranchPrefixesAreWeakEvidence() {
        let cases: [(String, AgentTool)] = [
            ("claude/refactor-auth", .claudeCode),
            ("worktree-refactor-auth", .claudeCode),
            ("cursor/cleanup", .cursor),
            ("codex/cleanup", .codex),
        ]
        for (branch, tool) in cases {
            let detection = AgentDetector.detect(path: "/Users/me/wt/x", branch: branch)
            XCTAssertEqual(detection?.tool, tool, branch)
            XCTAssertEqual(detection?.basis, .branch, branch)
            XCTAssertTrue(detection?.label.hasPrefix("Probably ") == true)
        }
    }

    func testPathWinsOverBranch() {
        let detection = AgentDetector.detect(
            path: "/Users/me/.codex/worktrees/1a2b/api", branch: "claude/something")
        XCTAssertEqual(detection?.tool, .codex)
        XCTAssertEqual(detection?.label, "Codex")
    }

    func testOrdinaryWorktreesAreNotAgents() {
        XCTAssertNil(AgentDetector.detect(path: "/Users/me/code/api-hotfix", branch: "hotfix/login"))
        XCTAssertNil(AgentDetector.detect(path: "/Users/me/code/api-hotfix", branch: nil))
    }

    func testAgentHintKeepsReturningTheToolName() {
        XCTAssertEqual(AgentHint.detect(path: "/a/.claude/worktrees/x", branch: nil), "Claude Code")
        XCTAssertEqual(AgentHint.detect(path: "/a/wt", branch: "claude/x"), "Claude Code")
        XCTAssertNil(AgentHint.detect(path: "/a/wt", branch: "feat/x"))
    }
}

import ArgumentParser
import XCTest
@testable import Lopper
@testable import LopperCLI

final class AgentsTests: XCTestCase {
    private func harness() throws -> Harness {
        let harness = try Harness()
        try harness.addAgentWorktrees()
        // No grace period, so the worktrees count as idle straight away.
        var settings = Settings(roots: [harness.repo.sandbox], scanDepth: 3)
        settings.agentFinishedGraceMinutes = 0
        try settings.save(to: harness.settingsURL)
        return harness
    }

    func testAgentsListsTheToolAndTheStateOfEachWorktree() async throws {
        let harness = try harness()
        let result = try await harness.run(["agents"])

        XCTAssertTrue(result.out.contains("2 agent worktrees: 1 finished"), result.out)
        XCTAssertTrue(result.out.contains("Claude Code"), result.out)
        XCTAssertTrue(result.out.contains("Finished"), result.out)
        // The harness clock is months ahead, so the worktree with work only on itself reads as abandoned.
        XCTAssertTrue(result.out.contains("Abandoned"), result.out)
        XCTAssertTrue(result.out.contains("--reclaim-finished"), result.out)
    }

    func testAgentsJSONReportsToolTotalsAndEligibility() async throws {
        let harness = try harness()
        let result = try await harness.run(["agents", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["total"] as? Int, 2)
        XCTAssertEqual(object["finished"] as? Int, 1)
        let tools = try XCTUnwrap(object["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["tool"] as? String, "claudeCode")
        XCTAssertEqual(tools.first?["count"] as? Int, 2)
    }

    func testReclaimFinishedRemovesOnlyTheFinishedWorktree() async throws {
        let harness = try harness()
        let finished = harness.repo.sandbox.appendingPathComponent(".claude/worktrees/finished")
        let unmerged = harness.repo.sandbox.appendingPathComponent(".claude/worktrees/unmerged")

        let result = try await harness.run(["agents", "--reclaim-finished", "--yes"])

        XCTAssertTrue(result.out.contains("removed"), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmerged.path), "unmerged agent work must stay")
        XCTAssertTrue(try harness.branches().contains("claude/unmerged"))
    }

    func testReclaimFinishedNeedsConfirmation() async throws {
        let harness = try harness()
        let finished = harness.repo.sandbox.appendingPathComponent(".claude/worktrees/finished")
        do {
            try await harness.run(["agents", "--reclaim-finished"])
            XCTFail("expected a refusal")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--yes"), error.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
    }
}


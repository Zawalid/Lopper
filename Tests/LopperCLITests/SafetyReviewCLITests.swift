import ArgumentParser
import XCTest
@testable import Lopper
@testable import LopperCLI

/// Independent safety review reproductions at the command line. Each test asserts the SAFE behaviour.
final class SafetyReviewCLITests: XCTestCase {
    private func run(_ harness: Harness, _ arguments: [String], now: Date) async throws -> String {
        let console = TestConsole(interactive: false)
        let context = CLIContext(
            console: console, settingsURL: harness.settingsURL,
            undoLogURL: harness.support.appendingPathComponent("undo-log.jsonl"),
            detectPullRequests: false,
            trash: FolderTrash(folder: harness.repo.sandbox.appendingPathComponent("FakeTrash")), now: { now })
        try await CLIContext.$current.withValue(context) {
            var command = try Lop.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
        return console.out
    }

    /// A Claude Code worktree that is mid-task (state Active, clean tree, one commit not yet merged) must survive
    /// `lop clean --include-review --repo ... --yes`.
    func testIncludeReviewDoesNotRemoveAnAgentWorktreeThatIsStillActive() async throws {
        let harness = try Harness()
        let live = harness.repo.sandbox.appendingPathComponent(".claude/worktrees/live")
        try harness.repo.git("worktree", "add", "-b", "claude/live", live.path)
        try harness.repo.commit("agent just committed", files: ["x.txt": "x"], in: live)

        let out = try await run(harness, ["clean", "--include-review", "--yes", "--repo", "repo"], now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "folder of an Active agent removed:\n\(out)")
    }

    /// `--include-review` is documented as needing "a name", so it "can never be a blanket removal". A one
    /// character query matches by substring (against the title AND the folder path), so it is one.
    func testIncludeReviewWithAOneCharacterQueryIsNotABlanketRemoval() async throws {
        let harness = try Harness()
        try harness.addAgentWorktrees()
        let unmerged = harness.repo.sandbox.appendingPathComponent(".claude/worktrees/unmerged")

        var out = ""
        do {
            out = try await run(harness, ["clean", "--include-review", "--yes", "/"], now: Harness.fixedNow)
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("at least 3"), error.message)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: unmerged.path), "removed by query \"/\":\n\(out)")
    }
}

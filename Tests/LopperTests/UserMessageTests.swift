import XCTest
@testable import Lopper

final class UserMessageTests: XCTestCase {
    func testGitFailuresAreExplainedWithoutCommandLinesOrExitCodes() {
        let message = UserMessage.describe(CommandError.failed(
            command: "git worktree list --porcelain -z", exitCode: 128,
            stderr: "fatal: not a git repository (or any of the parent directories): .git"))

        XCTAssertFalse(message.contains("worktree list"))
        XCTAssertFalse(message.contains("128"))
        XCTAssertFalse(message.contains("fatal:"))
        XCTAssertTrue(message.contains("not a git repository"))
    }

    func testTimeoutsAndLaunchFailuresTellThePersonWhatToDo() {
        XCTAssertTrue(UserMessage.describe(CommandError.timedOut(command: "git status")).contains("too long"))
        XCTAssertTrue(UserMessage.describe(CommandError.launchFailed("posix 2")).lowercased().contains("command line tools"))
    }

    func testRefusalsAndUnknownErrorsHaveGenericPlainSentences() {
        XCTAssertTrue(UserMessage.describe(CleanError.movedAfterVerification("x")).contains("changed"))
        XCTAssertTrue(UserMessage.describe(CleanError.checkedOut("/w")).contains("worktree"))
        XCTAssertEqual(UserMessage.describe(CancellationError()), "Cancelled.")
        struct Odd: Error {}
        XCTAssertEqual(UserMessage.describe(Odd()), "Something unexpected went wrong.")
    }

    func testScanFailuresCarryAPlainMessageNotADebugDump() async throws {
        let fixture = try TestRepo()
        let broken = fixture.sandbox.appendingPathComponent("broken")
        try FileManager.default.createDirectory(
            at: broken.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let results = await ScanService(inspector: RepoInspector()).inspect(repos: [broken])

        guard case .failure(_, let message) = try XCTUnwrap(results.first) else { return XCTFail() }
        XCTAssertFalse(message.contains("CommandError"), message)
        XCTAssertFalse(message.contains("exitCode"), message)
    }
}

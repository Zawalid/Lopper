import XCTest
@testable import Lopper

final class GitRunnerTests: XCTestCase {
    func testRunReturnsStdoutAndExitCode() async throws {
        let repo = try TestRepo()
        try repo.commit("first", files: ["a.txt": "a"])
        let output = try await GitRunner().run(["rev-parse", "--abbrev-ref", "HEAD"], in: repo.root)
        XCTAssertEqual(output.stdout.trimmingCharacters(in: .newlines), "main")
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.succeeded)
    }

    func testRunReportsNonZeroExitWithoutThrowing() async throws {
        let repo = try TestRepo()
        let output = try await GitRunner().run(["rev-parse", "--verify", "no-such-ref"], in: repo.root)
        XCTAssertFalse(output.succeeded)
    }

    func testRunCheckedThrowsOnFailure() async throws {
        let repo = try TestRepo()
        do {
            try await GitRunner().runChecked(["rev-parse", "--verify", "no-such-ref"], in: repo.root)
            XCTFail("expected failure")
        } catch let CommandError.failed(command, exitCode, _) {
            XCTAssertTrue(command.contains("rev-parse"))
            XCTAssertNotEqual(exitCode, 0)
        }
    }

    func testTimeoutKillsTheProcess() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: .milliseconds(200))
        let started = ContinuousClock.now
        do {
            _ = try await runner.run(["5"])
            XCTFail("expected timeout")
        } catch let CommandError.timedOut(command) {
            XCTAssertTrue(command.contains("sleep"))
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
    }

    func testLargeOutputDoesNotDeadlock() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/usr/bin/yes"), timeout: .seconds(1))
        // `yes` never ends on its own; the timeout must still return even while the pipe is full.
        do {
            _ = try await runner.run([])
            XCTFail("expected timeout")
        } catch CommandError.timedOut {
            // expected
        }
    }

    func testLaunchFailureIsReported() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/no/such/binary"))
        do {
            _ = try await runner.run([])
            XCTFail("expected launch failure")
        } catch CommandError.launchFailed {
            // expected
        }
    }

    func testCancellingTheCallerKillsTheProcessAndThrowsCancellation() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: .seconds(30))
        let started = ContinuousClock.now
        let task = Task { try await runner.run(["10"]) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }
}

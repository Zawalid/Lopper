import XCTest
@testable import Lopper

/// A scan runs tens of thousands of git commands. Each one must give its file descriptors back as soon as it
/// finishes, or a large scan runs out of them and every later repository fails with "could not start git".
final class CommandRunnerDescriptorTests: XCTestCase {
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    /// The count after the commands settle. A pipe is closed when its last reference goes, which on a slow or busy
    /// machine can trail the command by a moment, so a leak is a count that never comes back down, not one read at once.
    private func settledGrowth(since before: Int) async -> Int {
        var growth = openDescriptors() - before
        for _ in 0..<50 where growth >= 20 {
            try? await Task.sleep(for: .milliseconds(100))
            growth = openDescriptors() - before
        }
        return growth
    }

    func testFinishedCommandsDoNotKeepDescriptorsOpen() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(60))
        _ = try await runner.run([])
        let before = openDescriptors()

        for _ in 0..<150 { _ = try await runner.run([]) }

        let growth = await settledGrowth(since: before)
        XCTAssertLessThan(growth, 20, "descriptors grew by \(growth) over 150 finished commands and stayed open")
    }

    func testConcurrentCommandsAlsoGiveDescriptorsBack() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(60))
        _ = try await runner.run([])
        let before = openDescriptors()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 { group.addTask { _ = try? await runner.run([]) } }
        }

        let growth = await settledGrowth(since: before)
        XCTAssertLessThan(growth, 20, "descriptors grew by \(growth) after 200 concurrent commands and stayed open")
    }

    func testATimeoutStillStopsALongCommand() async {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/bin/sleep"), timeout: .milliseconds(300))
        do {
            _ = try await runner.run(["30"])
            XCTFail("expected a timeout")
        } catch CommandError.timedOut {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

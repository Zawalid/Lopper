import XCTest
@testable import Lopper

/// A scan runs tens of thousands of git commands. Each one must give its file descriptors back as soon as it
/// finishes, or a large scan runs out of them and every later repository fails with "could not start git".
final class CommandRunnerDescriptorTests: XCTestCase {
    private func openDescriptors() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1
    }

    func testFinishedCommandsDoNotKeepDescriptorsOpen() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(60))
        _ = try await runner.run([])
        let before = openDescriptors()

        for _ in 0..<150 { _ = try await runner.run([]) }

        let after = openDescriptors()
        XCTAssertLessThan(after - before, 20, "descriptors grew from \(before) to \(after) over 150 finished commands")
    }

    func testConcurrentCommandsAlsoGiveDescriptorsBack() async throws {
        let runner = CommandRunner(executable: URL(fileURLWithPath: "/usr/bin/true"), timeout: .seconds(60))
        _ = try await runner.run([])
        let before = openDescriptors()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<200 { group.addTask { _ = try? await runner.run([]) } }
        }

        let after = openDescriptors()
        XCTAssertLessThan(after - before, 20, "descriptors grew from \(before) to \(after)")
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

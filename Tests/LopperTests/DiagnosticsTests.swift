import XCTest
@testable import Lopper

final class DiagnosticsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var logURL: URL!

    override func setUp() {
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("lopper-diag-\(UUID().uuidString).log")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    // MARK: Scrubbing

    func testTheHomeFolderAndOtherAccountsBecomeATilde() {
        XCTAssertEqual(DiagnosticScrubber.scrub("cannot read /Users/walid/Code/acme", home: "/Users/walid"), "cannot read ~/Code/acme")
        XCTAssertEqual(DiagnosticScrubber.scrub("/Users/someone/else/x", home: "/Users/walid"), "~/else/x")
    }

    func testCredentialsInRemoteAddressesAreRemoved() {
        let text = "fetch https://walid:ghp_abcdefghijklmnopqrstuvwxyz123456@github.com/acme/api.git failed"
        let scrubbed = DiagnosticScrubber.scrub(text, home: "/Users/x")
        XCTAssertEqual(scrubbed, "fetch https://github.com/acme/api.git failed")
    }

    func testTokensAndEmailAddressesAreRemoved() {
        let scrubbed = DiagnosticScrubber.scrub(
            "token ghp_abcdefghijklmnopqrstuvwxyz123456 and github_pat_11ABCDEFG0abcdefghijklmnop and walid@zawalid.com and git@github.com:acme/api.git",
            home: "/Users/x")
        XCTAssertFalse(scrubbed.contains("ghp_"), scrubbed)
        XCTAssertFalse(scrubbed.contains("github_pat_"), scrubbed)
        XCTAssertFalse(scrubbed.contains("zawalid.com"), scrubbed)
        XCTAssertFalse(scrubbed.contains("walid@"), scrubbed)
        XCTAssertTrue(scrubbed.contains("<token>") && scrubbed.contains("<email>"), scrubbed)
    }

    func testNamesBecomeStableStandInsAndOnlyWholeNamesAreReplaced() {
        let text = "branch feature/login-page in acme-api was skipped; rapid and acme-api-gateway are other things; main is fine"
        let result = DiagnosticScrubber.pseudonymize(
            text, repositories: ["acme-api", "api"], branches: ["feature/login-page", "feature", "main"])

        XCTAssertFalse(result.contains("feature/login-page"), result)
        XCTAssertFalse(result.contains("in acme-api "), result)
        XCTAssertTrue(result.contains("rapid"), "a name inside another word stays: \(result)")
        XCTAssertTrue(result.contains("acme-api-gateway"), "a longer name that merely starts with it stays: \(result)")
        XCTAssertTrue(result.contains("main is fine"), "main says nothing about the work: \(result)")
        XCTAssertTrue(result.contains("branch-") && result.contains("repo-"), result)
    }

    // MARK: Log

    func testRecordingScrubsTheMessage() async {
        let log = DiagnosticLog(url: logURL)
        await log.record(DiagnosticEvent(timestamp: now, kind: .scanFailure, message: "could not read /Users/walid/Code (walid@zawalid.com)"))

        let events = await log.events(now: now)

        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(events[0].message.contains("walid@"), events[0].message)
        XCTAssertFalse(events[0].message.contains("/Users/walid"), events[0].message)
    }

    func testTheLogStaysUnderItsCap() async throws {
        let log = DiagnosticLog(url: logURL)
        for index in 0..<720 {
            await log.record(DiagnosticEvent(timestamp: now, kind: .cleanProblem, message: "problem \(index)"))
        }

        let events = await log.events(now: now)

        XCTAssertLessThanOrEqual(events.count, DiagnosticLog.maxEvents)
        XCTAssertEqual(events.last?.message, "problem 719", "the newest events are the ones kept")
        let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").count
        XCTAssertLessThanOrEqual(lines, DiagnosticLog.maxEvents + 100 + 1, "the file itself is compacted")
    }

    func testOldEventsAreLeftOut() async {
        let log = DiagnosticLog(url: logURL)
        await log.record(DiagnosticEvent(timestamp: now.addingTimeInterval(-40 * 86_400), kind: .cleanProblem, message: "old"))
        await log.record(DiagnosticEvent(timestamp: now.addingTimeInterval(-86_400), kind: .cleanProblem, message: "recent"))

        let events = await log.events(now: now)

        XCTAssertEqual(events.map(\.message), ["recent"])
    }

    func testADamagedLineIsSkippedNotFatal() async throws {
        let log = DiagnosticLog(url: logURL)
        await log.record(DiagnosticEvent(timestamp: now, kind: .cleanProblem, message: "first"))
        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        await log.record(DiagnosticEvent(timestamp: now, kind: .cleanProblem, message: "second"))

        let events = await log.events(now: now)

        XCTAssertEqual(events.map(\.message), ["first", "second"])
    }

    // MARK: Report

    private func input() -> DiagnosticsInput {
        let record = UndoRecord(
            timestamp: now, repoPath: "/Users/walid/Code/acme-api", action: .deleteBranch, branch: "feature/login",
            tip: "abc", upstream: nil, worktreePath: nil, trashRef: "", status: .completed)
        return DiagnosticsInput(
            appVersion: "0.3.0 (7)", osVersion: "15.2", architecture: "arm64", gitVersion: "2.54.0", gitHubCLIVersion: nil,
            setupProblems: ["1 folder cannot be opened"], settings: Settings(roots: [URL(fileURLWithPath: "/Users/walid/Code")]),
            folderAccess: [.ok, .denied], history: [record, record],
            events: [
                DiagnosticEvent(timestamp: now, kind: .scanFinished, message: "", numbers: ["repositories": 12, "failures": 1, "scanSeconds": 4.2, "sizeSeconds": 1.14]),
                DiagnosticEvent(timestamp: now, kind: .cleanProblem, message: "feature/login in acme-api: Someone pushed to feature/login"),
            ],
            repositoryNames: ["acme-api"], branchNames: ["feature/login"], now: now)
    }

    func testTheReportLeavesNamesOutByDefault() {
        let text = DiagnosticsReport.text(input(), includeNames: false)

        XCTAssertTrue(text.contains("Names: left out"), text)
        XCTAssertFalse(text.contains("acme-api"), text)
        XCTAssertFalse(text.contains("feature/login"), text)
        XCTAssertTrue(text.contains("repo-1") && text.contains("branch-1"), text)
    }

    func testTheReportCanIncludeNamesButNeverSecrets() {
        var data = input()
        data.events.append(DiagnosticEvent(timestamp: now, kind: .scanFailure, message: "fetch https://walid:ghp_abcdefghijklmnopqrstuvwxyz123456@github.com/acme/api.git"))

        let text = DiagnosticsReport.text(data, includeNames: true)

        XCTAssertTrue(text.contains("acme-api") && text.contains("feature/login"), text)
        XCTAssertFalse(text.contains("ghp_"), text)
        XCTAssertFalse(text.contains("walid:"), text)
    }

    func testTheReportSaysWhatMattersForSupport() {
        let text = DiagnosticsReport.text(input(), includeNames: false)

        XCTAssertTrue(text.contains("Lopper: 0.3.0 (7)"), text)
        XCTAssertTrue(text.contains("macOS: 15.2 (arm64)"), text)
        XCTAssertTrue(text.contains("git: 2.54.0"), text)
        XCTAssertTrue(text.contains("GitHub CLI: not found"), text)
        XCTAssertTrue(text.contains("1 folder cannot be opened"), text)
        XCTAssertTrue(text.contains("1 readable, 1 no access"), text)
        XCTAssertTrue(text.contains("12 repositories, 1 failed, scan 4.2s, sizes 1.1s"), text)
        XCTAssertTrue(text.contains("deleteBranch completed: 2"), text)
        XCTAssertFalse(text.contains("/Users/walid"), "no folder paths in the report: \(text)")
    }

    func testAnEmptyReportStillReads() {
        let empty = DiagnosticsInput(
            appVersion: "dev", osVersion: "15", architecture: "arm64", gitVersion: nil, gitHubCLIVersion: nil,
            setupProblems: [], settings: Settings(), folderAccess: [], history: [], events: [],
            repositoryNames: [], branchNames: [], now: now)
        let text = DiagnosticsReport.text(empty, includeNames: false)
        XCTAssertTrue(text.contains("git: not found"), text)
        XCTAssertTrue(text.contains("no problems") && text.contains("none recorded") && text.contains("no removals"), text)
    }
}

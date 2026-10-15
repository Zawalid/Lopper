import XCTest
@testable import Lopper

final class ReinstallerTests: XCTestCase {
    private var sandbox: URL!
    private var bin: URL!
    private var project: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-reinstall-\(UUID().uuidString)", isDirectory: true)
        bin = sandbox.appendingPathComponent("bin", isDirectory: true)
        project = sandbox.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func fakeTool(_ name: String, script: String) throws {
        let url = bin.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func reinstaller() -> Reinstaller {
        Reinstaller(
            shell: URL(fileURLWithPath: "/bin/sh"), shellArguments: ["-c"],
            environment: ["PATH": bin.path + ":/usr/bin:/bin"], timeout: .seconds(20))
    }

    func testOnlyInstallCommandsLopperKnowsAreSupported() {
        XCTAssertTrue(Reinstaller.isSupported("npm ci"))
        XCTAssertTrue(Reinstaller.isSupported("pnpm install"))
        XCTAssertTrue(Reinstaller.isSupported("yarn install"))
        XCTAssertFalse(Reinstaller.isSupported("your next build or dev run"))
        XCTAssertFalse(Reinstaller.isSupported("npm ci && echo extra"))
    }

    func testItRunsTheLockfileInstallInsideTheProject() async throws {
        let marker = sandbox.appendingPathComponent("ran.txt")
        try fakeTool("npm", script: "echo \"$@ in $(pwd -P)\" > \"\(marker.path)\"")

        let outcome = await reinstaller().reinstall(in: project, how: "npm ci")

        XCTAssertEqual(outcome, .done)
        let text = try String(contentsOf: marker, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("ci in "), text)
        XCTAssertTrue(text.contains(project.resolvingSymlinksInPath().path), text)
    }

    func testAFailureCarriesTheEndOfTheErrorOutput() async throws {
        try fakeTool("npm", script: "echo 'ERR! lockfile out of date' >&2; exit 1")

        let outcome = await reinstaller().reinstall(in: project, how: "npm ci")

        guard case .failed(let message) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(message.contains("lockfile out of date"), message)
    }

    func testAnUnknownCommandIsNeverRun() async throws {
        let marker = sandbox.appendingPathComponent("ran.txt")
        try fakeTool("npm", script: "touch \"\(marker.path)\"")

        let outcome = await reinstaller().reinstall(in: project, how: "your next build or dev run")

        XCTAssertEqual(outcome, .unsupported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testAMissingFolderIsReportedNotRun() async {
        let outcome = await reinstaller().reinstall(in: sandbox.appendingPathComponent("gone"), how: "npm ci")
        guard case .failed = outcome else { return XCTFail("\(outcome)") }
    }
}

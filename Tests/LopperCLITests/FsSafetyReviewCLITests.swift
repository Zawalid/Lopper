import ArgumentParser
import XCTest
@testable import Lopper
@testable import LopperCLI

final class FsSafetyReviewCLITests: XCTestCase {
    /// F14: `--untouched-days` is documented as "projects nobody has edited for N days" but filters on the newest
    /// file INSIDE the generated folder. A project edited yesterday whose node_modules was installed long ago is
    /// cleared by `lop disk --clear --untouched-days 30 --yes`.
    func testUntouchedDaysLooksAtTheProjectNotAtTheGeneratedFolder() async throws {
        let harness = try Harness()
        try harness.repo.commit("deps", files: [".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        let modules = harness.repo.root.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        let file = modules.appendingPathComponent("index.js")
        try Data(count: 60_000).write(to: file)
        let old = Harness.fixedNow.addingTimeInterval(-90 * 86_400)
        let yesterday = Harness.fixedNow.addingTimeInterval(-86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: modules.path)
        // The person edited their own source yesterday.
        let source = harness.repo.root.appendingPathComponent("app.txt")
        try "edited yesterday".write(to: source, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: yesterday], ofItemAtPath: source.path)

        _ = try await harness.run(["disk", "--clear", "--untouched-days", "30", "--yes"])

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: harness.repo.root.appendingPathComponent("node_modules").path),
            "node_modules of a project edited yesterday was cleared by --untouched-days 30")
    }

    /// F11 (CLI half): corrupt settings are silently replaced by defaults for the run, so the person's own
    /// protected patterns are not honoured and `lop clean --yes` removes a branch they protected.
    func testCorruptSettingsDoNotDropTheUsersProtectedPatternsDuringClean() async throws {
        let harness = try Harness()
        try """
        {"schemaVersion":2,"protectedPatterns":["done"],"scanDepth":"3","folders":[]}
        """.write(to: harness.settingsURL, atomically: true, encoding: .utf8)

        do {
            _ = try await harness.run(["clean", "--yes", "--folder", harness.repo.sandbox.path])
            XCTFail("a clean must not run on settings it could not fully read")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("could not be read"), error.message)
        }

        XCTAssertTrue(try harness.branches().contains("done"), "branch protected in settings.json was deleted")
    }
}

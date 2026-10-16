import ArgumentParser
import XCTest
@testable import Lopper
@testable import LopperCLI

final class DiskFoldersDoctorTests: XCTestCase {
    /// The harness repository with a git-ignored node_modules (and the lockfile that makes it reinstallable).
    private func harnessWithModules() throws -> Harness {
        let harness = try Harness()
        try harness.repo.commit("deps", files: [".gitignore": "node_modules\n", "package.json": "{}\n", "package-lock.json": "{}\n"])
        let modules = harness.repo.root.appendingPathComponent("node_modules/pkg")
        try FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try Data(count: 60_000).write(to: modules.appendingPathComponent("index.js"))
        return harness
    }

    func testDiskListsGeneratedFoldersAndWhatCanBeCleared() async throws {
        let harness = try harnessWithModules()
        let result = try await harness.run(["disk"])

        XCTAssertTrue(result.out.contains("node_modules"), result.out)
        XCTAssertTrue(result.out.contains("can be cleared"), result.out)
    }

    func testDiskJSONMarksWhichFoldersAreOffered() async throws {
        let harness = try harnessWithModules()
        let result = try await harness.run(["disk", "--json"])

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        let folders = try XCTUnwrap(object["folders"] as? [[String: Any]])
        let folder = try XCTUnwrap(folders.first { $0["name"] as? String == "node_modules" })
        XCTAssertEqual(folder["offered"] as? Bool, true)
        XCTAssertGreaterThan(folder["bytes"] as? Int ?? 0, 0)
    }

    func testClearNeedsConfirmationAndThenMovesTheFolderToTheTrash() async throws {
        let harness = try harnessWithModules()
        let modules = harness.repo.root.appendingPathComponent("node_modules")
        do {
            try await harness.run(["disk", "--clear"])
            XCTFail("expected a refusal")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("--yes"), error.message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path))

        let result = try await harness.run(["disk", "--clear"], interactive: true, answers: ["y"])

        XCTAssertTrue(result.out.contains("Moved 1 folder to the Trash"), result.out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modules.path))

        try await harness.run(["undo", "--last"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: modules.path), "undo puts the folder back")
    }

    func testClearDryRunChangesNothing() async throws {
        let harness = try harnessWithModules()
        let result = try await harness.run(["disk", "--clear", "--dry-run"])
        XCTAssertTrue(result.out.contains("Dry run"), result.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.repo.root.appendingPathComponent("node_modules").path))
    }

    func testFoldersAddListAndRemove() async throws {
        let harness = try Harness(foldersConfigured: false)
        let folder = harness.repo.sandbox.appendingPathComponent("code")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let empty = try await harness.run(["folders"])
        XCTAssertTrue(empty.out.contains("No folders yet"), empty.out)

        let added = try await harness.run(["folders", "add", folder.path])
        XCTAssertTrue(added.out.contains("Added"), added.out)
        let listed = try await harness.run(["folders", "list"])
        XCTAssertTrue(listed.out.contains(folder.resolvingSymlinksInPath().path), listed.out)

        let again = try await harness.run(["folders", "add", folder.path])
        XCTAssertTrue(again.out.contains("already in the list"), again.out)

        let removed = try await harness.run(["folders", "remove", folder.path])
        XCTAssertTrue(removed.out.contains("not touched"), removed.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "removing a folder from the list never deletes it")
    }

    func testFoldersAddRefusesANonFolder() async throws {
        let harness = try Harness(foldersConfigured: false)
        do {
            try await harness.run(["folders", "add", "/definitely/not/here"])
            XCTFail("expected an error")
        } catch let error as ValidationError {
            XCTAssertTrue(error.message.contains("not a folder"), error.message)
        }
    }

    func testDoctorReportsGitFoldersAndFiles() async throws {
        let harness = try Harness()
        let result = try await harness.run(["doctor"])

        XCTAssertTrue(result.out.contains("git"), result.out)
        XCTAssertTrue(result.out.contains("settings"), result.out)
        XCTAssertTrue(result.out.contains("undo log"), result.out)
        XCTAssertTrue(result.out.contains(harness.repo.sandbox.path), result.out)
    }

    func testDoctorFailsWhenNoFolderIsConfigured() async throws {
        let harness = try Harness(foldersConfigured: false)
        do {
            try await harness.run(["doctor"])
            XCTFail("expected a failing exit")
        } catch let code as ExitCode {
            XCTAssertEqual(code.rawValue, 1)
        }
    }
}

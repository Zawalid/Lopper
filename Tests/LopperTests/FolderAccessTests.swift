import XCTest
@testable import Lopper

final class FolderAccessTests: XCTestCase {
    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("lopper-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore permissions first so the folder can be removed.
        if let children = try? FileManager.default.contentsOfDirectory(atPath: sandbox.path) {
            for child in children {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.appendingPathComponent(child).path)
            }
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testReadableFolderIsOk() {
        XCTAssertEqual(FolderProbe.check(sandbox), .ok)
    }

    func testMissingFolderIsMissing() {
        XCTAssertEqual(FolderProbe.check(sandbox.appendingPathComponent("gone")), .missing)
    }

    func testFileIsNotAFolder() throws {
        let file = sandbox.appendingPathComponent("a.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(FolderProbe.check(file), .notAFolder)
    }

    func testFolderWithoutPermissionIsDenied() throws {
        try XCTSkipIf(getuid() == 0, "root can read anything")
        let locked = sandbox.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        XCTAssertEqual(FolderProbe.check(locked), .denied)
    }

    func testCheckingSeveralFoldersKeysThemByCanonicalPath() throws {
        let good = sandbox.appendingPathComponent("good")
        try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
        let missing = sandbox.appendingPathComponent("missing")
        let result = FolderProbe.check([good, missing])
        XCTAssertEqual(result[good.canonicalized.path], .ok)
        XCTAssertEqual(result[missing.canonicalized.path], .missing)
    }

    func testGitIsMissingWithoutAnActiveDeveloperDirectory() {
        XCTAssertFalse(GitAvailability.isInstalled(developerDirectory: { nil }, fileExists: { _ in true }))
    }

    func testGitIsMissingWhenTheDeveloperDirectoryHasNoGit() {
        XCTAssertFalse(GitAvailability.isInstalled(developerDirectory: { "/Library/Developer/CommandLineTools" }, fileExists: { _ in false }))
    }

    func testGitIsInstalledWhenTheDeveloperDirectoryHoldsIt() {
        var asked: String?
        let installed = GitAvailability.isInstalled(
            developerDirectory: { "/Library/Developer/CommandLineTools" }, fileExists: { asked = $0; return true })
        XCTAssertTrue(installed)
        XCTAssertEqual(asked, "/Library/Developer/CommandLineTools/usr/bin/git")
    }
}

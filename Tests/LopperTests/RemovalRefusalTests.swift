import XCTest
@testable import Lopper

final class RemovalRefusalTests: XCTestCase {
    // MARK: Classifying what git said

    func testGitsRefusalOverChangedFilesIsClassifiedAsChanges() {
        let message = "git couldn't complete this step: '/code/api-wt' contains modified or untracked files, use --force to delete it"

        XCTAssertEqual(RemovalRefusal.classify(message), .hasChanges)
    }

    func testLoppersOwnFolderOnlyWorkRefusalIsClassifiedAsChanges() {
        XCTAssertEqual(
            RemovalRefusal.classify("Work that exists only in this folder appeared after you reviewed it"), .hasChanges)
    }

    func testLockedAndSubmoduleRefusalsAreRecognised() {
        XCTAssertEqual(RemovalRefusal.classify("git couldn't complete this step: cannot remove a locked working tree"), .locked)
        XCTAssertEqual(RemovalRefusal.classify("The worktree is locked"), .locked)
        XCTAssertEqual(
            RemovalRefusal.classify("git couldn't complete this step: working trees containing submodules cannot be moved or removed"),
            .submodules)
    }

    func testAnItemThatChangedAfterReviewIsClassifiedAsMoved() {
        XCTAssertEqual(
            RemovalRefusal.classify("This item changed after you reviewed it, so it was left alone."), .changedSinceReview)
    }

    func testAnythingElseIsOtherAndKeepsTheOriginalWords() {
        XCTAssertEqual(RemovalRefusal.classify("Something unexpected went wrong."), .other)
    }

    func testOnlyAFolderWithChangesCanBeRemovedKeepingACopy() {
        XCTAssertTrue(RemovalRefusal.hasChanges.allowsKeepingACopy)
        for other in [RemovalRefusal.locked, .submodules, .changedSinceReview, .other] {
            XCTAssertFalse(other.allowsKeepingACopy, "\(other) must never offer to move the folder away")
        }
    }

    func testEveryRefusalHasAPlainSentenceWithoutGitJargon() {
        for refusal in [RemovalRefusal.hasChanges, .locked, .submodules, .changedSinceReview, .other] {
            let sentence = refusal.sentence
            XCTAssertFalse(sentence.isEmpty)
            XCTAssertFalse(sentence.contains("--force"), "\(refusal) must not mention --force")
        }
    }

    // MARK: Reading the files that block a removal

    func testTheChangesReaderListsModifiedAndUntrackedFilesWithTheirKind() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", "gone.txt": "bye\n"])
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        try "changed".write(to: wt.appendingPathComponent("app.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: wt.appendingPathComponent("gone.txt"))
        try "new".write(to: wt.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let changes = await WorktreeChanges.read(at: wt)

        let byPath = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, $0.kind) })
        XCTAssertEqual(byPath["app.txt"], .modified)
        XCTAssertEqual(byPath["gone.txt"], .deleted)
        XCTAssertEqual(byPath["notes.md"], .untracked)
        XCTAssertEqual(changes.total, 3)
        XCTAssertEqual(changes.hiddenCount, 0)
    }

    func testTheChangesReaderListsFilesInsideANewFolderOneByOne() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        let folder = wt.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "a".write(to: folder.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: folder.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let changes = await WorktreeChanges.read(at: wt)

        XCTAssertEqual(Set(changes.files.map(\.path)), ["notes/a.md", "notes/b.md"])
    }

    func testTheChangesReaderCapsTheListAndCountsTheRest() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        for index in 0..<12 {
            try "x".write(to: wt.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
        }

        let changes = await WorktreeChanges.read(at: wt, limit: 5)

        XCTAssertEqual(changes.files.count, 5)
        XCTAssertEqual(changes.total, 12)
        XCTAssertEqual(changes.hiddenCount, 7)
    }

    func testTheChangesReaderIgnoresIgnoredFilesBecauseGitDoesNotCountThem() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n", ".gitignore": "node_modules\n"])
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        try FileManager.default.createDirectory(
            at: wt.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
        try "x".write(to: wt.appendingPathComponent("node_modules/pkg/i.js"), atomically: true, encoding: .utf8)

        let changes = await WorktreeChanges.read(at: wt)

        XCTAssertTrue(changes.files.isEmpty)
        XCTAssertEqual(changes.total, 0)
    }

    func testTheChangesReaderGivesAnEmptyAnswerForAFolderThatIsGone() async {
        let changes = await WorktreeChanges.read(at: URL(fileURLWithPath: "/nonexistent/lopper-\(UUID().uuidString)"))

        XCTAssertEqual(changes.total, 0)
        XCTAssertTrue(changes.files.isEmpty)
    }

    func testPathsWithSpacesAndAccentsComeBackUnquoted() async throws {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"])
        let wt = repo.sandbox.appendingPathComponent("wt")
        try repo.git("worktree", "add", "-b", "feature", wt.path)
        try "x".write(to: wt.appendingPathComponent("café notes.txt"), atomically: true, encoding: .utf8)

        let changes = await WorktreeChanges.read(at: wt)

        XCTAssertEqual(changes.files.map(\.path), ["café notes.txt"])
    }
}

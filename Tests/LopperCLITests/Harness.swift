import ArgumentParser
import Foundation
import XCTest
@testable import Lopper
@testable import LopperCLI

/// A console that records what a command prints and answers its questions from a script.
final class TestConsole: Console, @unchecked Sendable {
    private let lock = NSLock()
    private var output = ""
    private var errors = ""
    private var answers: [String]
    let isInteractive: Bool
    let useColor = false

    init(interactive: Bool = false, answers: [String] = []) {
        self.isInteractive = interactive
        self.answers = answers
    }

    var out: String { lock.lock(); defer { lock.unlock() }; return output }
    var err: String { lock.lock(); defer { lock.unlock() }; return errors }

    func write(_ text: String) { lock.lock(); output += text; lock.unlock() }
    func writeError(_ text: String) { lock.lock(); errors += text; lock.unlock() }
    func readLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

/// A repository with a merged branch ("done"), a branch with work only on itself ("wip"), and a settings file
/// and undo log in a throwaway folder, so commands run end to end against real git without touching real data.
struct Harness {
    let repo: TestRepo
    let support: URL
    static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    init(foldersConfigured: Bool = true) throws {
        repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "base\n"], date: Harness.fixedNow.addingTimeInterval(-90 * 86_400))
        try repo.addOrigin()
        try repo.git("checkout", "-b", "done")
        try repo.commit("done work", files: ["done.txt": "d"], date: Harness.fixedNow.addingTimeInterval(-60 * 86_400))
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge done", "done")
        try repo.git("push", "origin", "main")
        try repo.git("checkout", "-b", "wip")
        try repo.commit("wip work", files: ["wip.txt": "w"], date: Harness.fixedNow.addingTimeInterval(-3 * 86_400))
        try repo.git("checkout", "main")
        support = repo.sandbox.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        if foldersConfigured {
            try Settings(roots: [repo.sandbox], scanDepth: 3).save(to: support.appendingPathComponent("settings.json"))
        }
    }

    var settingsURL: URL { support.appendingPathComponent("settings.json") }

    struct Result { let out: String; let err: String }

    /// Runs `lop <arguments>` and returns what it printed. Throws what the command throws.
    @discardableResult
    func run(_ arguments: [String], interactive: Bool = false, answers: [String] = []) async throws -> Result {
        let console = TestConsole(interactive: interactive, answers: answers)
        let context = CLIContext(
            console: console, settingsURL: settingsURL, undoLogURL: support.appendingPathComponent("undo-log.jsonl"),
            detectPullRequests: false, now: { Harness.fixedNow })
        try await CLIContext.$current.withValue(context) {
            var command = try Lop.parseAsRoot(arguments)
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        }
        return Result(out: console.out, err: console.err)
    }

    func branches() throws -> [String] {
        try repo.git("branch", "--format=%(refname:short)").split(separator: "\n").map(String.init)
    }
}

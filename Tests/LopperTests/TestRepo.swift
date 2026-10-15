import Foundation
@testable import Lopper

/// A throwaway real git repository for tests. Uses synchronous git so test setup reads top to bottom.
final class TestRepo: @unchecked Sendable {
    /// Temp directory holding the repo, the bare origin, and any worktrees a test creates.
    let sandbox: URL
    let root: URL
    let originURL: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Canonical (/var -> /private/var) so paths match what git reports.
        sandbox = base.canonicalized
        root = sandbox.appendingPathComponent("repo", isDirectory: true)
        originURL = sandbox.appendingPathComponent("origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Self.configure(at: root)
    }

    deinit {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// `git init` plus identity and hook settings, so commits never prompt or run user hooks.
    static func configure(at directory: URL) throws {
        try runGit(["init", "-b", "main"], in: directory)
        try runGit(["config", "user.name", "Lopper Test"], in: directory)
        try runGit(["config", "user.email", "test@lopper.invalid"], in: directory)
        try runGit(["config", "commit.gpgsign", "false"], in: directory)
        try runGit(["config", "core.hooksPath", "/dev/null"], in: directory)
    }

    /// Creates a standalone repository with one commit at `url` (used for scanner fixtures).
    static func makeStandaloneRepo(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try configure(at: url)
        try "x".write(to: url.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try runGit(["add", "-A"], in: url)
        try runGit(["commit", "-m", "init"], in: url)
    }

    @discardableResult
    static func runGit(_ arguments: [String], in directory: URL, date: Date? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        if let date {
            let stamp = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_AUTHOR_DATE"] = stamp
            env["GIT_COMMITTER_DATE"] = stamp
        }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TestRepoError.gitFailed(
                arguments.joined(separator: " "), String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Runs git in `directory` (default: the main repo) and returns trimmed stdout.
    @discardableResult
    func git(_ arguments: String..., in directory: URL? = nil, date: Date? = nil) throws -> String {
        try Self.runGit(arguments, in: directory ?? root, date: date)
    }

    /// Writes files (path -> content), stages everything, commits, and returns the new commit SHA.
    @discardableResult
    func commit(
        _ message: String, files: [String: String] = [:], in directory: URL? = nil, date: Date? = nil
    ) throws -> String {
        let base = directory ?? root
        for (path, content) in files {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        try Self.runGit(["add", "-A"], in: base)
        try Self.runGit(["commit", "--allow-empty", "-m", message], in: base, date: date)
        return try Self.runGit(["rev-parse", "HEAD"], in: base)
    }

    /// Creates a bare origin, wires it up as `origin`, pushes `main`, and sets origin/HEAD.
    func addOrigin() throws {
        try FileManager.default.createDirectory(at: originURL, withIntermediateDirectories: true)
        try Self.runGit(["init", "--bare", "-b", "main"], in: originURL)
        try git("remote", "add", "origin", originURL.path)
        try git("push", "-u", "origin", "main")
        try git("remote", "set-head", "origin", "main")
    }

    func sha(_ ref: String, in directory: URL? = nil) throws -> String {
        try git("rev-parse", ref, in: directory)
    }
}

enum TestRepoError: Error {
    case gitFailed(String, String)
}

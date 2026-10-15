import Foundation

/// Runs `git` with a stable, non-interactive environment.
public struct GitRunner: Sendable {
    private let runner: CommandRunner

    public init(
        executable: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: Duration = .seconds(30)
    ) {
        runner = CommandRunner(
            executable: executable,
            timeout: timeout,
            environment: [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_PAGER": "cat",
                "LC_ALL": "C",
            ]
        )
    }

    /// Returns the raw output, including non-zero exit codes. Throws only on launch failure or timeout.
    public func run(_ arguments: [String], in directory: URL) async throws -> CommandOutput {
        try await runner.run(arguments, in: directory)
    }

    /// Returns stdout, trimmed of trailing newlines. Throws `CommandError.failed` on non-zero exit.
    @discardableResult
    public func runChecked(_ arguments: [String], in directory: URL) async throws -> String {
        let output = try await runner.run(arguments, in: directory)
        guard output.succeeded else {
            throw CommandError.failed(
                command: (["git"] + arguments).joined(separator: " "),
                exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return output.stdout.trimmingCharacters(in: .newlines)
    }
}

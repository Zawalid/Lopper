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
            ],
            inheritsVariable: { !Self.redirectsGit($0) }
        )
    }

    /// Variables that make git work on another repository, index, object store or configuration than the folder it is
    /// run in. They are normally set by git hooks, direnv or IDE terminals; a `lop` started from one would otherwise
    /// check and act on the wrong repository, or have its safety checks silently disabled (a missing GIT_INDEX_FILE makes
    /// "nothing tracked in this folder" look true).
    static func redirectsGit(_ name: String) -> Bool {
        let exact: Set<String> = [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_INDEX_VERSION", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_CONFIG",
            "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_NO_REPLACE_OBJECTS", "GIT_REPLACE_REF_BASE",
            "GIT_GRAFT_FILE", "GIT_SHALLOW_FILE", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS",
            "GIT_LITERAL_PATHSPECS", "GIT_QUARANTINE_PATH",
        ]
        return exact.contains(name) || name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_")
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

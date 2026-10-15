import Foundation

/// Reads merged pull requests through the GitHub CLI (`gh`). One call per repository.
public struct GhCliProvider: PRProvider {
    let runner: CommandRunner

    private static let candidatePaths = [
        "/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh",
    ]

    /// Finds `gh` in the usual install locations. GUI apps do not inherit the shell PATH.
    public static func locate() -> URL? {
        candidatePaths
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public init?(executable: URL? = GhCliProvider.locate(), timeout: Duration = .seconds(60)) {
        guard let executable else { return nil }
        runner = CommandRunner(
            executable: executable, timeout: timeout,
            environment: ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"])
    }

    public func mergedPullRequests(in repoRoot: URL) async throws -> [MergedPR] {
        let output = try await runner.run(
            ["pr", "list", "--state", "merged", "--limit", "300",
             "--json", "number,headRefName,headRefOid,baseRefName"],
            in: repoRoot)
        guard output.succeeded else {
            throw CommandError.failed(
                command: "gh pr list", exitCode: output.exitCode,
                stderr: output.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try Self.decode(output.stdout)
    }

    static func decode(_ json: String) throws -> [MergedPR] {
        struct Row: Decodable {
            let number: Int
            let headRefName: String
            let headRefOid: String
            let baseRefName: String
        }
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        return rows.map {
            MergedPR(
                number: $0.number, headBranch: $0.headRefName, headSHA: $0.headRefOid,
                baseBranch: $0.baseRefName)
        }
    }
}

import Foundation

public enum DefaultBranch {
    /// Resolves the default branch name: override, then origin/HEAD, then `main`, then `master`.
    /// Returns nil when none of those identify it. The checked-out branch is deliberately not a
    /// fallback: it says nothing about where work gets merged, and guessing it would make every
    /// ancestor of whatever is checked out look "already merged".
    public static func resolve(git: GitRunner, repoRoot: URL, override: String? = nil) async -> String? {
        if let override, !override.isEmpty { return override }

        if let output = try? await git.run(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: repoRoot),
            output.succeeded
        {
            let name = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("origin/") { return String(name.dropFirst("origin/".count)) }
        }
        for candidate in ["main", "master"] where await refExists(git: git, repoRoot: repoRoot, ref: "refs/heads/\(candidate)") {
            return candidate
        }
        return nil
    }

    /// Full ref names of the default branch that exist locally: the local branch and `origin/<name>`.
    public static func existingRefs(git: GitRunner, repoRoot: URL, branch: String) async -> [String] {
        var refs: [String] = []
        for ref in ["refs/heads/\(branch)", "refs/remotes/origin/\(branch)"]
        where await refExists(git: git, repoRoot: repoRoot, ref: ref) {
            refs.append(ref)
        }
        return refs
    }

    static func refExists(git: GitRunner, repoRoot: URL, ref: String) async -> Bool {
        guard let output = try? await git.run(["rev-parse", "--verify", "--quiet", ref], in: repoRoot) else {
            return false
        }
        return output.succeeded
    }
}

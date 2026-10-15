import Foundation

/// Builds a classified snapshot of one repository: its branches and worktrees.
public struct RepoInspector: Sendable {
    private let git: GitRunner
    private let settings: Settings
    private let prProvider: PRProvider?

    public init(git: GitRunner = GitRunner(), settings: Settings = Settings(), prProvider: PRProvider? = nil) {
        self.git = git
        self.settings = settings
        self.prProvider = prProvider
    }

    public func inspect(repoRoot: URL, now: Date = Date()) async throws -> RepoSnapshot {
        let defaultName = await DefaultBranch.resolve(
            git: git, repoRoot: repoRoot, override: settings.defaultBranchOverrides[repoRoot.path])
        let defaultRefs: [String]
        if let defaultName {
            defaultRefs = await DefaultBranch.existingRefs(git: git, repoRoot: repoRoot, branch: defaultName)
        } else {
            defaultRefs = []
        }
        let detector = MergeEvidenceDetector(git: git, repoRoot: repoRoot, defaultRefs: defaultRefs)

        let worktreeText = try await git.runChecked(["worktree", "list", "--porcelain", "-z"], in: repoRoot)
        let listed = GitParsers.parseWorktreeList(worktreeText)
        let branchText = try await git.runChecked(
            ["for-each-ref", "refs/heads", "--format=\(GitParsers.branchFormat)"], in: repoRoot)
        let refs = GitParsers.parseBranches(branchText)

        let stashText = (try? await git.run(["stash", "list", "--format=%gs"], in: repoRoot))?.stdout ?? ""
        let stashBranches = GitParsers.parseStashBranches(stashText)
        let remoteURL = (try? await git.run(["remote", "get-url", "origin"], in: repoRoot))
            .flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }

        var mergedPRs: [MergedPR] = []
        var prAvailable = false
        if let prProvider {
            do {
                // A PR merged into some other branch (a stacked PR, an abandoned integration branch)
                // proves nothing about the default branch.
                mergedPRs = try await prProvider.mergedPullRequests(in: repoRoot)
                    .filter { $0.baseBranch == defaultName }
                prAvailable = true
            } catch {
                prAvailable = false
            }
        }

        let mainEntry = listed.first
        let linked = listed.dropFirst().filter { !$0.isBare }

        var branchEntries: [BranchEntry] = []
        var refByName: [String: BranchRef] = [:]
        for ref in refs {
            refByName[ref.name] = ref
            let evidence = await detector.evidence(
                tip: ref.tip, branchName: ref.name, upstreamGone: ref.upstreamGone, mergedPRs: mergedPRs)
            let counts = await aheadBehind(tip: ref.tip, defaultRef: defaultRefs.first, repoRoot: repoRoot)
            let worktreesWithBranch = linked.filter { $0.branch == ref.name }.map(\.path)
            let input = ClassificationInput(
                branchName: ref.name,
                evidence: evidence,
                aheadOfDefault: counts.ahead,
                isDefaultBranch: ref.name == defaultName,
                isMainWorktreeHead: mainEntry?.branch == ref.name,
                checkedOutElsewhere: worktreesWithBranch,
                protectedPatterns: settings.protectedPatterns,
                hasStash: stashBranches.contains(ref.name),
                worktree: nil)
            branchEntries.append(BranchEntry(
                repoRoot: repoRoot, name: ref.name, tip: ref.tip, upstream: ref.upstream,
                lastCommit: ref.lastCommit, ahead: counts.ahead, behind: counts.behind,
                checkedOutAt: worktreesWithBranch.first.map { URL(fileURLWithPath: $0) },
                evidence: evidence, verdict: Classifier.classify(input)))
        }

        var worktreeEntries: [WorktreeEntry] = []
        for (index, entry) in listed.enumerated() where !entry.isBare {
            let url = URL(fileURLWithPath: entry.path)
            let isMain = index == 0
            var status = WorktreeStatus()
            var operation = false
            var unreadable = false
            // Git also calls a worktree "prunable" when it merely cannot enter the folder, so the
            // flag is not trusted: only a folder that is really gone has nothing left to lose.
            let folderMissing = !FileManager.default.fileExists(atPath: entry.path)
            if !folderMissing {
                // A prunable folder that still exists has lost its .git file: running git inside it
                // would answer for the enclosing repository, so it is never read.
                if entry.isPrunable {
                    unreadable = true
                } else if let read = await worktreeStatus(at: url) {
                    status = read
                    operation = await operationInProgress(at: url)
                } else {
                    unreadable = true
                }
            }
            let ref = entry.branch.flatMap { refByName[$0] }
            let evidence = await detector.evidence(
                tip: entry.head, branchName: entry.branch,
                upstreamGone: ref?.upstreamGone ?? false, mergedPRs: mergedPRs)
            let counts = await aheadBehind(tip: entry.head, defaultRef: defaultRefs.first, repoRoot: repoRoot)
            let input = ClassificationInput(
                branchName: entry.branch,
                evidence: evidence,
                aheadOfDefault: counts.ahead,
                isDefaultBranch: entry.branch == defaultName,
                isMainWorktreeHead: isMain,
                checkedOutElsewhere: [],
                protectedPatterns: settings.protectedPatterns,
                hasStash: entry.branch.map(stashBranches.contains) ?? false,
                worktree: WorktreeConditions(
                    isDirty: status.isDirty, isLocked: entry.isLocked,
                    extraFiles: status.extraFiles, operationInProgress: operation,
                    isUnreadable: unreadable))
            worktreeEntries.append(WorktreeEntry(
                repoRoot: repoRoot, path: url, head: entry.head, branch: entry.branch,
                isMain: isMain, isLocked: entry.isLocked, isPrunable: entry.isPrunable,
                status: status, operationInProgress: operation, evidence: evidence,
                verdict: Classifier.classify(input),
                agentHint: AgentHint.detect(path: entry.path, branch: entry.branch)))
        }

        let repo = Repo(
            root: repoRoot, name: repoRoot.lastPathComponent,
            defaultBranch: defaultName, remoteURL: remoteURL)
        return RepoSnapshot(
            repo: repo, branches: branchEntries, worktrees: worktreeEntries,
            prDetectionAvailable: prAvailable, scannedAt: now)
    }

    private func aheadBehind(tip: String, defaultRef: String?, repoRoot: URL) async -> (ahead: Int, behind: Int) {
        guard let defaultRef,
            let output = try? await git.run(
                ["rev-list", "--left-right", "--count", "\(defaultRef)...\(tip)"], in: repoRoot),
            output.succeeded
        else { return (0, 0) }
        let parts = output.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
        guard parts.count == 2 else { return (0, 0) }
        return (ahead: parts[1], behind: parts[0])
    }

    /// Nil when git could not read the worktree (failure, timeout, unreadable folder).
    private func worktreeStatus(at url: URL) async -> WorktreeStatus? {
        guard let output = try? await git.run(
            ["status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal"], in: url),
            output.succeeded
        else { return nil }
        return GitParsers.parseStatus(output.stdout, disposable: settings.disposableSet)
    }

    private func operationInProgress(at url: URL) async -> Bool {
        guard let output = try? await git.run(["rev-parse", "--absolute-git-dir"], in: url), output.succeeded
        else { return false }
        let gitDir = URL(fileURLWithPath: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let markers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]
        return markers.contains { FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path) }
    }
}

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

    /// Everything that is shared by all items of one repository. Built once per call; evaluating a
    /// single branch or worktree against it costs a handful of git calls instead of a full scan.
    private struct Context {
        let repoRoot: URL
        let defaultName: String?
        let defaultRefs: [String]
        let detector: MergeEvidenceDetector
        let listed: [WorktreeListEntry]
        let refs: [BranchRef]
        let stashBranches: Set<String>
        let mergedPRs: [MergedPR]
        let prAvailable: Bool
    }

    private func makeContext(repoRoot: URL) async throws -> Context {
        let defaultName = await DefaultBranch.resolve(
            git: git, repoRoot: repoRoot, override: settings.defaultBranchOverride(for: repoRoot))
        let defaultRefs: [String]
        if let defaultName {
            defaultRefs = await DefaultBranch.existingRefs(git: git, repoRoot: repoRoot, branch: defaultName)
        } else {
            defaultRefs = []
        }
        let worktreeText = try await git.runChecked(["worktree", "list", "--porcelain", "-z"], in: repoRoot)
        let branchText = try await git.runChecked(
            ["for-each-ref", "refs/heads", "--format=\(GitParsers.branchFormat)"], in: repoRoot)
        let stashText = (try? await git.run(["stash", "list", "--format=%gs"], in: repoRoot))?.stdout ?? ""

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
        return Context(
            repoRoot: repoRoot,
            defaultName: defaultName,
            defaultRefs: defaultRefs,
            detector: MergeEvidenceDetector(git: git, repoRoot: repoRoot, defaultRefs: defaultRefs),
            listed: GitParsers.parseWorktreeList(worktreeText),
            refs: GitParsers.parseBranches(branchText),
            stashBranches: GitParsers.parseStashBranches(stashText),
            mergedPRs: mergedPRs,
            prAvailable: prAvailable)
    }

    public func inspect(repoRoot: URL, now: Date = Date()) async throws -> RepoSnapshot {
        let context = try await makeContext(repoRoot: repoRoot)
        let remoteURL = (try? await git.run(["remote", "get-url", "origin"], in: repoRoot))
            .flatMap { $0.succeeded ? $0.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : nil }

        var branchEntries: [BranchEntry] = []
        for ref in context.refs {
            branchEntries.append(await branchEntry(ref, in: context))
        }
        var worktreeEntries: [WorktreeEntry] = []
        for (index, entry) in context.listed.enumerated() where !entry.isBare {
            worktreeEntries.append(await worktreeEntry(entry, isMain: index == 0, in: context))
        }

        let repo = Repo(
            root: repoRoot, name: repoRoot.lastPathComponent,
            defaultBranch: context.defaultName, remoteURL: remoteURL)
        return RepoSnapshot(
            repo: repo, branches: branchEntries, worktrees: worktreeEntries,
            prDetectionAvailable: context.prAvailable, scannedAt: now)
    }

    /// True when the user hid this repository; scans skip it entirely.
    public func isIgnored(_ repoRoot: URL) -> Bool {
        settings.isIgnored(repoRoot)
    }

    /// One branch, or nil if it does not exist. Re-verification before a deletion uses this, so a
    /// bulk clean costs a few git calls per item rather than a full scan per item.
    public func inspectBranch(repoRoot: URL, name: String) async throws -> BranchEntry? {
        let context = try await makeContext(repoRoot: repoRoot)
        guard let ref = context.refs.first(where: { $0.name == name }) else { return nil }
        return await branchEntry(ref, in: context)
    }

    /// One worktree by path, or nil if git does not list it.
    public func inspectWorktree(repoRoot: URL, path: URL) async throws -> WorktreeEntry? {
        let context = try await makeContext(repoRoot: repoRoot)
        let target = path.canonicalized.path
        for (index, entry) in context.listed.enumerated() where !entry.isBare {
            if URL(fileURLWithPath: entry.path).canonicalized.path == target {
                return await worktreeEntry(entry, isMain: index == 0, in: context)
            }
        }
        return nil
    }

    private func branchEntry(_ ref: BranchRef, in context: Context) async -> BranchEntry {
        let linked = context.listed.dropFirst().filter { !$0.isBare }
        let evidence = await context.detector.evidence(
            tip: ref.tip, branchName: ref.name, upstreamGone: ref.upstreamGone, mergedPRs: context.mergedPRs)
        let counts = await aheadBehind(
            tip: ref.tip, defaultRef: context.defaultRefs.first, repoRoot: context.repoRoot)
        let worktreesWithBranch = linked.filter { $0.branch == ref.name }.map(\.path)
        let input = ClassificationInput(
            branchName: ref.name,
            evidence: evidence,
            aheadOfDefault: counts.ahead,
            isDefaultBranch: ref.name == context.defaultName,
            isMainWorktreeHead: context.listed.first?.branch == ref.name,
            checkedOutElsewhere: worktreesWithBranch,
            protectedPatterns: settings.protectedPatterns(for: context.repoRoot),
            hasStash: context.stashBranches.contains(ref.name),
            worktree: nil)
        return BranchEntry(
            repoRoot: context.repoRoot, name: ref.name, tip: ref.tip, upstream: ref.upstream,
            lastCommit: ref.lastCommit, ahead: counts.ahead, behind: counts.behind,
            checkedOutAt: worktreesWithBranch.first.map { URL(fileURLWithPath: $0) },
            evidence: evidence, verdict: Classifier.classify(input))
    }

    private func worktreeEntry(_ entry: WorktreeListEntry, isMain: Bool, in context: Context) async -> WorktreeEntry {
        let url = URL(fileURLWithPath: entry.path)
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
            } else if let read = await worktreeStatus(
                at: url, disposable: settings.disposableSet(for: context.repoRoot))
            {
                status = read
                operation = await operationInProgress(at: url)
            } else {
                unreadable = true
            }
        }
        let ref = entry.branch.flatMap { name in context.refs.first { $0.name == name } }
        let evidence = await context.detector.evidence(
            tip: entry.head, branchName: entry.branch,
            upstreamGone: ref?.upstreamGone ?? false, mergedPRs: context.mergedPRs)
        let counts = await aheadBehind(
            tip: entry.head, defaultRef: context.defaultRefs.first, repoRoot: context.repoRoot)
        let input = ClassificationInput(
            branchName: entry.branch,
            evidence: evidence,
            aheadOfDefault: counts.ahead,
            isDefaultBranch: entry.branch == context.defaultName,
            isMainWorktreeHead: isMain,
            checkedOutElsewhere: [],
            protectedPatterns: settings.protectedPatterns(for: context.repoRoot),
            hasStash: entry.branch.map(context.stashBranches.contains) ?? false,
            worktree: WorktreeConditions(
                isDirty: status.isDirty, isLocked: entry.isLocked,
                extraFiles: status.extraFiles, operationInProgress: operation,
                isUnreadable: unreadable))
        return WorktreeEntry(
            repoRoot: context.repoRoot, path: url, head: entry.head, branch: entry.branch,
            isMain: isMain, isLocked: entry.isLocked, isPrunable: entry.isPrunable,
            status: status, operationInProgress: operation, evidence: evidence,
            verdict: Classifier.classify(input),
            agentHint: AgentHint.detect(path: entry.path, branch: entry.branch))
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
    private func worktreeStatus(at url: URL, disposable: Set<String>) async -> WorktreeStatus? {
        guard let output = try? await git.run(
            ["status", "--porcelain=v1", "-z", "--ignored", "--untracked-files=normal"], in: url),
            output.succeeded
        else { return nil }
        return GitParsers.parseStatus(output.stdout, disposable: disposable)
    }

    private func operationInProgress(at url: URL) async -> Bool {
        guard let output = try? await git.run(["rev-parse", "--absolute-git-dir"], in: url), output.succeeded
        else { return false }
        let gitDir = URL(fileURLWithPath: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        let markers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]
        return markers.contains { FileManager.default.fileExists(atPath: gitDir.appendingPathComponent($0).path) }
    }
}

import XCTest
@testable import Lopper

final class AgentAssessorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(days: Double = 0, minutes: Double = 0) -> Date {
        now.addingTimeInterval(-(days * 86_400 + minutes * 60))
    }

    /// Builds the entry with the real classifier so the verdict is never hand written.
    private func entry(
        path: String = "/code/api/.claude/worktrees/x", branch: String? = "claude/x",
        evidence: MergeEvidence = .ancestorOfDefault, ahead: Int = 0, dirty: Bool = false,
        extraFiles: [String] = [], locked: Bool = false, stash: Bool = false, unreadable: Bool = false,
        operation: Bool = false, prunable: Bool = false, isMain: Bool = false,
        patterns: [String] = [], lastCommit: Date?
    ) -> WorktreeEntry {
        let verdict = Classifier.classify(ClassificationInput(
            branchName: branch, evidence: evidence, aheadOfDefault: ahead, isMainWorktreeHead: isMain,
            protectedPatterns: patterns, hasStash: stash,
            worktree: WorktreeConditions(
                isDirty: dirty, isLocked: locked, extraFiles: extraFiles,
                operationInProgress: operation, isUnreadable: unreadable)))
        return WorktreeEntry(
            repoRoot: URL(fileURLWithPath: "/code/api"), path: URL(fileURLWithPath: path),
            head: "0123456789abcdef", branch: branch, isMain: isMain, isLocked: locked, isPrunable: prunable,
            status: WorktreeStatus(isDirty: dirty, extraFiles: extraFiles, disposablePaths: []),
            operationInProgress: operation, evidence: evidence, verdict: verdict, agentHint: nil,
            ahead: ahead, lastCommit: lastCommit,
            createdAt: (lastCommit ?? ago(days: 20)).addingTimeInterval(-86_400))
    }

    private func usage(_ modified: Date?) -> DiskUsage {
        DiskUsage(total: 1_000, disposable: 0, newestModification: modified)
    }

    private func assess(_ worktree: WorktreeEntry, _ usage: DiskUsage?, policy: AgentPolicy = AgentPolicy()) throws -> AgentAssessment {
        try XCTUnwrap(AgentAssessor.assess(worktree: worktree, usage: usage, policy: policy, now: now))
    }

    func testMergedAndIdleIsFinishedAndReclaimable() throws {
        let result = try assess(entry(lastCommit: ago(days: 3)), usage(ago(days: 3)))
        XCTAssertEqual(result.state, .finished)
        XCTAssertEqual(result.removal, .reclaim)
        XCTAssertTrue(result.isReclaimable)
        XCTAssertTrue(result.uniqueWork.isEmpty)
    }

    func testUnmeasuredWorktreeIsNeverReclaimable() throws {
        let result = try assess(entry(lastCommit: ago(days: 3)), nil)
        XCTAssertEqual(result.state, .finished)
        XCTAssertFalse(result.isActivityMeasured)
        XCTAssertFalse(result.isReclaimable)
    }

    func testFreshEmptyWorktreeIsActiveNotFinished() throws {
        // No commits of its own, so the engine calls it Safe; ten minutes old, so it is still in use.
        let result = try assess(entry(lastCommit: ago(minutes: 10)), usage(ago(minutes: 10)))
        XCTAssertEqual(result.state, .active)
        XCTAssertFalse(result.isReclaimable)
        XCTAssertEqual(result.removal, .notOffered)
    }

    func testRecentFileEditKeepsAnOldCommitActive() throws {
        let result = try assess(entry(lastCommit: ago(days: 5)), usage(ago(minutes: 5)))
        XCTAssertEqual(result.state, .active)
    }

    func testCommittedUnmergedWorkIsNotMergedAndKeepsItsBranch() throws {
        let work = entry(evidence: .none, ahead: 3, lastCommit: ago(days: 10))
        let result = try assess(work, usage(ago(days: 10)))
        XCTAssertEqual(result.state, .unmerged)
        XCTAssertEqual(result.uniqueWork.commits, 3)
        XCTAssertEqual(result.removal, .keepBranch("claude/x"))
        XCTAssertFalse(result.isReclaimable)
        XCTAssertTrue(result.canReview)
        XCTAssertTrue(result.sheetNote.contains("claude/x"))
        XCTAssertTrue(result.sheetNote.contains("3 commits"))
    }

    func testCommittedUnmergedWorkIdleForStaleDaysIsAbandonedAndReviewReclaimable() throws {
        let work = entry(evidence: .none, ahead: 2, lastCommit: ago(days: 45))
        let result = try assess(work, usage(ago(days: 45)))
        XCTAssertEqual(result.state, .abandoned)
        XCTAssertTrue(result.isReviewReclaimable)
        XCTAssertFalse(result.isReclaimable)
    }

    func testUncommittedChangesAreNeverAbandonedOrRemovable() throws {
        let work = entry(evidence: .none, ahead: 1, dirty: true, lastCommit: ago(days: 90))
        let result = try assess(work, usage(ago(days: 90)))
        XCTAssertEqual(result.state, .unmerged)
        XCTAssertTrue(result.uniqueWork.existsOnlyInFolder)
        XCTAssertEqual(result.removal, .blocked("Changes exist only in this folder. Commit or move them first."))
        XCTAssertFalse(result.canReview)
    }

    func testIgnoredEnvFileInAMergedWorktreeBlocksRemoval() throws {
        let work = entry(extraFiles: [".env.local"], lastCommit: ago(days: 30))
        let result = try assess(work, usage(ago(days: 30)))
        XCTAssertEqual(result.state, .unmerged)
        XCTAssertFalse(result.isReclaimable)
        XCTAssertFalse(result.canReview)
        XCTAssertEqual(result.uniqueWork.untrackedFiles, [".env.local"])
    }

    func testUnknownDefaultBranchIsNeverAbandonedOrFinished() throws {
        // No default branch: evidence is none and ahead is reported as 0, which must not read as "nothing unique".
        for idle in [10.0, 45.0, 400.0] {
            let work = entry(evidence: .none, ahead: 0, lastCommit: ago(days: idle))
            let result = try assess(work, usage(ago(days: idle)))
            XCTAssertEqual(result.state, .unmerged, "idle \(idle) days")
            XCTAssertTrue(result.uniqueWork.isComparisonUnknown)
            XCTAssertFalse(result.isReclaimable)
            XCTAssertFalse(result.isReviewReclaimable)
        }
    }

    func testLockedMergedWorktreeIsFinishedButBlocked() throws {
        let result = try assess(entry(locked: true, lastCommit: ago(days: 20)), usage(ago(days: 20)))
        XCTAssertEqual(result.state, .finished)
        XCTAssertFalse(result.isReclaimable)
        guard case .blocked = result.removal else { return XCTFail("\(result.removal)") }
    }

    func testDetachedUnmergedWorkIsSavedAsABranchFirst() throws {
        let work = entry(branch: nil, evidence: .none, ahead: 1, lastCommit: ago(days: 40))
        let result = try assess(work, usage(ago(days: 40)))
        XCTAssertEqual(result.state, .abandoned)
        let name = Cleaner.savedBranchName(forWorktreeAt: work.path, head: work.head)
        XCTAssertEqual(result.removal, .saveAsBranch(name))
        XCTAssertTrue(result.sheetNote.contains(name))
        XCTAssertTrue(result.uniqueWork.isDetached)
    }

    func testProtectedWorktreeIsProtected() throws {
        let work = entry(branch: "release/1.0", patterns: ["release/*"], lastCommit: ago(days: 60))
        let result = try assess(work, usage(ago(days: 60)))
        XCTAssertEqual(result.state, .protected)
        XCTAssertEqual(result.removal, .notOffered)
    }

    func testOrdinaryAndMainWorktreesAreNotAssessed() {
        let ordinary = entry(path: "/code/api-hotfix", branch: "hotfix/login", lastCommit: ago(days: 5))
        XCTAssertNil(AgentAssessor.assess(worktree: ordinary, usage: nil, policy: AgentPolicy(), now: now))
        let main = entry(path: "/code/api/.claude/worktrees/m", isMain: true, lastCommit: ago(days: 5))
        XCTAssertNil(AgentAssessor.assess(worktree: main, usage: nil, policy: AgentPolicy(), now: now))
    }

    func testPrunableWorktreeWithMissingFolderCountsAsMeasured() throws {
        let result = try assess(entry(prunable: true, lastCommit: ago(days: 8)), nil)
        XCTAssertTrue(result.isActivityMeasured)
        XCTAssertEqual(result.state, .finished)
    }

    func testRowNoteIsOnlyOfferedWhenRemovalActuallyHappensAsDescribed() throws {
        let keep = try assess(entry(evidence: .none, ahead: 2, lastCommit: ago(days: 10)), usage(ago(days: 10)))
        XCTAssertNotNil(keep.rowNote)
        let blocked = try assess(entry(extraFiles: [".env.local"], lastCommit: ago(days: 30)), usage(ago(days: 30)))
        XCTAssertNil(blocked.rowNote, "the sheet must not claim a blocked row is held back")
        let active = try assess(entry(lastCommit: ago(minutes: 5)), usage(ago(minutes: 5)))
        XCTAssertNil(active.rowNote)
    }

    func testCreationTimeCountsAsActivity() throws {
        // Created ten minutes ago from main: the HEAD commit is old and nothing was written yet.
        var fresh = entry(lastCommit: ago(days: 30))
        fresh = WorktreeEntry(
            repoRoot: fresh.repoRoot, path: fresh.path, head: fresh.head, branch: fresh.branch, isMain: false,
            isLocked: false, isPrunable: false, status: fresh.status, operationInProgress: false,
            evidence: fresh.evidence, verdict: fresh.verdict, agentHint: nil, ahead: 0,
            lastCommit: ago(days: 30), createdAt: ago(minutes: 10))
        let result = try assess(fresh, usage(nil))
        XCTAssertEqual(result.state, .active)
        XCTAssertFalse(result.isReclaimable)
    }

    func testPolicyReadsSettings() {
        var settings = Settings()
        settings.agentFinishedGraceMinutes = 30
        settings.staleDays = 14
        let policy = AgentPolicy(settings: settings)
        XCTAssertEqual(policy.finishedGrace, 1_800)
        XCTAssertEqual(policy.abandonedAfter, 14 * 86_400)
    }

    func testSavedBranchNameIsSafeForGitAndStableForOneCommit() {
        let path = URL(fileURLWithPath: "/tmp/Mon Projet/été..lock")
        let name = Cleaner.savedBranchName(forWorktreeAt: path, head: "0123456789abcdef")
        XCTAssertEqual(name, "lopper/saved/ete-lock-01234567")
        XCTAssertEqual(name, Cleaner.savedBranchName(forWorktreeAt: path, head: "0123456789abcdef"))
        let empty = Cleaner.savedBranchName(forWorktreeAt: URL(fileURLWithPath: "/tmp/éé"), head: "abcdef0123")
        XCTAssertEqual(empty, "lopper/saved/ee-abcdef01")
        let none = Cleaner.savedBranchName(forWorktreeAt: URL(fileURLWithPath: "/tmp/日本"), head: "abcdef0123")
        XCTAssertEqual(none, "lopper/saved/worktree-abcdef01")
    }
}

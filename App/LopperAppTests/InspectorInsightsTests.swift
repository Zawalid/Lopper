import XCTest
import Lopper
@testable import LopperApp

final class InspectorInsightsTests: XCTestCase {
    private func row(
        kind: CleanupRow.Kind = .branch, verdict: VerdictKind = .review, reasons: [String] = [],
        extraFiles: [String] = [], facts: RowFacts = RowFacts()
    ) -> CleanupRow {
        CleanupRow(
            id: "r", kind: kind, repoRoot: URL(fileURLWithPath: "/code/api"), repoName: "api", title: "feat/x",
            location: "Local branch", path: kind == .worktree ? URL(fileURLWithPath: "/code/wt/x") : nil,
            verdict: verdict, reasons: reasons, evidence: "", prNumber: nil, prURL: nil, lastCommit: nil,
            size: nil, agentHint: nil, extraFiles: extraFiles, bundledBranch: nil, facts: facts)
    }

    private func facts(
        _ evidence: MergeEvidence, upstream: String? = nil, defaultBranch: String? = "main",
        prDetection: Bool = true, dirty: Bool = false
    ) -> RowFacts {
        RowFacts(
            evidence: evidence, tip: "0123456789abcdef", upstream: upstream, ahead: 2, behind: 1,
            isDirty: dirty, defaultBranch: defaultBranch, prDetectionAvailable: prDetection)
    }

    private func check(_ id: String, in row: CleanupRow) -> EvidenceCheck? {
        InspectorInsights.checklist(for: row).first { $0.id == id }
    }

    // MARK: Banner

    func testBannerForSafeItemsSaysWhyInPlainWords() {
        XCTAssertEqual(
            InspectorInsights.banner(for: row(verdict: .safe, facts: facts(.ancestorOfDefault))),
            "Safe to remove. Its commits are already in main.")
        XCTAssertEqual(
            InspectorInsights.banner(for: row(verdict: .safe, facts: facts(.contentIncluded))),
            "Safe to remove. The same changes are already in main.")
        XCTAssertEqual(
            InspectorInsights.banner(for: row(verdict: .safe, facts: facts(.prMerged(number: 54)))),
            "Safe to remove. Its pull request #54 was merged.")
    }

    func testBannerForReviewItemsNamesTheDecision() {
        XCTAssertEqual(
            InspectorInsights.banner(for: row(facts: facts(.none))),
            "Needs your decision. Nothing shows this work was merged.")
        XCTAssertEqual(
            InspectorInsights.banner(for: row(facts: facts(.prMergedWithNewerCommits(number: 9)))),
            "Needs your decision. Its pull request was merged, but this branch has newer commits.")
        XCTAssertEqual(
            InspectorInsights.banner(for: row(facts: facts(.upstreamGone))),
            "Needs your decision. Its remote branch was deleted, but nothing shows it was merged.")
    }

    func testBannerForProtectedItemsUsesTheEngineReason() {
        let protected = row(verdict: .protected, reasons: ["It is the default branch"], facts: facts(.none))
        XCTAssertEqual(InspectorInsights.banner(for: protected), "Protected. It is the default branch.")
        XCTAssertEqual(
            InspectorInsights.banner(for: row(verdict: .protected)), "Protected. Lopper never removes it.")
    }

    // MARK: Checklist

    func testDefaultBranchCheckFollowsTheMergeEvidence() {
        XCTAssertEqual(check("default", in: row(facts: facts(.ancestorOfDefault)))?.state, .passed)
        XCTAssertEqual(check("default", in: row(facts: facts(.contentIncluded)))?.state, .passed)
        XCTAssertEqual(check("default", in: row(facts: facts(.prMerged(number: 1))))?.state, .passed)
        XCTAssertEqual(check("default", in: row(facts: facts(.prMergedWithNewerCommits(number: 1))))?.state, .warning)
        XCTAssertEqual(check("default", in: row(facts: facts(.none)))?.state, .failed)
        XCTAssertEqual(check("default", in: row(facts: facts(.none, defaultBranch: nil)))?.state, .neutral)
    }

    func testPullRequestCheckSaysWhenItCouldNotLook() {
        XCTAssertEqual(check("pr", in: row(facts: facts(.prMerged(number: 54))))?.title, "Pull request #54 merged")
        XCTAssertEqual(check("pr", in: row(facts: facts(.none)))?.title, "No merged pull request found")
        let unchecked = check("pr", in: row(facts: facts(.none, prDetection: false)))
        XCTAssertEqual(unchecked?.title, "Pull requests were not checked")
        XCTAssertEqual(unchecked?.state, .neutral)
    }

    func testRemoteCheckFlagsWorkThatExistsOnlyOnThisMac() {
        XCTAssertEqual(check("remote", in: row(facts: facts(.none, upstream: "origin/feat/x")))?.state, .passed)
        XCTAssertEqual(check("remote", in: row(facts: facts(.upstreamGone)))?.state, .warning)
        XCTAssertEqual(check("remote", in: row(facts: facts(.none)))?.state, .failed)
        XCTAssertEqual(check("remote", in: row(facts: facts(.none)))?.title, "Only on this Mac")
        // Already merged, so a missing remote copy loses nothing.
        XCTAssertEqual(check("remote", in: row(facts: facts(.ancestorOfDefault)))?.state, .neutral)
    }

    func testWorktreeChecksAppearOnlyForWorktrees() {
        XCTAssertNil(check("worktree", in: row(kind: .branch, facts: facts(.none))))
        XCTAssertEqual(
            check("worktree", in: row(kind: .worktree, facts: facts(.none, dirty: true)))?.state, .failed)
        XCTAssertEqual(
            check("worktree", in: row(kind: .worktree, facts: facts(.none, dirty: false)))?.state, .passed)
    }

    func testUntrackedFilesAreAWarningWhenThereAreAny() {
        let withFiles = row(kind: .worktree, extraFiles: [".env", "notes.md"], facts: facts(.none))
        XCTAssertEqual(check("untracked", in: withFiles)?.state, .warning)
        XCTAssertEqual(check("untracked", in: withFiles)?.title, "2 files git does not track")
        XCTAssertNil(check("untracked", in: row(kind: .worktree, facts: facts(.none))))
    }

    // MARK: Facts

    func testDivergenceReadsAheadAndBehindTheDefaultBranch() {
        XCTAssertEqual(InspectorInsights.divergence(facts(.none)), "2 ahead, 1 behind main")
        var level = facts(.none)
        level.ahead = 0
        level.behind = 0
        XCTAssertEqual(InspectorInsights.divergence(level), "Level with main")
        var unknown = facts(.none)
        unknown.ahead = nil
        XCTAssertNil(InspectorInsights.divergence(unknown))
        XCTAssertNil(InspectorInsights.divergence(facts(.none, defaultBranch: nil)))
    }

    func testShortHashIsSevenCharactersOrWhatThereIs() {
        XCTAssertEqual(InspectorInsights.shortHash("0123456789abcdef"), "0123456")
        XCTAssertEqual(InspectorInsights.shortHash("abc"), "abc")
    }
}

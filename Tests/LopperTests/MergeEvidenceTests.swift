import XCTest
@testable import Lopper

final class MergeEvidenceTests: XCTestCase {
    private let git = GitRunner()

    private func detector(_ repo: TestRepo) async -> MergeEvidenceDetector {
        let name = await DefaultBranch.resolve(git: git, repoRoot: repo.root) ?? "main"
        let refs = await DefaultBranch.existingRefs(git: git, repoRoot: repo.root, branch: name)
        return MergeEvidenceDetector(git: git, repoRoot: repo.root, defaultRefs: refs)
    }

    private func baseRepo() throws -> TestRepo {
        let repo = try TestRepo()
        try repo.commit("base", files: ["app.txt": "line1\nline2\nline3\n"])
        return repo
    }

    func testAncestorWhenMergedWithMergeCommit() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("work", files: ["feature.txt": "x"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--no-ff", "-m", "merge feature", "feature")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .ancestorOfDefault)
    }

    func testContentIncludedWhenSquashMerged() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        try repo.commit("one", files: ["a.txt": "a"])
        let tip = try repo.commit("two", files: ["b.txt": "b"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "feature")
        try repo.git("commit", "-m", "feature (#1)")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .contentIncluded)
    }

    func testContentIncludedWhenRebaseMerged() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        try repo.commit("one", files: ["a.txt": "a"])
        let tip = try repo.commit("two", files: ["b.txt": "b"])
        try repo.git("checkout", "main")
        try repo.commit("unrelated main work", files: ["m.txt": "m"])
        try repo.git("cherry-pick", "feature~1", "feature")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .contentIncluded)
    }

    func testNoneWhenBranchHasUniqueWork() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("unmerged", files: ["secret.txt": "work"])
        try repo.git("checkout", "main")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .none)
    }

    func testUpstreamGoneAloneIsNotStrong() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("unmerged", files: ["secret.txt": "work"])
        try repo.git("checkout", "main")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: true, mergedPRs: [])
        XCTAssertEqual(evidence, .upstreamGone)
        XCTAssertFalse(evidence.isStrong)
    }

    func testSingleCommitSquashStillDetectedAfterMainEditsSameLines() async throws {
        // merge-tree conflicts here, but the single commit's patch-id matches the squash commit.
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("edit", files: ["app.txt": "line1\nFEATURE\nline3\n"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "feature")
        try repo.git("commit", "-m", "feature (#1)")
        try repo.commit("later edit", files: ["app.txt": "line1\nLATER\nline3\n"])

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .contentIncluded)
    }

    func testMultiCommitSquashThenMainEditsSameLinesFallsBackToNoEvidence() async throws {
        // Known limitation: neither tree equality nor per-commit patch-ids can prove it any more.
        // The branch is classified Review, never Safe, and the PR provider is the way out.
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        try repo.commit("one", files: ["app.txt": "line1\nFEATURE1\nline3\n"])
        let tip = try repo.commit("two", files: ["app.txt": "line1\nFEATURE1\nFEATURE3\n"])
        try repo.git("checkout", "main")
        try repo.git("merge", "--squash", "feature")
        try repo.git("commit", "-m", "feature (#1)")
        try repo.commit("later edit", files: ["app.txt": "line1\nLATER\nFEATURE3\n"])

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .none)
    }

    func testPrMergedMatchesExactTip() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let tip = try repo.commit("work", files: ["f.txt": "f"])
        try repo.git("checkout", "main")
        let pr = MergedPR(number: 482, headBranch: "feature", headSHA: tip, baseBranch: "main")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [pr])
        XCTAssertEqual(evidence, .prMerged(number: 482))
    }

    func testPrMergedWithNewerLocalCommitsIsNotStrong() async throws {
        let repo = try baseRepo()
        try repo.git("checkout", "-b", "feature")
        let prHead = try repo.commit("work", files: ["f.txt": "f"])
        let tip = try repo.commit("after the PR was merged", files: ["g.txt": "g"])
        try repo.git("checkout", "main")
        let pr = MergedPR(number: 7, headBranch: "feature", headSHA: prHead, baseBranch: "main")

        let evidence = await detector(repo).evidence(tip: tip, branchName: "feature", upstreamGone: false, mergedPRs: [pr])
        XCTAssertEqual(evidence, .prMergedWithNewerCommits(number: 7))
        XCTAssertFalse(evidence.isStrong)
    }

    func testDetachedHeadHasNoBranchNameButStillGetsAncestry() async throws {
        let repo = try baseRepo()
        let tip = try repo.sha("HEAD")
        try repo.commit("main moves on", files: ["x.txt": "x"])

        let evidence = await detector(repo).evidence(tip: tip, branchName: nil, upstreamGone: false, mergedPRs: [])
        XCTAssertEqual(evidence, .ancestorOfDefault)
    }

    func testDefaultBranchUsesOriginHead() async throws {
        let repo = try baseRepo()
        try repo.addOrigin()
        let name = await DefaultBranch.resolve(git: git, repoRoot: repo.root)
        XCTAssertEqual(name, "main")
        let refs = await DefaultBranch.existingRefs(git: git, repoRoot: repo.root, branch: "main")
        XCTAssertEqual(refs, ["refs/heads/main", "refs/remotes/origin/main"])
    }

    func testDefaultBranchFallsBackToMaster() async throws {
        let repo = try TestRepo()
        try repo.git("branch", "-m", "main", "master")
        try repo.commit("base", files: ["a": "a"])
        let name = await DefaultBranch.resolve(git: git, repoRoot: repo.root)
        XCTAssertEqual(name, "master")
    }

    func testDefaultBranchOverrideWins() async throws {
        let repo = try baseRepo()
        let name = await DefaultBranch.resolve(git: git, repoRoot: repo.root, override: "develop")
        XCTAssertEqual(name, "develop")
    }

    func testDefaultBranchIsNilWhenNothingIdentifiesIt() async throws {
        // No origin, no main, no master, no override: the checked-out branch is not evidence of
        // anything, so Lopper must not invent a default from it.
        let repo = try TestRepo()
        try repo.git("branch", "-m", "main", "trunk")
        try repo.commit("base", files: ["a": "a"])
        let name = await DefaultBranch.resolve(git: git, repoRoot: repo.root)
        XCTAssertNil(name)
    }
}

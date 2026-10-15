import XCTest
@testable import Lopper

final class ClassifierTests: XCTestCase {
    private let patterns = ["main", "master", "develop", "release/*"]

    private func input(
        _ evidence: MergeEvidence,
        name: String? = "feature/x",
        ahead: Int = 2,
        worktree: WorktreeConditions? = nil,
        stash: Bool = false
    ) -> ClassificationInput {
        ClassificationInput(
            branchName: name, evidence: evidence, aheadOfDefault: ahead,
            protectedPatterns: patterns, hasStash: stash, worktree: worktree)
    }

    func testStrongEvidenceWithNothingElseIsSafe() {
        for evidence: MergeEvidence in [.prMerged(number: 1), .ancestorOfDefault, .contentIncluded] {
            XCTAssertEqual(Classifier.classify(input(evidence)).kind, .safe, "\(evidence)")
        }
    }

    func testNoEvidenceIsReview() {
        let verdict = Classifier.classify(input(.none))
        XCTAssertEqual(verdict.kind, .review)
        XCTAssertEqual(verdict.reasons, [.noMergeEvidence])
    }

    func testUpstreamGoneAloneIsNeverSafe() {
        let verdict = Classifier.classify(input(.upstreamGone))
        XCTAssertEqual(verdict.kind, .review)
        XCTAssertEqual(verdict.reasons, [.upstreamGoneOnly])
    }

    func testCommitsAfterMergedPRIsReview() {
        let verdict = Classifier.classify(input(.prMergedWithNewerCommits(number: 9)))
        XCTAssertEqual(verdict.kind, .review)
        XCTAssertEqual(verdict.reasons, [.commitsAfterMergedPR(number: 9)])
    }

    func testProtectedPatternWinsOverEvidence() {
        let verdict = Classifier.classify(input(.ancestorOfDefault, name: "release/1.4"))
        XCTAssertEqual(verdict.kind, .protected)
        XCTAssertEqual(verdict.reasons, [.matchesProtectedPattern("release/*")])
    }

    func testDefaultBranchAndMainWorktreeHeadAreProtected() {
        var item = input(.ancestorOfDefault, name: "main")
        item.isDefaultBranch = true
        XCTAssertEqual(Classifier.classify(item).kind, .protected)

        var head = input(.ancestorOfDefault)
        head.isMainWorktreeHead = true
        XCTAssertEqual(Classifier.classify(head).kind, .protected)
    }

    func testBranchCheckedOutInAnotherWorktreeIsProtected() {
        var item = input(.ancestorOfDefault)
        item.checkedOutElsewhere = ["/work/repo-feature"]
        let verdict = Classifier.classify(item)
        XCTAssertEqual(verdict.kind, .protected)
        XCTAssertEqual(verdict.reasons, [.checkedOut(inWorktree: "/work/repo-feature")])
    }

    func testDirtyLockedExtraFilesAndOperationEachForceReview() {
        let cases: [WorktreeConditions] = [
            WorktreeConditions(isDirty: true),
            WorktreeConditions(isLocked: true),
            WorktreeConditions(extraFiles: [".env.local"]),
            WorktreeConditions(operationInProgress: true),
        ]
        for conditions in cases {
            let verdict = Classifier.classify(input(.ancestorOfDefault, worktree: conditions))
            XCTAssertEqual(verdict.kind, .review, "\(conditions)")
        }
    }

    func testUnreadableWorktreeIsReviewNeverSafe() {
        let verdict = Classifier.classify(
            input(.ancestorOfDefault, worktree: WorktreeConditions(isUnreadable: true)))
        XCTAssertEqual(verdict.kind, .review)
        XCTAssertEqual(verdict.reasons, [.worktreeUnreadable])
    }

    func testCleanWorktreeWithStrongEvidenceIsSafe() {
        let verdict = Classifier.classify(input(.contentIncluded, worktree: WorktreeConditions()))
        XCTAssertEqual(verdict.kind, .safe)
    }

    func testStashForcesReview() {
        XCTAssertEqual(Classifier.classify(input(.ancestorOfDefault, stash: true)).kind, .review)
    }

    func testBranchWithoutOwnCommitsIsSafeAndSaysSo() {
        let verdict = Classifier.classify(input(.ancestorOfDefault, ahead: 0))
        XCTAssertEqual(verdict.kind, .safe)
        XCTAssertTrue(verdict.reasons.contains(.noOwnCommits))
    }

    func testDetachedHeadIsNotMatchedAgainstPatterns() {
        let verdict = Classifier.classify(input(.ancestorOfDefault, name: nil))
        XCTAssertEqual(verdict.kind, .safe)
    }

    /// Invariant: Safe implies strong evidence and no protection or review condition, for every combination.
    func testSafeImpliesStrongEvidenceAndNoBlockingCondition() {
        let evidences: [MergeEvidence] = [
            .prMerged(number: 1), .ancestorOfDefault, .contentIncluded,
            .prMergedWithNewerCommits(number: 1), .upstreamGone, .none,
        ]
        let names = ["feature/x", "main", "release/2"]
        var safeCount = 0

        // Eight independent boolean conditions, enumerated as bits of `mask`.
        for evidence in evidences {
            for name in names {
                for mask in 0..<(1 << 8) {
                    func bit(_ index: Int) -> Bool { mask & (1 << index) != 0 }
                    let item = ClassificationInput(
                        branchName: name,
                        evidence: evidence,
                        isDefaultBranch: bit(0),
                        isMainWorktreeHead: bit(1),
                        checkedOutElsewhere: bit(2) ? ["/w"] : [],
                        protectedPatterns: patterns,
                        hasStash: bit(3),
                        worktree: WorktreeConditions(
                            isDirty: bit(4), isLocked: bit(5),
                            extraFiles: [], operationInProgress: bit(6), isUnreadable: bit(7)))
                    guard Classifier.classify(item).kind == .safe else { continue }
                    safeCount += 1
                    XCTAssertTrue(evidence.isStrong, "\(item)")
                    XCTAssertEqual(mask, 0, "\(item)")
                    XCTAssertEqual(name, "feature/x", "\(item)")
                }
            }
        }
        XCTAssertGreaterThan(safeCount, 0)
    }

    func testGlobMatcher() {
        XCTAssertTrue(GlobMatcher.matches(pattern: "release/*", name: "release/1.2"))
        XCTAssertTrue(GlobMatcher.matches(pattern: "release/*", name: "release/1.2/hotfix"))
        XCTAssertTrue(GlobMatcher.matches(pattern: "main", name: "main"))
        XCTAssertFalse(GlobMatcher.matches(pattern: "main", name: "maintenance"))
    }

    func testSettingsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        var settings = Settings(roots: [URL(fileURLWithPath: "/Users/me/code")])
        settings.staleDays = 14
        try settings.save(to: url)
        XCTAssertEqual(Settings.load(from: url), settings)
        XCTAssertEqual(Settings.load(from: url.appendingPathExtension("missing")), Settings())
    }

    func testDefaultDisposableListCoversCommonToolCachesButNotSecrets() {
        let disposable = Settings().disposableSet
        for name in [".pytest_cache", ".ruff_cache", ".mypy_cache", ".DS_Store", "tsconfig.tsbuildinfo", "node_modules"] {
            XCTAssertTrue(GitParsers.isDisposable(name, disposable: disposable), name)
        }
        // Real work that exists nowhere else must keep a worktree in Review.
        for name in [".env", ".env.test", ".env.local", "media", "notes.md"] {
            XCTAssertFalse(GitParsers.isDisposable(name, disposable: disposable), name)
        }
    }

    func testSettingsLoadKeepsDefaultsForKeysAddedInLaterVersions() throws {
        // A settings file written by an older build has no repoDisposableNames; it must still load,
        // otherwise a new release would silently reset everything the user configured.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lopper-old-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try #"{"staleDays": 14, "scanDepth": 2}"#.write(to: url, atomically: true, encoding: .utf8)

        let settings = Settings.load(from: url)

        XCTAssertEqual(settings.staleDays, 14)
        XCTAssertEqual(settings.scanDepth, 2)
        XCTAssertEqual(settings.protectedPatterns, Settings.defaultProtectedPatterns)
        XCTAssertTrue(settings.repoDisposableNames.isEmpty)
    }

    func testAddingRepoDisposableIsPerRepositoryAndIdempotent() {
        let repo = URL(fileURLWithPath: "/code/api")
        let once = Settings().addingRepoDisposable(".env.test", for: repo)
        let twice = once.addingRepoDisposable(".env.test", for: repo)

        XCTAssertEqual(twice.repoDisposableNames[repo.path], [".env.test"])
        XCTAssertTrue(twice.disposableSet(for: repo).contains(".env.test"))
        XCTAssertFalse(twice.disposableSet(for: URL(fileURLWithPath: "/code/apps")).contains(".env.test"))
    }
}

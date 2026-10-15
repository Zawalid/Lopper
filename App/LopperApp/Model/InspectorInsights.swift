import Foundation
import Lopper

enum CheckState: Equatable {
    case passed, failed, warning, neutral
}

/// One line of the evidence checklist in the details panel.
struct EvidenceCheck: Identifiable, Equatable {
    let id: String
    let state: CheckState
    let title: String
    let detail: String?
}

/// What the details panel says about an item, derived from the facts the engine already gathered. Pure, so the
/// wording that decides whether someone trusts a removal is unit tested.
enum InspectorInsights {
    /// One sentence that answers "what should I do with this". An open pull request changes the advice for an
    /// item that needs a decision: it is most likely still in use.
    static func banner(for row: CleanupRow, pullRequest: PullRequestStatus? = nil) -> String {
        if row.verdict == .review, let pullRequest, pullRequest.state == .open {
            return "Needs your decision. It has an open pull request, #\(pullRequest.number), "
                + "so it is probably still in use."
        }
        return plainBanner(for: row)
    }

    private static func plainBanner(for row: CleanupRow) -> String {
        let main = row.facts.defaultBranch ?? "the default branch"
        switch row.verdict {
        case .protected:
            return "Protected. \(row.reasons.first.map(sentence) ?? "Lopper never removes it.")"
        case .safe:
            switch row.facts.evidence {
            case .prMerged(let number): return "Safe to remove. Its pull request #\(number) was merged."
            case .contentIncluded: return "Safe to remove. The same changes are already in \(main)."
            default: return "Safe to remove. Its commits are already in \(main)."
            }
        case .review:
            switch row.facts.evidence {
            case .prMergedWithNewerCommits:
                return "Needs your decision. Its pull request was merged, but this branch has newer commits."
            case .upstreamGone:
                return "Needs your decision. Its remote branch was deleted, but nothing shows it was merged."
            default:
                return "Needs your decision. Nothing shows this work was merged."
            }
        }
    }

    static func checklist(for row: CleanupRow) -> [EvidenceCheck] {
        var checks = [defaultBranchCheck(row.facts), pullRequestCheck(row.facts), remoteCheck(row.facts)]
        if row.kind == .worktree {
            checks.append(EvidenceCheck(
                id: "worktree",
                state: row.facts.isDirty ? .failed : .passed,
                title: row.facts.isDirty ? "Uncommitted changes" : "No uncommitted changes",
                detail: row.facts.isDirty ? "Removing the worktree would discard them." : nil))
            if !row.extraFiles.isEmpty {
                checks.append(EvidenceCheck(
                    id: "untracked", state: .warning,
                    title: "\(Plural.count(row.extraFiles.count, "file")) git does not track",
                    detail: "They exist only in this worktree."))
            }
        }
        return checks
    }

    /// "2 ahead, 1 behind main", or nil when the numbers or the default branch are not known.
    static func divergence(_ facts: RowFacts) -> String? {
        guard let main = facts.defaultBranch, let ahead = facts.ahead, let behind = facts.behind else { return nil }
        if ahead == 0 && behind == 0 { return "Level with \(main)" }
        return "\(ahead) ahead, \(behind) behind \(main)"
    }

    static func shortHash(_ tip: String) -> String { String(tip.prefix(7)) }

    // MARK: Pull request

    struct PullRequestSummary: Equatable {
        enum Tone { case caution, neutral }
        let headline: String
        let detail: String?
        let tone: Tone
    }

    static func pullRequestSummary(_ pr: PullRequestStatus) -> PullRequestSummary {
        switch pr.state {
        case .merged:
            return PullRequestSummary(headline: "Pull request #\(pr.number) was merged", detail: nil, tone: .neutral)
        case .closed:
            return PullRequestSummary(
                headline: "Pull request #\(pr.number) was closed without merging", detail: nil, tone: .neutral)
        case .open:
            let review: String? = switch pr.review {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .reviewRequired: "Waiting for review"
            case .none: nil
            }
            let checks: String? = switch pr.checks {
            case .passing: "checks passing"
            case .failing: "checks failing"
            case .pending: "checks running"
            case .none: nil
            }
            let detail = [review, checks].compactMap { $0 }.joined(separator: ", ")
            return PullRequestSummary(
                headline: pr.isDraft ? "Draft pull request #\(pr.number)" : "Open pull request #\(pr.number)",
                detail: detail.isEmpty ? nil : detail,
                tone: .caution)
        }
    }

    // MARK: Last touched

    struct LastTouched: Equatable {
        enum Kind { case commit, checkout }
        let date: Date
        let kind: Kind
    }

    /// The more recent of the last commit and the last checkout. A checkout newer than any commit means
    /// someone was on this branch recently even though nothing was committed.
    static func lastTouched(commit: Date?, checkedOut: Date?) -> LastTouched? {
        switch (commit, checkedOut) {
        case let (commit?, checkout?):
            return checkout > commit
                ? LastTouched(date: checkout, kind: .checkout)
                : LastTouched(date: commit, kind: .commit)
        case let (commit?, nil): return LastTouched(date: commit, kind: .commit)
        case let (nil, checkout?): return LastTouched(date: checkout, kind: .checkout)
        case (nil, nil): return nil
        }
    }

    // MARK: Checks

    private static func defaultBranchCheck(_ facts: RowFacts) -> EvidenceCheck {
        guard let main = facts.defaultBranch else {
            return EvidenceCheck(
                id: "default", state: .neutral, title: "Default branch unknown",
                detail: "Set it in Settings so Lopper can compare.")
        }
        switch facts.evidence {
        case .ancestorOfDefault:
            return EvidenceCheck(id: "default", state: .passed, title: "Already in \(main)",
                                 detail: "Every commit is part of \(main).")
        case .contentIncluded:
            return EvidenceCheck(id: "default", state: .passed, title: "Already in \(main)",
                                 detail: "The same changes are in \(main).")
        case .prMerged:
            return EvidenceCheck(id: "default", state: .passed, title: "Already in \(main)",
                                 detail: "Its pull request was merged.")
        case .prMergedWithNewerCommits:
            return EvidenceCheck(id: "default", state: .warning, title: "Newer commits are not in \(main)",
                                 detail: "The merged pull request did not contain the latest commits.")
        case .upstreamGone, .none:
            return EvidenceCheck(id: "default", state: .failed, title: "Not found in \(main)", detail: nil)
        }
    }

    private static func pullRequestCheck(_ facts: RowFacts) -> EvidenceCheck {
        switch facts.evidence {
        case .prMerged(let number):
            return EvidenceCheck(id: "pr", state: .passed, title: "Pull request #\(number) merged", detail: nil)
        case .prMergedWithNewerCommits(let number):
            return EvidenceCheck(
                id: "pr", state: .warning, title: "Pull request #\(number) merged earlier",
                detail: "This branch has commits made after it.")
        default:
            if facts.prDetectionAvailable {
                return EvidenceCheck(id: "pr", state: .neutral, title: "No merged pull request found", detail: nil)
            }
            return EvidenceCheck(
                id: "pr", state: .neutral, title: "Pull requests were not checked",
                detail: "Install the GitHub CLI to check them.")
        }
    }

    private static func remoteCheck(_ facts: RowFacts) -> EvidenceCheck {
        if let upstream = facts.upstream {
            return EvidenceCheck(id: "remote", state: .passed, title: "On a remote", detail: upstream)
        }
        if facts.evidence == .upstreamGone {
            return EvidenceCheck(
                id: "remote", state: .warning, title: "Its remote branch was deleted",
                detail: "Nothing else holds this work now.")
        }
        if facts.evidence.isStrong {
            return EvidenceCheck(
                id: "remote", state: .neutral, title: "Not pushed", detail: "Its content is already in the default branch.")
        }
        return EvidenceCheck(
            id: "remote", state: .failed, title: "Only on this Mac", detail: "No remote copy of this work exists.")
    }

    private static func sentence(_ reason: String) -> String {
        reason.hasSuffix(".") ? reason : reason + "."
    }
}

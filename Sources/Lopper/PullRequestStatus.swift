import Foundation

/// One pull request as the details panel shows it: is it still open, is anyone waiting on it, did its checks
/// pass. An open pull request is the strongest "do not remove this" signal there is.
public struct PullRequestStatus: Sendable, Equatable {
    public enum State: Sendable, Equatable { case open, closed, merged }
    public enum Review: Sendable, Equatable { case approved, changesRequested, reviewRequired, none }
    public enum Checks: Sendable, Equatable { case passing, failing, pending, none }

    public let number: Int
    public let title: String
    public let state: State
    public let isDraft: Bool
    public let review: Review
    public let checks: Checks
    public let url: URL?
    public let updatedAt: Date?

    public init(
        number: Int, title: String, state: State, isDraft: Bool, review: Review, checks: Checks, url: URL?,
        updatedAt: Date? = nil
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.review = review
        self.checks = checks
        self.url = url
        self.updatedAt = updatedAt
    }

    /// The open pull request if there is one, otherwise whichever was updated last.
    public static func mostRelevant(in all: [PullRequestStatus]) -> PullRequestStatus? {
        if let open = all.first(where: { $0.state == .open }) { return open }
        return all.max { ($0.updatedAt ?? .distantPast) < ($1.updatedAt ?? .distantPast) }
    }

    /// Decodes `gh pr list --json number,title,state,isDraft,reviewDecision,url,updatedAt,statusCheckRollup`.
    static func decode(_ json: String) throws -> [PullRequestStatus] {
        struct Check: Decodable {
            let status: String?
            let conclusion: String?
            let state: String?
        }
        struct Row: Decodable {
            let number: Int
            let title: String
            let state: String
            let isDraft: Bool?
            let reviewDecision: String?
            let url: String?
            let updatedAt: String?
            let statusCheckRollup: [Check]?
        }

        let formatter = ISO8601DateFormatter()
        let rows = try JSONDecoder().decode([Row].self, from: Data(json.utf8))
        return rows.map { row in
            PullRequestStatus(
                number: row.number,
                title: row.title,
                state: state(row.state),
                isDraft: row.isDraft ?? false,
                review: review(row.reviewDecision),
                checks: checks((row.statusCheckRollup ?? []).map { ($0.status, $0.conclusion, $0.state) }),
                url: row.url.flatMap { $0.isEmpty ? nil : URL(string: $0) },
                updatedAt: row.updatedAt.flatMap { formatter.date(from: $0) })
        }
    }

    private static func state(_ value: String) -> State {
        switch value.uppercased() {
        case "MERGED": .merged
        case "CLOSED": .closed
        default: .open
        }
    }

    private static func review(_ value: String?) -> Review {
        switch value?.uppercased() {
        case "APPROVED": .approved
        case "CHANGES_REQUESTED": .changesRequested
        case "REVIEW_REQUIRED": .reviewRequired
        default: .none
        }
    }

    /// A failure anywhere wins, then anything still running, otherwise it passed.
    private static func checks(_ items: [(status: String?, conclusion: String?, state: String?)]) -> Checks {
        guard !items.isEmpty else { return .none }
        let failed: Set<String> = ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR"]
        let running: Set<String> = ["QUEUED", "IN_PROGRESS", "PENDING", "WAITING", "REQUESTED", "EXPECTED"]

        var anyPending = false
        for item in items {
            let conclusion = item.conclusion?.uppercased() ?? ""
            let status = item.status?.uppercased() ?? ""
            let state = item.state?.uppercased() ?? ""
            if failed.contains(conclusion) || failed.contains(state) { return .failing }
            if running.contains(status) || running.contains(state) { anyPending = true }
        }
        return anyPending ? .pending : .passing
    }
}

extension GhCliProvider {
    /// The pull request that matters for a branch, or nil when there is none, `gh` is not signed in, or the
    /// call fails for any reason. Only ever called for the one item being looked at.
    public func pullRequestStatus(forBranch branch: String, in repoRoot: URL) async -> PullRequestStatus? {
        guard !branch.isEmpty, !branch.hasPrefix("-") else { return nil }
        guard !reachability.isOffline else { return nil }
        let output: CommandOutput
        do {
            output = try await runner.run(
                ["pr", "list", "--head", branch, "--state", "all", "--limit", "10",
                 "--json", "number,title,state,isDraft,reviewDecision,url,updatedAt,statusCheckRollup"],
                in: repoRoot)
        } catch {
            if GitHubReachability.isNetworkError(error) { reachability.recordNetworkFailure() }
            return nil
        }
        if output.succeeded {
            reachability.recordSuccess()
        } else {
            if GitHubReachability.looksLikeNoNetwork(output.stderr) { reachability.recordNetworkFailure() }
            return nil
        }
        return (try? PullRequestStatus.decode(output.stdout)).flatMap(PullRequestStatus.mostRelevant)
    }
}

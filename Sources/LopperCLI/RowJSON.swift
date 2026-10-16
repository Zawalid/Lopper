import Foundation
import Lopper

/// The stable, versioned shape of `--json` output. Bump `schema` when a field changes meaning.
struct JSONEnvelope<Payload: Encodable>: Encodable {
    let schema = 1
    let generatedAt: String
    let payload: Payload

    private enum CodingKeys: String, CodingKey { case schema, generatedAt }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schema, forKey: .schema)
        try container.encode(generatedAt, forKey: .generatedAt)
        try payload.encode(to: encoder)
    }
}

struct RowJSON: Encodable {
    let id: String
    let kind: String
    let repository: String
    let repositoryPath: String
    let title: String
    let path: String?
    let verdict: String
    let evidence: String
    let reasons: [String]
    let lastCommit: String?
    let sizeBytes: Int64?
    let pullRequest: Int?
    let bulkEligible: Bool
    let agent: AgentJSON?

    struct AgentJSON: Encodable {
        let tool: String
        let state: String
        let note: String?
    }

    init(_ row: CleanupRow) {
        id = row.id
        kind = row.kind == .branch ? "branch" : "worktree"
        repository = row.repoName
        repositoryPath = row.repoRoot.path
        title = row.title
        path = row.path?.path
        verdict = row.verdict.rawValue
        evidence = row.evidence
        reasons = row.reasons
        lastCommit = row.lastCommit.map(Format.iso8601)
        sizeBytes = row.size
        pullRequest = row.prNumber
        bulkEligible = row.isBulkEligible
        agent = row.agent.map {
            AgentJSON(tool: $0.detection.tool.rawValue, state: $0.state.rawValue, note: $0.rowNote)
        }
    }
}

enum JSONOutput {
    static func string<T: Encodable>(_ payload: T, now: Date) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(JSONEnvelope(generatedAt: Format.iso8601(now), payload: payload))
        return String(decoding: data, as: UTF8.self)
    }
}

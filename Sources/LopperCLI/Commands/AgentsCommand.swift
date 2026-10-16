import ArgumentParser
import Foundation
import Lopper

struct AgentsPayload: Encodable {
    struct ToolTotal: Encodable {
        let tool: String
        let count: Int
        let bytes: Int64
    }

    let total: Int
    let finished: Int
    let reclaimableBytes: Int64
    let notMerged: Int
    let tools: [ToolTotal]
    let worktrees: [RowJSON]
}

struct AgentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Worktrees left by Claude Code, Cursor, Codex and Conductor: which are finished, which hold unmerged work.")

    @OptionGroup var options: GlobalOptions

    @Flag(name: .customLong("reclaim-finished"), help: "Remove the finished ones, after you confirm.")
    var reclaimFinished = false

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation when reclaiming. Required when not in a terminal.")
    var yes = false

    @Flag(name: .long, help: "With --reclaim-finished: show the plan and stop.")
    var dryRun = false

    func run() async throws {
        let session = try Session.open(options)
        let console = session.console
        let scan = await session.workspace.scan()
        let rows = scan.rows
            .filter { $0.agent != nil }
            .sorted {
                let left = $0.agent?.state.displayRank ?? 9, right = $1.agent?.state.displayRank ?? 9
                if left != right { return left < right }
                return ($0.agent?.lastActivity ?? .distantPast) < ($1.agent?.lastActivity ?? .distantPast)
            }
        let agentRows = rows.compactMap { row in row.agent.map { AgentRow(row: row, assessment: $0) } }
        let reclaimable = rows.filter(\.isBulkEligible)
        let reclaimBytes = reclaimable.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let notMerged = agentRows.filter { $0.assessment.state == .unmerged || $0.assessment.state == .abandoned }.count
        let tools = AgentToolTotal.totals(of: agentRows)

        if reclaimFinished {
            try session.requireTrustedSettings()
            let held = rows.filter { !$0.isBulkEligible }
            if reclaimable.isEmpty {
                console.line(options.json ? "{}" : "No finished agent worktrees to reclaim.")
                return
            }
            try await CleanFlow.execute(session: session, chosen: reclaimable, held: held, dryRun: dryRun, yes: yes)
            return
        }

        if options.json {
            let payload = AgentsPayload(
                total: rows.count, finished: reclaimable.count, reclaimableBytes: reclaimBytes, notMerged: notMerged,
                tools: tools.map { .init(tool: $0.tool.rawValue, count: $0.count, bytes: $0.bytes) },
                worktrees: rows.map(RowJSON.init))
            console.line(try JSONOutput.string(payload, now: session.now))
            return
        }
        if rows.isEmpty {
            console.line("No agent worktrees found in your folders.")
            return
        }
        console.line(session.style.bold(
            "\(Format.count(rows.count, "agent worktree")): \(reclaimable.count) finished"
                + (reclaimBytes > 0 ? " (\(Format.bytes(reclaimBytes)))" : "") + ", \(notMerged) not merged."))
        console.line(session.style.dim(tools.map { "\($0.tool.label) \($0.count) \(Format.bytes($0.bytes))" }.joined(separator: "   ")))
        console.line()
        let titleWidth = min(max(rows.map(\.title.count).max() ?? 4, 4), 36)
        for row in rows {
            guard let agent = row.agent else { continue }
            console.line([
                Format.column(agent.state.label, 10), Format.column(agent.detection.tool.label, 11),
                Format.column(row.title, titleWidth), Format.column(row.repoName, 16),
                Format.column(Format.age(of: agent.lastActivity, now: session.now), 6),
                Format.column(row.size.map { Format.bytes($0) } ?? "", 9), agent.rowNote ?? "",
            ].joined(separator: " "))
        }
        if !reclaimable.isEmpty {
            console.line()
            console.line(session.style.dim("`lop agents --reclaim-finished` removes the \(reclaimable.count) finished ones."))
        }
    }
}

import ArgumentParser
import Foundation
import Lopper

struct RepoCounts: Encodable {
    let name: String
    let path: String
    let safe: Int
    let review: Int
    let protected: Int
    let reclaimableBytes: Int64
    let error: String?
}

struct ScanPayload: Encodable {
    let repositories: [RepoCounts]
    let safe: Int
    let review: Int
    let protected: Int
    let reclaimableBytes: Int64
}

/// How a repository's rows add up. "Safe" is what a bulk clean would remove, so an agent worktree that may
/// still be in use counts as needing a look, exactly as in the app.
func summarize(_ scan: WorkspaceScan) -> ScanPayload {
    var counts: [RepoCounts] = []
    for result in scan.results {
        switch result {
        case .failure(let root, let message):
            counts.append(RepoCounts(
                name: root.lastPathComponent, path: root.path, safe: 0, review: 0, protected: 0,
                reclaimableBytes: 0, error: message))
        case .snapshot(let snapshot):
            let rows = scan.rows.filter { $0.repoRoot == snapshot.repo.root }
            counts.append(RepoCounts(
                name: snapshot.repo.name, path: snapshot.repo.root.path,
                safe: rows.filter(\.isBulkEligible).count,
                review: rows.filter { $0.verdict == .review || ($0.verdict == .safe && !$0.isBulkEligible) }.count,
                protected: rows.filter { $0.verdict == .protected }.count,
                reclaimableBytes: rows.filter(\.isBulkEligible).reduce(0) { $0 + ($1.size ?? 0) },
                error: nil))
        }
    }
    return ScanPayload(
        repositories: counts, safe: counts.reduce(0) { $0 + $1.safe }, review: counts.reduce(0) { $0 + $1.review },
        protected: counts.reduce(0) { $0 + $1.protected },
        reclaimableBytes: counts.reduce(0) { $0 + $1.reclaimableBytes })
}

struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Scan your folders and summarize what can be removed, repository by repository.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let session = try Session.open(options)
        let scan = await session.workspace.scan()
        let summary = summarize(scan)
        if options.json {
            session.console.line(try JSONOutput.string(summary, now: session.now))
            return
        }
        let nameWidth = min(max(summary.repositories.map(\.name.count).max() ?? 4, 4), 28)
        for repo in summary.repositories {
            if let error = repo.error {
                session.console.line("\(Format.column(repo.name, nameWidth))  \(session.style.red("could not be read")): \(error)")
                continue
            }
            let counts = [
                "\(repo.safe) safe", "\(repo.review) review", "\(repo.protected) protected",
            ].map { Format.column($0, 12) }.joined(separator: " ")
            let size = repo.reclaimableBytes > 0 ? Format.bytes(repo.reclaimableBytes) : ""
            session.console.line("\(session.style.bold(Format.column(repo.name, nameWidth)))  \(counts) \(size)")
        }
        session.console.line()
        session.console.line(
            "\(Format.count(summary.repositories.count, "repository", "repositories")): "
                + "\(summary.safe) safe to remove, \(summary.review) need a look, \(summary.protected) protected. "
                + "\(Format.bytes(summary.reclaimableBytes)) reclaimable.")
        if summary.safe > 0 { session.console.line(session.style.dim("Run `lop clean` to review and remove the safe ones.")) }
    }
}

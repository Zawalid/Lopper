import Foundation
import Lopper

// lopper-scan: read-only dry run. Prints what Lopper would classify, deletes nothing.
//
//   swift run lopper-scan ~/Personal/Projects ~/Professional [--no-gh] [--depth N]

var roots: [URL] = []
var useGh = true
var depth = 4
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--no-gh": useGh = false
    case "--depth": depth = arguments.next().flatMap(Int.init) ?? depth
    default:
        let expanded = (argument as NSString).expandingTildeInPath
        roots.append(URL(fileURLWithPath: expanded, isDirectory: true))
    }
}
guard !roots.isEmpty else {
    FileHandle.standardError.write(Data("usage: lopper-scan <root>... [--no-gh] [--depth N]\n".utf8))
    exit(2)
}

let settings = Settings(roots: roots, scanDepth: depth)
let provider: PRProvider? = useGh ? GhCliProvider() : nil
let service = ScanService(inspector: RepoInspector(settings: settings, prProvider: provider))

func label(_ kind: VerdictKind) -> String {
    switch kind {
    case .safe: "SAFE     "
    case .review: "REVIEW   "
    case .protected: "PROTECTED"
    }
}

func age(_ date: Date) -> String {
    let days = Int(Date().timeIntervalSince(date) / 86_400)
    return days < 1 ? "today" : "\(days)d"
}

func gigabytes(_ bytes: Int64) -> String {
    String(format: "%.2f GB", Double(bytes) / 1_073_741_824)
}

let results = await service.scan(roots: roots, maxDepth: depth)
var safeBranches = 0
var safeWorktrees = 0
var reclaimable: Int64 = 0

for result in results {
    switch result {
    case .failure(let root, let message):
        print("!! \(root.path): \(message)")
    case .snapshot(let snapshot):
        let gh = snapshot.prDetectionAvailable ? "" : "  (PR detection off)"
        print("\n== \(snapshot.repo.name)  [default: \(snapshot.repo.defaultBranch ?? "unknown")]\(gh)")
        for branch in snapshot.branches.sorted(by: { $0.name < $1.name }) {
            let reasons = branch.verdict.reasons.map(\.text).joined(separator: "; ")
            print("  branch   \(label(branch.verdict.kind)) \(branch.name)  \(age(branch.lastCommit))  \(reasons)")
            if branch.verdict.kind == .safe { safeBranches += 1 }
        }
        for worktree in snapshot.worktrees where !worktree.isMain {
            let usage = await SizeCalculator.measure(worktree.path, disposableNames: settings.disposableSet)
            let reasons = worktree.verdict.reasons.map(\.text).joined(separator: "; ")
            let hint = worktree.agentHint.map { " [agent: \($0)]" } ?? ""
            let prunable = worktree.isPrunable ? " [prunable]" : ""
            print("  worktree \(label(worktree.verdict.kind)) \(worktree.path.path)  \(gigabytes(usage.total))\(hint)\(prunable)  \(reasons)")
            if worktree.verdict.kind == .safe {
                safeWorktrees += 1
                reclaimable += usage.total
            }
        }
    }
}
print("\nSafe branches: \(safeBranches)   Safe worktrees: \(safeWorktrees)   Reclaimable from safe worktrees: \(gigabytes(reclaimable))")

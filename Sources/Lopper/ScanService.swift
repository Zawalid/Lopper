import Foundation

public enum RepoScanResult: Sendable, Equatable {
    case snapshot(RepoSnapshot)
    case failure(repoRoot: URL, message: String)

    public var repoRoot: URL {
        switch self {
        case .snapshot(let snapshot): snapshot.repo.root
        case .failure(let root, _): root
        }
    }
}

public enum ScanEvent: Sendable, Equatable {
    case discovered(count: Int)
    case result(RepoScanResult)
}

/// Discovers repos under the configured roots and inspects them in parallel.
/// A failing repo produces a `.failure` result and never affects the others.
public struct ScanService: Sendable {
    private let inspector: RepoInspector
    private let scanner: RepoScanner
    private let gate: RepoGate
    private let maxConcurrent: Int

    public init(
        inspector: RepoInspector,
        scanner: RepoScanner = RepoScanner(),
        gate: RepoGate = RepoGate(),
        maxConcurrent: Int = max(2, ProcessInfo.processInfo.activeProcessorCount)
    ) {
        self.inspector = inspector
        self.scanner = scanner
        self.gate = gate
        self.maxConcurrent = maxConcurrent
    }

    public func scan(roots: [URL], maxDepth: Int) async -> [RepoScanResult] {
        let repos = await Task.detached { [scanner] in
            scanner.findRepos(in: roots, maxDepth: maxDepth)
        }.value
        return await inspect(repos: repos)
    }

    public func inspect(repos: [URL]) async -> [RepoScanResult] {
        var results: [RepoScanResult] = []
        await withTaskGroup(of: RepoScanResult.self) { group in
            var iterator = repos.makeIterator()
            func addNext() {
                guard let repo = iterator.next() else { return }
                group.addTask { await self.inspectOne(repo) }
            }
            for _ in 0..<maxConcurrent { addNext() }
            while let result = await group.next() {
                results.append(result)
                addNext()
            }
        }
        return results.sorted { $0.repoRoot.path < $1.repoRoot.path }
    }

    /// Discovers repositories, then yields each result as soon as that repository is done, so a UI can
    /// fill in progressively. The stream finishes after the last repository.
    public func scanStream(roots: [URL], maxDepth: Int) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task {
                let repos = await Task.detached { [scanner] in
                    scanner.findRepos(in: roots, maxDepth: maxDepth)
                }.value
                continuation.yield(.discovered(count: repos.count))
                await withTaskGroup(of: RepoScanResult.self) { group in
                    var iterator = repos.makeIterator()
                    func addNext() {
                        guard let repo = iterator.next() else { return }
                        group.addTask { await self.inspectOne(repo) }
                    }
                    for _ in 0..<maxConcurrent { addNext() }
                    while let result = await group.next() {
                        continuation.yield(.result(result))
                        if Task.isCancelled { group.cancelAll(); break }
                        addNext()
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func inspectOne(_ repo: URL) async -> RepoScanResult {
        do {
            let inspector = self.inspector
            let snapshot = try await gate.run(key: repo.path) {
                try await inspector.inspect(repoRoot: repo)
            }
            return .snapshot(snapshot)
        } catch {
            return .failure(repoRoot: repo, message: UserMessage.describe(error))
        }
    }
}

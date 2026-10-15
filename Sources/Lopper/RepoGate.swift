import Foundation

/// Serializes work per key (a repository path) so two git operations never race on the same repo.
public actor RepoGate {
    private var tails: [String: Task<Void, Never>] = [:]

    public init() {}

    public func run<T: Sendable>(
        key: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tails[key]
        let task = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await body()
        }
        tails[key] = Task { _ = await task.result }
        // The work runs in its own unstructured task, so cancellation must be forwarded explicitly.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

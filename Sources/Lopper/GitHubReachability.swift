import Foundation
import os

/// Remembers that GitHub could not be reached, so a scan of dozens of repositories asks once instead of waiting for
/// the network once per repository. After a cooldown the next scan tries again, so coming back online is noticed.
public final class GitHubReachability: Sendable {
    /// Shared by every scan in the process: each scan builds its own provider, and the memory has to outlive them.
    public static let shared = GitHubReachability()

    private let cooldown: TimeInterval
    private let now: @Sendable () -> Date
    private let offlineUntil = OSAllocatedUnfairLock<Date?>(initialState: nil)

    public init(cooldown: TimeInterval = 45, now: @escaping @Sendable () -> Date = { Date() }) {
        self.cooldown = cooldown
        self.now = now
    }

    public var isOffline: Bool {
        offlineUntil.withLock { state in
            guard let end = state else { return false }
            if now() < end { return true }
            state = nil
            return false
        }
    }

    public func recordNetworkFailure() {
        let end = now().addingTimeInterval(cooldown)
        offlineUntil.withLock { $0 = end }
    }

    public func recordSuccess() {
        offlineUntil.withLock { $0 = nil }
    }

    /// True for the messages `gh` prints when it cannot reach GitHub at all. A repository that is not on GitHub, or a
    /// login that is missing, says nothing about the others and is not matched.
    public static func looksLikeNoNetwork(_ stderr: String) -> Bool {
        let text = stderr.lowercased()
        return [
            "no such host", "dial tcp", "i/o timeout", "network is unreachable", "error connecting to",
            "could not resolve", "context deadline exceeded", "tls handshake timeout", "connection refused",
        ].contains { text.contains($0) }
    }
}

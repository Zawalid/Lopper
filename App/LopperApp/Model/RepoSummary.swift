import Foundation
import Lopper

struct RepoSummary: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let root: URL
    let safeBranches: Int
    let safeWorktrees: Int
    let review: Int
    let protected: Int
    let reclaimableBytes: Int64
    let defaultBranch: String?
    /// Set when the scan of this repository failed.
    let failure: String?

    var safe: Int { safeBranches + safeWorktrees }
    var total: Int { safe + review + protected }
    var hasSafeItems: Bool { safe > 0 }

    /// What a screen reader says after the name.
    var countsDescription: String {
        if failure != nil { return "Could not be read" }
        return "\(safe) safe, \(review) to review, \(protected) protected"
    }
}

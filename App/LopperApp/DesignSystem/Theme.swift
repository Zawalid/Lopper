import SwiftUI
import Lopper

enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
}

extension VerdictKind {
    var tint: Color {
        switch self {
        case .safe: .green
        case .review: .orange
        case .protected: .secondary
        }
    }

    var symbol: String {
        switch self {
        case .safe: "checkmark.circle"
        case .review: "eye"
        case .protected: "lock"
        }
    }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .protected: "Protected"
        }
    }
}

extension CleanupRow.Kind {
    var symbol: String {
        switch self {
        case .branch: "arrow.triangle.branch"
        case .worktree: "rectangle.stack"
        }
    }

    var label: String {
        switch self {
        case .branch: "Branch"
        case .worktree: "Worktree"
        }
    }
}

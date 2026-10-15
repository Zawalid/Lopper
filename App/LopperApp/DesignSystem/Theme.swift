import SwiftUI
import AppKit
import Lopper

enum Theme {
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }

    /// The background behind every page. An explicit solid color, because the system window background is
    /// tinted by whatever wallpaper sits behind the window and drifts from dark gray to a washed-out one
    /// without any change in the app.
    static let pageBackgroundNS = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.15, alpha: 1) : .windowBackgroundColor
    }

    static var pageBackground: Color { Color(nsColor: pageBackgroundNS) }

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

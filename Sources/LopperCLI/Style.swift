import Foundation
import Lopper

/// ANSI styling that switches itself off when output is not a terminal.
struct Style {
    let enabled: Bool

    private func wrap(_ text: String, _ code: String) -> String {
        enabled ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    func bold(_ text: String) -> String { wrap(text, "1") }
    func dim(_ text: String) -> String { wrap(text, "2") }
    func green(_ text: String) -> String { wrap(text, "32") }
    func yellow(_ text: String) -> String { wrap(text, "33") }
    func red(_ text: String) -> String { wrap(text, "31") }

    func verdict(_ kind: VerdictKind) -> String {
        let label = Format.column(Self.label(kind), 9)
        switch kind {
        case .safe: return green(label)
        case .review: return yellow(label)
        case .protected: return dim(label)
        }
    }

    static func label(_ kind: VerdictKind) -> String {
        switch kind {
        case .safe: "SAFE"
        case .review: "REVIEW"
        case .protected: "PROTECTED"
        }
    }
}

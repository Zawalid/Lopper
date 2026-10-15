import Foundation

enum SizeFormat {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

enum AgeFormat {
    /// "today", "5d", "3mo", "2y": compact enough for a table column.
    static func short(from date: Date, to now: Date = Date()) -> String {
        let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
        switch days {
        case 0: return "today"
        case 1..<60: return "\(days)d"
        case 60..<730: return "\(days / 30)mo"
        default: return "\(days / 365)y"
        }
    }
}

enum Plural {
    /// "1 branch", "3 branches".
    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) " + (n == 1 ? singular : (plural ?? singular + "s"))
    }
}

import Foundation

/// Plain, locale-independent formatting, so output is the same on every machine and easy to parse.
enum Format {
    /// 453.7 MB, 1.5 GB, 820 KB. Decimal units, one decimal above a megabyte.
    static func bytes(_ count: Int64) -> String {
        let value = Double(max(count, 0))
        let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
        for (size, unit) in units where value >= size {
            let scaled = value / size
            return unit == "KB" ? "\(Int(scaled.rounded())) \(unit)" : String(format: "%.1f %@", scaled, unit)
        }
        return "\(Int(value)) B"
    }

    /// today, 3d, 6w, 2mo, 1y: the age of a date, coarse on purpose.
    static func age(of date: Date?, now: Date) -> String {
        guard let date else { return "-" }
        let days = Int(now.timeIntervalSince(date) / 86_400)
        switch days {
        case ..<1: return "today"
        case ..<14: return "\(days)d"
        case ..<60: return "\(days / 7)w"
        case ..<730: return "\(days / 30)mo"
        default: return "\(days / 365)y"
        }
    }

    static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }

    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    /// Pads or truncates to exactly `width` characters, for table columns.
    static func column(_ text: String, _ width: Int) -> String {
        if text.count > width { return String(text.prefix(max(width - 1, 1))) + "~" }
        return text + String(repeating: " ", count: width - text.count)
    }
}

import Foundation

/// Where one item sits in the list being worked through, and which items are next to it.
struct TriagePosition: Equatable {
    /// One-based, as people count.
    let index: Int
    let total: Int
    let previousID: String?
    let nextID: String?
}

enum Triage {
    static func position(of id: String, in ids: [String]) -> TriagePosition? {
        guard let offset = ids.firstIndex(of: id) else { return nil }
        return TriagePosition(
            index: offset + 1,
            total: ids.count,
            previousID: offset > 0 ? ids[offset - 1] : nil,
            nextID: offset + 1 < ids.count ? ids[offset + 1] : nil)
    }
}

enum SnoozeDuration: CaseIterable, Identifiable {
    case oneWeek, twoWeeks, oneMonth

    var id: Self { self }

    var days: Int {
        switch self {
        case .oneWeek: 7
        case .twoWeeks: 14
        case .oneMonth: 30
        }
    }

    var title: String {
        switch self {
        case .oneWeek: "For a week"
        case .twoWeeks: "For 2 weeks"
        case .oneMonth: "For a month"
        }
    }

    /// What the confirmation says after snoozing.
    var phrase: String {
        switch self {
        case .oneWeek: "a week"
        case .twoWeeks: "2 weeks"
        case .oneMonth: "a month"
        }
    }

    func date(from now: Date) -> Date { now.addingTimeInterval(Double(days) * 86_400) }
}

/// Items put aside until a date: hidden from the lists that nag, never removed or changed in any way.
struct Snoozes: Equatable {
    private var dates: [String: Date] = [:]

    init() {}

    /// Reads the stored form. Anything unreadable is treated as "nothing snoozed": a lost snooze only makes an
    /// item show up again, which is harmless.
    init(encoded: String?) {
        guard let encoded, !encoded.isEmpty,
              let decoded = try? Self.decoder.decode([String: Date].self, from: Data(encoded.utf8)) else { return }
        dates = decoded
    }

    var encoded: String {
        guard let data = try? Self.encoder.encode(dates) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func until(for id: String) -> Date? { dates[id] }

    func isSnoozed(_ id: String, now: Date) -> Bool {
        guard let date = dates[id] else { return false }
        return date > now
    }

    func snoozing(_ id: String, until date: Date) -> Snoozes {
        var copy = self
        copy.dates[id] = date
        return copy
    }

    func waking(_ id: String) -> Snoozes {
        var copy = self
        copy.dates[id] = nil
        return copy
    }

    func pruned(now: Date) -> Snoozes {
        var copy = self
        copy.dates = dates.filter { $0.value > now }
        return copy
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

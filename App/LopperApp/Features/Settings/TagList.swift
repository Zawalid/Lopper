import Foundation

/// The rules behind the tag editor, kept apart from the view so they can be tested directly.
enum TagList {
    /// Adds one or more comma-separated tags: trimmed, empty ones ignored, duplicates ignored, order kept.
    static func adding(_ input: String, to tags: [String]) -> [String] {
        var result = tags
        for piece in input.split(separator: ",") {
            let tag = piece.trimmingCharacters(in: .whitespaces)
            if !tag.isEmpty, !result.contains(tag) { result.append(tag) }
        }
        return result
    }

    static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0 != tag }
    }
}

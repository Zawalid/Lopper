import SwiftUI

/// A list of short values shown as removable chips, with a field to add more (comma separated is fine).
struct TagListEditor: View {
    @Binding var tags: [String]
    var prompt: String
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(tags, id: \.self) { tag in
                        TagChip(title: tag) { tags = TagList.removing(tag, from: tags) }
                    }
                }
            }
            HStack {
                TextField(prompt, text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func add() {
        tags = TagList.adding(draft, to: tags)
        draft = ""
    }
}

struct TagChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.callout.monospaced()).lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(0.14), in: Capsule())
    }
}

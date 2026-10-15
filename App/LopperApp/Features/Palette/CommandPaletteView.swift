import SwiftUI

/// Command-K: type to jump to a page, repository, branch or generated folder, or to run an action.
struct CommandPaletteView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selection: PaletteItem.ID?
    @State private var items: [PaletteItem] = []
    @FocusState private var focused: Bool

    private var results: [PaletteItem] {
        Array(CommandPalette.search(items, query: query).prefix(60))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search branches, worktrees, folders, pages and actions", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(performSelected)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { model.showsPalette = false; return .handled }
            }
            .padding(Theme.Spacing.lg)
            Divider()
            let shown = results
            if shown.isEmpty {
                Text("Nothing matches \"\(query)\"")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(shown) { item in
                                row(item, isSelected: item.id == selection)
                                    .id(item.id)
                                    .onTapGesture { perform(item) }
                            }
                        }
                        .padding(Theme.Spacing.sm)
                    }
                    .onChange(of: selection) { _, new in
                        if let new { proxy.scrollTo(new) }
                    }
                }
            }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            items = model.paletteItems()
            selection = results.first?.id
            focused = true
        }
        .onChange(of: query) { _, _ in selection = results.first?.id }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1).truncationMode(.middle)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.caption).lineLimit(1)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            Text(item.kind.heading)
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.white.opacity(0.7) : Color.secondary.opacity(0.7))
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        let shown = results
        guard !shown.isEmpty else { return }
        let current = shown.firstIndex { $0.id == selection } ?? 0
        selection = shown[min(max(current + delta, 0), shown.count - 1)].id
    }

    private func performSelected() {
        if let item = results.first(where: { $0.id == selection }) { perform(item) }
    }

    private func perform(_ item: PaletteItem) {
        model.showsPalette = false
        // Let the sheet close first: some targets open another sheet.
        DispatchQueue.main.async { model.perform(item) }
    }
}

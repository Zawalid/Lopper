import SwiftUI
import Lopper

struct HistoryView: View {
    @Environment(AppModel.self) private var model

    private struct Batch: Identifiable {
        let id: UUID
        let batchID: UUID?
        let records: [UndoRecord]
        var date: Date { records.map(\.timestamp).max() ?? .distantPast }
        var restorable: Bool { batchID != nil && records.contains { $0.status == .completed } }
    }

    private var groups: [Batch] {
        Dictionary(grouping: model.history.filter { $0.status != .pending }) { $0.batchID ?? $0.id }
            .map { key, records in
                Batch(id: key, batchID: records.first?.batchID, records: records)
            }
            .sorted { $0.date > $1.date }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                EmptyState(
                    symbol: "clock.arrow.circlepath", title: "No removals yet",
                    message: "Everything Lopper removes shows up here, and can be restored for \(model.settings.trashRetentionDays) days.")
            } else {
                List {
                    ForEach(groups) { group in
                        DisclosureGroup {
                            ForEach(group.records) { record in
                                RecordRow(record: record)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Plural.count(group.records.count, "item") + " removed").font(.headline)
                                    Text(group.date, format: .dateTime.day().month().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let batchID = group.batchID, group.restorable {
                                    Button("Restore all") { model.restoreBatch(batchID) }
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
    }
}

private struct RecordRow: View {
    let record: UndoRecord
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Image(systemName: record.action == .deleteBranch ? "arrow.triangle.branch" : "rectangle.stack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(record.branch ?? URL(fileURLWithPath: record.worktreePath ?? "").lastPathComponent)
                Text(URL(fileURLWithPath: record.repoPath).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch record.status {
            case .completed:
                Button("Restore") { model.restore(record) }.controlSize(.small)
            case .restored:
                Text("Restored").font(.caption).foregroundStyle(.secondary)
            case .expired:
                Text("Expired").font(.caption).foregroundStyle(.tertiary)
            case .failed:
                Text("Failed").font(.caption).foregroundStyle(.orange)
            case .pending:
                EmptyView()
            }
        }
    }
}

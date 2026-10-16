import Foundation
import Lopper

/// One thing the person's rules found. Rules only suggest: opening a suggestion goes to the same review sheet as
/// any other cleanup, and nothing is removed without that step.
struct RuleSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case untouchedFolders, oldMergedBranches }

    let kind: Kind
    let title: String
    let detail: String
    let count: Int
    let bytes: Int64
    let artifactIDs: [String]
    let rowIDs: [String]

    var id: Kind { kind }
}

enum RuleEvaluator {
    static func suggestions(
        rules: Settings.Rules, projects: [DiskProject], rows: [CleanupRow],
        isSnoozed: (CleanupRow) -> Bool, now: Date
    ) -> [RuleSuggestion] {
        var found: [RuleSuggestion] = []

        if rules.untouchedFolders.isEnabled {
            let days = rules.untouchedFolders.days
            let idle = projects.filter { $0.isUntouched(now: now, staleDays: days) && !$0.clearable.isEmpty }
            let folders = idle.flatMap(\.clearable)
            if !folders.isEmpty {
                found.append(RuleSuggestion(
                    kind: .untouchedFolders,
                    title: "Clear generated folders in \(Plural.count(idle.count, "idle project"))",
                    detail: "Nobody has edited \(idle.count == 1 ? "it" : "them") for \(days)+ days. "
                        + "\(Plural.count(folders.count, "folder")), \(SizeFormat.string(folders.reduce(0) { $0 + $1.bytes })). "
                        + "Each comes back when the project is next built.",
                    count: folders.count, bytes: folders.reduce(0) { $0 + $1.bytes },
                    artifactIDs: folders.map(\.id), rowIDs: []))
            }
        }

        if rules.oldMergedBranches.isEnabled {
            let days = rules.oldMergedBranches.days
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let old = rows.filter { row in
                row.kind == .branch && row.isBulkEligible && !isSnoozed(row)
                    && (row.lastCommit.map { $0 < cutoff } ?? false)
            }
            if !old.isEmpty {
                found.append(RuleSuggestion(
                    kind: .oldMergedBranches,
                    title: "Remove \(Plural.count(old.count, "merged branch", "merged branches"))",
                    detail: "Already merged, and no commit for \(days)+ days. Every removal can be undone.",
                    count: old.count, bytes: 0, artifactIDs: [], rowIDs: old.map(\.id)))
            }
        }
        return found
    }
}

extension AppModel {
    var ruleSuggestions: [RuleSuggestion] {
        RuleEvaluator.suggestions(
            rules: settings.rules, projects: diskProjects, rows: allRows,
            isSnoozed: { isSnoozed($0, now: clock()) }, now: clock())
    }

    /// Opens the review sheet for a suggestion. Nothing is removed until the person confirms there.
    func review(_ suggestion: RuleSuggestion) {
        switch suggestion.kind {
        case .untouchedFolders:
            let ids = Set(suggestion.artifactIDs)
            beginDiskClear(artifacts.filter { ids.contains($0.id) }, title: suggestion.title)
        case .oldMergedBranches:
            let ids = Set(suggestion.rowIDs)
            beginClean(rows: allRows.filter { ids.contains($0.id) })
        }
    }
}

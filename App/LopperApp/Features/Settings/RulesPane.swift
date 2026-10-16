import SwiftUI
import Lopper

private typealias Rules = Lopper.Settings.Rules

/// Rules that find things worth cleaning. They only suggest: results appear on the Overview and in the weekly
/// digest, and nothing is removed until the person reviews it.
struct RulesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold {
            Section {
                RuleRow(
                    title: "Clear generated folders in idle projects",
                    detail: "node_modules, build output and caches in projects nobody has edited for a while.",
                    unit: "days without an edit",
                    rule: binding(\.untouchedFolders))
                RuleRow(
                    title: "Remove old merged branches",
                    detail: "Branches that are already merged and have had no new commit for a while.",
                    unit: "days without a commit",
                    rule: binding(\.oldMergedBranches))
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Rules only suggest. What they find shows on the Overview and in the weekly digest. "
                    + "You always review a list before anything is removed, and every removal can be undone.")
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Rules, Rules.Rule>) -> Binding<Rules.Rule> {
        Binding(
            get: { model.settings.rules[keyPath: keyPath] },
            set: { value in model.updateSettings { $0.rules[keyPath: keyPath] = value } })
    }
}

private struct RuleRow: View {
    let title: String
    let detail: String
    let unit: String
    @Binding var rule: Rules.Rule

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Toggle(isOn: $rule.isEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            if rule.isEnabled {
                Stepper(value: $rule.days, in: 1...365) {
                    Text("After \(rule.days) \(unit)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .padding(.leading, 20)
            }
        }
    }
}

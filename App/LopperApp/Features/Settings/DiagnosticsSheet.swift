import SwiftUI
import AppKit

/// Shows exactly what would be shared. Nothing is sent: the person copies it or saves it and attaches it to a report.
struct DiagnosticsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var includeNames = false
    @State private var report = ""
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Diagnostics").font(.title3.weight(.semibold))
                Text("This is everything that would go into a bug report. Nothing is sent anywhere: copy it or save it, and attach it yourself.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Include repository and branch names", isOn: $includeNames)
                .help("Off by default, because names can say what you work on. Home folders, credentials and email addresses are always removed.")
            DiagnosticsText(report: report)
            HStack {
                Button("Report a problem") { openURL(ProjectLinks.Link.newIssue.url) }
                    .buttonStyle(.lopperLink)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    OpenActions.copy(report)
                    copied = true
                }
                .buttonStyle(.lopperSecondary)
                Button("Save…") { DiagnosticsSheet.save(report) }
                    .buttonStyle(.lopperSecondary)
                Button("Done") { dismiss() }
                    .buttonStyle(.lopperPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 560, height: 520)
        .task(id: includeNames) {
            copied = false
            report = await model.diagnosticsReport(includeNames: includeNames)
        }
    }

    private static func save(_ text: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "lopper-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The report as selectable text, separate from the sheet so it can be rendered offscreen.
struct DiagnosticsText: View {
    let report: String

    var body: some View {
        ScrollView {
            Text(report.isEmpty ? "Collecting…" : report)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Spacing.md)
        }
        .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
        .frame(maxHeight: .infinity)
    }
}

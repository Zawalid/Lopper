import SwiftUI
import AppKit

/// A checkbox that can say "some": the header of a table or a section, over rows that are partly picked.
struct TriStateCheckbox: View {
    let state: RowSelection.HeaderState
    var help: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(state == .none ? Color.secondary : Color.accentColor)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(state == .all ? "all selected" : (state == .some ? "some selected" : "none selected"))
    }

    private var symbol: String {
        switch state {
        case .none: "square"
        case .some: "minus.square.fill"
        case .all: "checkmark.square.fill"
        }
    }
}

/// A row's checkbox. Shift-click picks every row from the last one clicked to this one.
struct RowCheckbox: View {
    let isOn: Bool
    let isEnabled: Bool
    let title: String
    var disabledReason = "This row cannot be cleaned"
    /// Called with whether Shift was held.
    let toggle: (Bool) -> Void

    var body: some View {
        Button {
            toggle(NSApp.currentEvent?.modifierFlags.contains(.shift) == true)
        } label: {
            Image(systemName: isOn ? "checkmark.square.fill" : "square")
                .font(.system(size: 15))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor(isEnabled)
        .disabled(!isEnabled)
        .help(isEnabled ? "Select for cleaning. Shift-click picks a range." : disabledReason)
        .accessibilityLabel("Select \(title)")
        .accessibilityValue(isOn ? "selected" : "not selected")
    }
}

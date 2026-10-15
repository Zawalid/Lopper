import SwiftUI

/// The common frame of every Settings pane: a grouped form that scrolls when its content is long.
struct PaneScaffold<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
    }
}

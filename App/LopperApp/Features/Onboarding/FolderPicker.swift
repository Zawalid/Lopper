import AppKit

enum FolderPicker {
    @MainActor
    static func choose(_ completion: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose the folders that contain your projects."
        if panel.runModal() == .OK { completion(panel.urls) }
    }
}

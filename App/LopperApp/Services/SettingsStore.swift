import Foundation
import Lopper

struct SettingsStore: Sendable {
    let url: URL

    static var standard: SettingsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(url: base.appendingPathComponent("Lopper/settings.json"))
    }

    func load() -> Settings { Settings.load(from: url) }

    func save(_ settings: Settings) {
        try? settings.save(to: url)
    }
}

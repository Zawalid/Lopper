import Foundation
import Lopper

/// Reads and writes the engine settings file for the app. Saves are coalesced so dragging a stepper or typing
/// in a field writes once, not on every change; `flush()` writes at once (the app calls it on quit).
final class SettingsStore: @unchecked Sendable {
    typealias Writer = @Sendable (Settings, URL) throws -> Void

    let url: URL
    private let debounce: Duration
    private let writer: Writer
    private let lock = NSLock()
    private var pending: Settings?
    private var task: Task<Void, Never>?

    static var standard: SettingsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SettingsStore(url: base.appendingPathComponent("Lopper/settings.json"))
    }

    init(
        url: URL,
        debounce: Duration = .milliseconds(300),
        writer: @escaping Writer = { settings, url in try settings.save(to: url) }
    ) {
        self.url = url
        self.debounce = debounce
        self.writer = writer
    }

    /// Loads without ever discarding a file that cannot be read: see `SettingsLoader`.
    func load() -> SettingsLoadResult {
        SettingsLoader.load(from: url)
    }

    /// Remembers the latest value and writes it once changes stop arriving.
    func scheduleSave(_ settings: Settings) {
        lock.lock()
        pending = settings
        task?.cancel()
        let wait = debounce
        task = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
        lock.unlock()
    }

    /// Writes any pending value now. Safe to call repeatedly.
    func flush() {
        lock.lock()
        let value = pending
        pending = nil
        task?.cancel()
        task = nil
        lock.unlock()
        guard let value else { return }
        try? writer(value, url)
    }

    /// Copies the settings file next to itself as `settings.json.<label>`. Returns nil when there is no file.
    @discardableResult
    func backupFile(label: String) -> URL? {
        let destination = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent).\(label)")
        guard FileManager.default.fileExists(atPath: url.path),
            (try? FileManager.default.copyItem(at: url, to: destination)) != nil
        else { return nil }
        return destination
    }

    /// Immediate save, kept for callers that need the file on disk right away.
    func save(_ settings: Settings) {
        scheduleSave(settings)
        flush()
    }
}

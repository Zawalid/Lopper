import Foundation
import Observation
import Lopper

/// The setup flow: welcome, choose where to look, first scan. Everything that is decided lives here so the
/// views only draw it.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Equatable { case welcome, choose, scan }

    enum SystemScan: Equatable {
        case idle
        case running(folders: Int, repos: Int)
        case finished(found: Int)
        case stopped(found: Int)
    }

    struct Candidate: Identifiable, Equatable {
        enum Source: Equatable { case suggested, found, chosen, current }

        let url: URL
        var repoCount: Int?
        var sampleNames: [String] = []
        let source: Source
        var isSelected: Bool

        var id: String { url.path }
    }

    private(set) var step: Step = .welcome
    private(set) var candidates: [Candidate] = []
    private(set) var suggestionsLoaded = false
    private(set) var systemScan: SystemScan = .idle

    private let client: any EngineClient
    private var scanTask: Task<Void, Never>?

    init(client: any EngineClient, existingRoots: [URL], startingAt step: Step = .welcome) {
        self.client = client
        self.step = step
        candidates = existingRoots.map {
            Candidate(url: $0, repoCount: nil, source: .current, isSelected: true)
        }
    }

    var selectedURLs: [URL] { candidates.filter(\.isSelected).map(\.url) }
    var canContinue: Bool { candidates.contains(where: \.isSelected) }
    var isScanningSystem: Bool { if case .running = systemScan { true } else { false } }

    // MARK: Steps

    func next() {
        if step == .welcome { step = .choose }
    }

    func back() {
        if step == .choose { step = .welcome }
        if step == .scan { step = .choose }
    }

    /// Saves the ticked folders and moves to the first scan.
    func begin(app: AppModel) {
        guard canContinue else { return }
        stopSystemScan()
        app.setRoots(selectedURLs)
        step = .scan
    }

    // MARK: Suggestions

    func loadSuggestions() async {
        let suggestions = await client.folderSuggestions()
        let incoming = suggestions.map {
            Candidate(url: $0.path, repoCount: $0.repoCount, source: .suggested, isSelected: $0.hasRepos)
        }
        candidates = Self.merging(candidates, with: incoming)
        suggestionsLoaded = true
    }

    // MARK: Whole-system scan

    func startSystemScan() {
        guard !isScanningSystem else { return }
        systemScan = .running(folders: 0, repos: 0)
        scanTask = Task {
            var found = 0
            for await event in client.systemScan() {
                if Task.isCancelled { break }
                switch event {
                case .progress(let folders, let repos):
                    systemScan = .running(folders: folders, repos: repos)
                case .finished(let folders):
                    let before = candidates.count
                    let incoming = folders.map {
                        Candidate(
                            url: $0.path, repoCount: $0.repoCount, sampleNames: $0.sampleNames, source: .found,
                            isSelected: $0.repoCount >= 2)
                    }
                    candidates = Self.merging(candidates, with: incoming)
                    found = max(0, candidates.count - before)
                    systemScan = .finished(found: found)
                }
            }
            if case .running = systemScan { systemScan = .stopped(found: found) }
        }
    }

    func stopSystemScan() {
        guard isScanningSystem else { return }
        scanTask?.cancel()
        systemScan = .stopped(found: 0)
    }

    // MARK: Choosing

    func toggle(_ id: String) {
        guard let index = candidates.firstIndex(where: { $0.id == id }) else { return }
        candidates[index].isSelected.toggle()
    }

    /// Folders picked in the panel or dropped on the window: ticked, and never listed twice.
    func add(_ urls: [URL]) {
        let incoming = urls.map { Candidate(url: $0, repoCount: nil, source: .chosen, isSelected: true) }
        candidates = Self.merging(candidates, with: incoming)
    }

    // MARK: Merging

    private static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private static func isInside(_ inner: String, _ outer: String) -> Bool { inner.hasPrefix(outer + "/") }

    /// Adds `incoming` to `existing` without duplicates. A folder equal to a listed one only updates its numbers.
    /// A folder inside a listed one is covered by it (and a folder the person chose ticks the outer one). A folder
    /// above listed ones replaces the inner ones, keeping them ticked if any were.
    static func merging(_ existing: [Candidate], with incoming: [Candidate]) -> [Candidate] {
        var result = existing
        for new in incoming {
            let newKey = key(new.url)
            if let index = result.firstIndex(where: { key($0.url) == newKey }) {
                if let count = new.repoCount { result[index].repoCount = count }
                if !new.sampleNames.isEmpty { result[index].sampleNames = new.sampleNames }
                if new.source == .chosen { result[index].isSelected = true }
                continue
            }
            if let outer = result.firstIndex(where: { isInside(newKey, key($0.url)) }) {
                if new.source == .chosen { result[outer].isSelected = true }
                continue
            }
            var merged = new
            let inner = result.indices.filter { isInside(key(result[$0].url), newKey) }
            if !inner.isEmpty {
                if inner.contains(where: { result[$0].isSelected }) { merged.isSelected = true }
                let drop = Set(inner)
                result = result.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
            }
            result.append(merged)
        }
        return result
    }
}

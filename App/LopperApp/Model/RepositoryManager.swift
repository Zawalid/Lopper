import Foundation
import Lopper

/// One repository as the manager lists it: either found by the last scan, or hidden by the person.
struct ManagedRepository: Identifiable, Equatable {
    var id: String { root.path }
    let name: String
    let root: URL
    let isHidden: Bool
    /// Branches and worktrees found in it; zero for a hidden repository, which is not scanned.
    let items: Int
    let reclaimableBytes: Int64
    /// Set when the last scan could not read it.
    let problem: String?

    /// The directory that holds the repository, which is how the manager groups them.
    var folder: URL { root.deletingLastPathComponent() }
}

/// Repositories that share a containing directory, so a whole project folder can be handled in one step.
struct ManagedGroup: Identifiable, Equatable {
    var id: String { folder.path }
    let folder: URL
    let repositories: [ManagedRepository]

    var name: String { folder.lastPathComponent }
}

/// The pure part of the manager: grouping, searching and finding which scanned folder owns a repository.
enum RepositoryManagerPresenter {
    static func groups(of repositories: [ManagedRepository], search: String = "") -> [ManagedGroup] {
        let text = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = repositories.filter { repository in
            guard !text.isEmpty else { return true }
            return [repository.name, repository.root.path].contains {
                $0.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return Dictionary(grouping: shown, by: { $0.folder.path })
            .map { path, members in
                ManagedGroup(
                    folder: URL(fileURLWithPath: path),
                    repositories: members.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    || ($0.name == $1.name && $0.folder.path < $1.folder.path)
            }
    }

    /// The enabled scanned folder that contains `repository`, preferring the most specific one.
    static func owningFolder(of repository: URL, in folders: [FolderSetting]) -> FolderSetting? {
        let path = repository.canonicalized.path
        return folders
            .filter { folder in
                guard folder.isEnabled else { return false }
                let base = folder.path.canonicalized.path
                return path == base || path.hasPrefix(base + "/")
            }
            .max { $0.path.canonicalized.path.count < $1.path.canonicalized.path.count }
    }

    /// Whether a folder name can be skipped as it is. Scan exclusions are globs, so a name with glob characters
    /// would match more than the one folder.
    static func canSkip(folderNamed name: String) -> Bool {
        !name.isEmpty && name.rangeOfCharacter(from: CharacterSet(charactersIn: "*?[]{}")) == nil
    }
}

extension AppModel {
    /// Repositories the last scan found.
    var listedRepositories: [ManagedRepository] {
        summaries.map {
            ManagedRepository(
                name: $0.name, root: $0.root, isHidden: false, items: $0.total,
                reclaimableBytes: $0.reclaimableBytes, problem: $0.failure)
        }
    }

    /// Repositories the person hid. They are not scanned, so only their path is known.
    var hiddenRepositories: [ManagedRepository] {
        settings.repos
            .filter { $0.value.isIgnored }
            .map { path, _ in
                let url = URL(fileURLWithPath: path)
                return ManagedRepository(
                    name: url.lastPathComponent, root: url, isHidden: true, items: 0, reclaimableBytes: 0, problem: nil)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Stops scanning and listing these repositories, in one change and one rescan. Nothing is deleted from disk.
    func hideRepositories(_ roots: [URL]) {
        guard !roots.isEmpty else { return }
        updateSettings { settings in
            for root in roots { settings.repos[root.path, default: RepoOverrides()].isIgnored = true }
        }
    }

    /// Brings hidden repositories back into the scan, keeping any other setting they had.
    func showRepositories(_ roots: [URL]) {
        guard !roots.isEmpty else { return }
        updateSettings { settings in
            for root in roots {
                guard var overrides = settings.repos[root.path] else { continue }
                overrides.isIgnored = false
                settings.repos[root.path] = overrides == RepoOverrides() ? nil : overrides
            }
        }
    }

    /// Never enters folders with this name while scanning, by adding it to the scanned folder that holds `repository`.
    /// Exclusions are by name and apply in every scanned folder. Returns false when no folder owns the repository or
    /// the name could match more than one folder.
    @discardableResult
    func skipFolderNamed(_ name: String, containing repository: URL) -> Bool {
        guard RepositoryManagerPresenter.canSkip(folderNamed: name),
            let owner = RepositoryManagerPresenter.owningFolder(of: repository, in: settings.folders) else { return false }
        updateSettings { settings in
            guard let index = settings.folders.firstIndex(where: { $0.path == owner.path }),
                !settings.folders[index].excludePatterns.contains(name) else { return }
            settings.folders[index].excludePatterns.append(name)
        }
        return true
    }

    /// Takes a skipped folder name back out of every scanned folder that lists it.
    func stopSkippingFolderNamed(_ name: String) {
        updateSettings { settings in
            for index in settings.folders.indices {
                settings.folders[index].excludePatterns.removeAll { $0 == name }
            }
        }
    }
}

import Foundation
import Lopper

extension AppModel {
    /// Everything the palette can jump to or do, built from what is on screen now.
    func paletteItems() -> [PaletteItem] {
        var items: [PaletteItem] = []

        for page in PrimaryRoute.allCases {
            items.append(PaletteItem(
                id: "page:\(page.title)", title: page.title, subtitle: "Go to page", symbol: page.symbol,
                kind: .page, target: .route(page.route)))
        }

        func action(_ id: String, _ title: String, _ symbol: String, _ subtitle: String, _ what: PaletteItem.Action) {
            items.append(PaletteItem(
                id: "action:\(id)", title: title, subtitle: subtitle, symbol: symbol, kind: .action,
                target: .action(what)))
        }
        action("rescan", "Rescan", "arrow.clockwise", "Look at every folder again", .rescan)
        action("add", "Add folder…", "folder.badge.plus", "Scan another folder", .addFolder)
        if toast != nil { action("undo", "Undo last cleanup", "arrow.uturn.backward", "Bring it back", .undoLast) }
        if totals.safe > 0 {
            action(
                "clean", "Review and clean everything safe", "checkmark.circle",
                "\(Plural.count(totals.safe, "item")), \(SizeFormat.string(totals.reclaimableBytes))", .cleanAllSafe)
        }
        let disk = diskTotals
        if disk.clearableBytes > 0 {
            action(
                "folders", "Clear generated folders", "shippingbox",
                "\(SizeFormat.string(disk.clearableBytes)) can be cleared", .clearGeneratedFolders)
        }
        if disk.untouchedBytes > 0 {
            action(
                "untouched", "Clear folders in untouched projects", "clock",
                "\(SizeFormat.string(disk.untouchedBytes)) in projects idle \(settings.staleDays)+ days", .clearUntouched)
        }
        let trash = trashedTotals
        if trash.folders > 0 {
            action(
                "trash", "Delete cleared folders from the Trash", "trash",
                "\(SizeFormat.string(trash.bytes)) still in the Trash", .deleteTrashed)
        }

        for summary in summaries where summary.failure == nil {
            items.append(PaletteItem(
                id: "repo:\(summary.id)", title: summary.name, subtitle: summary.root.deletingLastPathComponent().lastPathComponent,
                symbol: "shippingbox", kind: .repository, target: .repository(summary.id)))
        }

        for row in allRows {
            items.append(PaletteItem(
                id: "row:\(row.id)", title: row.title,
                subtitle: "\(row.repoName) · \(row.kind == .worktree ? "Worktree" : "Branch")",
                symbol: row.kind == .worktree ? "rectangle.stack" : "arrow.triangle.branch", kind: .item,
                target: .row(id: row.id, repoID: row.repoRoot.path)))
        }

        for artifact in artifacts + developerCaches where artifact.removal.isOffered {
            let owner = artifact.location == .developerCache ? "Developer cache" : artifact.checkoutRoot.lastPathComponent
            items.append(PaletteItem(
                id: "folder:\(artifact.id)", title: artifact.name,
                subtitle: "\(owner) · \(SizeFormat.string(artifact.bytes))", symbol: "folder", kind: .folder,
                target: .folder(artifact.id)))
        }
        return items
    }

    func perform(_ item: PaletteItem) {
        switch item.target {
        case .route(let route):
            self.route = route
        case .repository(let id):
            route = .repo(id)
        case .row(let id, let repoID):
            searchText = ""
            verdictFilter = .all
            kindFilter = .all
            route = .repo(repoID)
            focusedRowID = id
        case .folder(let id):
            if let artifact = (artifacts + developerCaches).first(where: { $0.id == id }) {
                route = .disk
                beginClear(artifact: artifact)
            }
        case .action(let action):
            switch action {
            case .rescan: startScan()
            case .cleanAllSafe: beginCleanAllSafe()
            case .clearGeneratedFolders:
                route = .disk
                beginDiskClear(diskProjects.flatMap(\.clearable), title: "Clear generated folders")
            case .clearUntouched:
                route = .disk
                beginClearUntouched()
            case .deleteTrashed: deleteTrashedForGood()
            case .addFolder: FolderPicker.choose { [weak self] in self?.addRoots($0) }
            case .undoLast: undoToast()
            }
        }
    }
}

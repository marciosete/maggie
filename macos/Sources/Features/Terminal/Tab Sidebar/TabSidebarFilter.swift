import Foundation

/// Narrows the sidebar to the sessions the board's filter shows: those in the picked
/// folders and groups, with the picked colors, in the picked statuses.
enum TabSidebarFilter {
    /// Whether `filter` shows `tab`: by its folder, group and color, and by its column
    /// on the board.
    static func shows(_ tab: TabSidebarModel.Tab, filter: SessionBoardFilter, settings: SessionBoardSettings) -> Bool {
        filter.shows(folder: tab.folderID, group: tab.groupID, color: tab.color)
            && filter.shows(column: settings.column(for: tab.boardPlace?.column))
    }

    /// The rows showing only the sessions `filter` shows. A group, folder or folder
    /// group left with none goes, except a folder the filter picks, which shows as it
    /// is: empty. Nothing unfolds: unlike a search, a filter is left on, so what is
    /// folded stays folded.
    static func filter(
        _ rows: [TabSidebarModel.Row],
        by filter: SessionBoardFilter,
        settings: SessionBoardSettings = .shared
    ) -> [TabSidebarModel.Row] {
        guard filter.isActive else { return rows }
        return rows.compactMap { row in
            switch row {
            case .tab(let tab):
                return shows(tab, filter: filter, settings: settings) ? row : nil

            case .group(let section):
                let tabs = section.tabs.filter { shows($0, filter: filter, settings: settings) }
                guard !tabs.isEmpty else { return nil }
                return .group(.init(group: section.group, tabs: tabs))

            case .folder(let section):
                return folder(section, by: filter, settings: settings).map(TabSidebarModel.Row.folder)

            case .folderGroup(let section):
                let folders = section.folders.compactMap { folder($0, by: filter, settings: settings) }
                guard !folders.isEmpty else { return nil }
                return .folderGroup(.init(group: section.group, folders: folders))
            }
        }
    }

    private static func folder(
        _ section: TabSidebarModel.FolderSection,
        by filter: SessionBoardFilter,
        settings: SessionBoardSettings
    ) -> TabSidebarModel.FolderSection? {
        let rows = self.filter(section.rows, by: filter, settings: settings)
        guard !rows.isEmpty || filter.folders.contains(section.folder.id) else { return nil }
        return .init(folder: section.folder, rows: rows)
    }
}

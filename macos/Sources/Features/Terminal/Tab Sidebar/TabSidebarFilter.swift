import Foundation

/// Narrows the sidebar to the sessions the board's filter shows: those in the picked
/// folders and groups, with the picked colors, in the picked statuses.
enum TabSidebarFilter {
    /// Whether `filter` shows `tab`: by its folder, its groups and the color its row is
    /// filled with, and by its column on the board. A picked group shows the sessions
    /// of the groups and folders inside it too.
    static func shows(_ tab: TabSidebarModel.Tab, filter: SessionBoardFilter, settings: SessionBoardSettings) -> Bool {
        filter.shows(folder: tab.folderID, groups: tab.allGroupIDs, color: tab.fillColor)
            && filter.shows(column: settings.column(for: tab.boardPlace?.column))
    }

    /// The rows showing only the sessions `filter` shows. A group or folder left with
    /// none goes, except a folder the filter picks, which shows as it is: empty. Nothing
    /// unfolds: unlike a search, a filter is left on, so what is folded stays folded.
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
                let rows = self.filter(section.rows, by: filter, settings: settings)
                guard !rows.isEmpty else { return nil }
                return .group(.init(group: section.group, rows: rows))

            case .folder(let section):
                let rows = self.filter(section.rows, by: filter, settings: settings)
                guard !rows.isEmpty || filter.folders.contains(section.folder.id) else { return nil }
                return .folder(.init(folder: section.folder, rows: rows))
            }
        }
    }
}

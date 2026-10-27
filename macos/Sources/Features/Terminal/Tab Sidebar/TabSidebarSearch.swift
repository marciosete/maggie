import AppKit

/// Finds sessions in the sidebar by what they are called and where they work.
enum TabSidebarSearch {
    /// Whether every word of `query` is in one of `fields`, ignoring case and accents.
    static func matches(_ query: String, _ fields: [String?]) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = fields.compactMap { $0 }.joined(separator: "\n")
        return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// What a session is found by: its title, the names of its groups and its folder,
    /// its folder's path, and its project, branch and directory.
    static func fields(
        of tab: TabSidebarModel.Tab,
        groups: [UserTabGroup],
        folder: UserTabFolder? = nil,
        info: TabSidebarSessionInfo?
    ) -> [String?] {
        [tab.title]
            + groups.map(\.name)
            + [folder?.name, folder?.abbreviatedPath]
            + [info?.checkout?.project, info?.branch, info?.abbreviatedDirectory]
    }

    /// The rows showing only the sessions matching `query`. A group or folder whose
    /// name matches keeps all its sessions. Those with a match are shown open, whatever
    /// their state.
    static func filter(
        _ rows: [TabSidebarModel.Row],
        query: String,
        infos: [ObjectIdentifier: TabSidebarSessionInfo]
    ) -> [TabSidebarModel.Row] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
        return filter(rows, query: query, within: Context(), infos: infos)
    }

    /// What the rows being searched are in, whose names find their sessions too.
    private struct Context {
        var groups: [UserTabGroup] = []
        var folder: UserTabFolder?
    }

    private static func filter(
        _ rows: [TabSidebarModel.Row],
        query: String,
        within context: Context,
        infos: [ObjectIdentifier: TabSidebarSessionInfo]
    ) -> [TabSidebarModel.Row] {
        rows.compactMap { row in
            switch row {
            case .tab(let tab):
                let fields = Self.fields(of: tab, groups: context.groups, folder: context.folder, info: infos[tab.id])
                return matches(query, fields) ? row : nil

            case .group(let section):
                var group = section.group
                var inner = context
                inner.groups.append(group)
                let rows = matches(query, [group.name])
                    ? section.rows
                    : filter(section.rows, query: query, within: inner, infos: infos)
                guard !rows.isEmpty else { return nil }
                group.isCollapsed = false
                return .group(.init(group: group, rows: rows))

            case .folder(let section):
                var folder = section.folder
                var inner = context
                inner.folder = folder
                let rows = matches(query, [folder.name, folder.abbreviatedPath])
                    ? section.rows
                    : filter(section.rows, query: query, within: inner, infos: infos)
                guard !rows.isEmpty else { return nil }
                folder.isCollapsed = false
                return .folder(.init(folder: folder, rows: rows))
            }
        }
    }

    /// The sessions in `rows`, in the order they show.
    static func tabs(in rows: [TabSidebarModel.Row]) -> [TabSidebarModel.Tab] {
        rows.flatMap { row -> [TabSidebarModel.Tab] in
            switch row {
            case .tab(let tab): return [tab]
            case .group(let section): return section.group.isCollapsed ? [] : tabs(in: section.rows)
            case .folder(let section): return section.folder.isCollapsed ? [] : tabs(in: section.rows)
            }
        }
    }
}

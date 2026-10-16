import AppKit
import SwiftUI

/// One choice of a filter, such as a folder, shown by its name and symbol.
struct SessionBoardFilterOption<Value: Hashable> {
    let value: Value
    let label: String
    let image: NSImage?
}

/// What the filters offer, on the board and in the sidebar: the folders and groups the
/// sessions are in, the board's columns, and the colors of the cards shown. Only what
/// some session has is offered, so there is always something to pick.
struct SessionBoardFilterOptions {
    let folders: [SessionBoardFilterOption<UUID?>]
    let groups: [SessionBoardFilterOption<UUID?>]
    let columns: [SessionBoardFilterOption<String>]
    let colors: [SessionBoardFilterOption<TerminalTabColor>]

    /// For the sessions of `model`'s sidebar, and the work items where the board shows
    /// them. Folders and groups are the sessions'; work items alone have a status and a
    /// color, so with them alone the folders and groups are left out.
    @MainActor
    init(
        model: TabSidebarModel,
        tabs: [TabSidebarModel.Tab],
        items: [WorkItem] = [],
        mode: SessionBoardMode = .sessions,
        board: SessionBoardSettings = .shared
    ) {
        let showsSessions = mode != .workItems
        folders = showsSessions ? Self.folders(model: model, tabs: tabs) : []
        groups = showsSessions ? Self.groups(of: tabs) : []
        columns = board.columns.map { .init(value: $0.id, label: $0.label, image: $0.menuImage) }
        colors = Self.colors(of: showsSessions ? tabs : [], items: mode == .sessions ? [] : items, board: board)
    }

    /// `title`, the one picked, or how many: `2 Folders`.
    static func label<Value>(
        _ title: String,
        plural: String,
        options: [SessionBoardFilterOption<Value>],
        selection: Set<Value>
    ) -> String {
        let picked = options.filter { selection.contains($0.value) }
        switch picked.count {
        case 0: return title
        case 1: return picked[0].label
        default: return "\(picked.count) \(plural)"
        }
    }

    /// Every folder open in the sidebar, as it lists them, even one with no sessions,
    /// and any other folder a session is in; then the sessions in none.
    @MainActor
    private static func folders(model: TabSidebarModel, tabs: [TabSidebarModel.Tab]) -> [SessionBoardFilterOption<UUID?>] {
        let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        var folders = model.foldersInWindow
        for tab in tabs {
            guard let id = tab.folderID, !folders.contains(where: { $0.id == id }),
                  let folder = UserTabFolderStore.shared[id] else { continue }
            folders.append(folder)
        }
        var options: [SessionBoardFilterOption<UUID?>] = folders.map {
            .init(value: $0.id, label: $0.name, image: folderImage)
        }
        if tabs.contains(where: { $0.folderID == nil }), !options.isEmpty {
            options.append(.init(value: nil, label: "No Folder", image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)))
        }
        return options
    }

    /// The groups the sessions are in, in sidebar order, then the sessions in none.
    @MainActor
    private static func groups(of tabs: [TabSidebarModel.Tab]) -> [SessionBoardFilterOption<UUID?>] {
        var seen = Set<UUID?>()
        var options: [SessionBoardFilterOption<UUID?>] = []
        for tab in tabs where seen.insert(tab.groupID).inserted {
            guard let id = tab.groupID, let group = UserTabGroupStore.shared[id] else { continue }
            options.append(.init(value: id, label: group.name, image: group.color.swatchImage(selected: false)))
        }
        if seen.contains(nil), !options.isEmpty {
            options.append(.init(
                value: nil, label: "No Group", image: NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)))
        }
        return options
    }

    /// The colors of the cards shown, by their labels where they have them. A session
    /// following Claude Code shows the light's color, which changes as it works, so
    /// while any does every light is offered, named for what it means, such as Waiting
    /// for you: picked, it keeps showing the sessions in that state as they come and go.
    /// With one color there is nothing to choose between, so none are offered.
    private static func colors(
        of tabs: [TabSidebarModel.Tab],
        items: [WorkItem],
        board: SessionBoardSettings
    ) -> [SessionBoardFilterOption<TerminalTabColor>] {
        var used = Set(tabs.map(\.color) + items.map(\.color))
        let followsClaudeCode = tabs.contains { $0.assignedColor.followsClaudeCode }
        if followsClaudeCode {
            used.formUnion(ClaudeCodeLight.allCases.map(\.tabColor))
        }
        guard used.count > 1 else { return [] }
        return TerminalTabColor.allCases
            .filter(used.contains)
            .map { color in
                let light = followsClaudeCode ? ClaudeCodeLight.allCases.first { $0.tabColor == color } : nil
                let label = board.label(of: color) ?? light?.label ?? color.localizedName
                return .init(value: color, label: label, image: color.swatchImage(selected: false))
            }
    }
}

/// The choices of one filter, each toggling, and Show All once some are picked. Menu
/// content: the board's pills open on it, and the sidebar's filter menu holds it in a
/// submenu each. Each choice shows its symbol or swatch, the color a session shows in
/// the sidebar, so they are buttons with a ✓ in the text, as the color menus are: a
/// toggle's check takes the image's place. A pull-down menu shows titles alone unless
/// the label style asks for the icon.
struct SessionBoardFilterToggles<Value: Hashable>: View {
    let options: [SessionBoardFilterOption<Value>]
    @Binding var selection: Set<Value>

    var body: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
            Button {
                SessionBoardFilter.toggle(option.value, in: &selection)
            } label: {
                Label {
                    Text(selection.contains(option.value) ? "\(option.label) ✓" : option.label)
                } icon: {
                    if let image = option.image { Image(nsImage: image) }
                }
                .labelStyle(.titleAndIcon)
            }
        }
        if !selection.isEmpty {
            Divider()
            Button("Show All") { selection = [] }
        }
    }
}

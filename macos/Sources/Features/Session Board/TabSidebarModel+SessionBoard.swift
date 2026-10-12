import AppKit

extension TabSidebarModel {
    /// The sessions of the sidebar, in sidebar order.
    var boardTabs: [Tab] { rows.flatMap(\.allTabs) }

    /// Each board column's sessions, in their order on the board.
    func boardLanes(of tabs: [Tab]? = nil) -> [String: [ObjectIdentifier]] {
        SessionBoardLayout.lanes(
            (tabs ?? boardTabs).map { .init(id: $0.id, place: $0.boardPlace) },
            settings: .shared)
    }

    /// Moves a session to `column`, before the session `before` or at the column's end.
    func moveOnBoard(_ id: ObjectIdentifier, to column: String, before: ObjectIdentifier? = nil) {
        let tabs = boardTabs
        let places = SessionBoardLayout.move(id, to: column, before: before, lanes: boardLanes(of: tabs))
        for tab in tabs {
            if let place = places[tab.id] { tab.window?.boardPlace = place }
        }
    }

    func moveOnBoard(_ window: TerminalWindow, to column: String) {
        moveOnBoard(ObjectIdentifier(window), to: column)
    }

    /// Moves a session into the column of `target`, just before or after it.
    func moveOnBoard(_ window: TerminalWindow, nextTo target: TerminalWindow, after: Bool) {
        let moved = ObjectIdentifier(window)
        let targetID = ObjectIdentifier(target)
        let column = SessionBoardSettings.shared.column(for: target.boardPlace?.column)
        let lane = (boardLanes()[column] ?? []).filter { $0 != moved }
        guard let index = lane.firstIndex(of: targetID) else { return }
        let before = after ? (index + 1 < lane.count ? lane[index + 1] : nil) : targetID
        moveOnBoard(moved, to: column, before: before)
    }
}

extension SessionBoardColumn {
    /// The column's symbol in its color, for menus, which otherwise draw symbols in the
    /// text's color.
    var menuImage: NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
            .applying(.init(paletteColors: [displayColor]))
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: label)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = false
        return image
    }
}

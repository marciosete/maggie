import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The session board: cards in columns such as Todo, In progress, In review and Done.
/// It covers the terminal, beside the sidebar, and ⌘K shows or hides it. It shows the
/// work items, kept by hand like a kanban board; the sessions of the window's sidebar;
/// or both together, each session that is linked to an item under it, in its column.
/// Dragging a card moves it to another column or another place in its own; nothing
/// else moves it.
struct SessionBoardView: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = SessionBoardSettings.shared
    @ObservedObject var store = WorkItemStore.shared

    @State private var query = ""
    @State private var dragging: SessionBoardCardID?
    @State private var dropTarget: SessionBoardDropTarget?
    @State private var isEditingColumns = false
    @State private var escapeMonitor: Any?

    /// The column whose new card is being typed, and what is typed.
    @State private var addingIn: String?
    @State private var newTitle = ""

    /// The item whose title is being changed in place.
    @State private var renaming: UUID?
    @State private var renameDraft = ""

    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case search
        case newCard
        case rename
    }

    static let columnWidth: CGFloat = 280

    private var tabs: [TabSidebarModel.Tab] { model.boardTabs }

    var body: some View {
        let content = SessionBoardContent(
            mode: settings.mode, tabs: tabs, items: store.items, settings: settings,
            sessionLanes: model.boardLanes())
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(settings.columns) { column in
                        lane(column, content: content)
                    }
                }
                .padding(14)
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .background(background)
        .onAppear(perform: watchEscape)
        .onDisappear {
            stopWatchingEscape()
            TabSidebarHoverCard.shared.hideNow()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Board")
                .font(.system(size: 14, weight: .semibold))

            Picker("Show", selection: $settings.mode) {
                ForEach(SessionBoardMode.allCases, id: \.self) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Show the work items, the sessions, or the work items with their sessions")

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField(settings.mode == .sessions ? "Search sessions" : "Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .search)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: 200, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            SessionBoardFilterBar(model: model, tabs: tabs, items: store.items, mode: settings.mode)

            Spacer()

            Button {
                isEditingColumns.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit Columns")
            .popover(isPresented: $isEditingColumns, arrowEdge: .bottom) {
                SessionBoardColumnsEditor(settings: settings)
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close the Board (⌘K)")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    @ViewBuilder
    private var background: some View {
        if let color = model.titlebarColor {
            Color(nsColor: color)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    // MARK: Lanes

    private func lane(_ column: SessionBoardColumn, content: SessionBoardContent) -> some View {
        let color = Color(nsColor: column.displayColor)
        // Every column stays; filtered by status, only the picked ones keep their cards.
        let showsColumn = model.boardFilter.shows(column: column.id)
        let items = content.items(in: column.id)
        let sessions = content.sessions(in: column.id)
        let shownItems = showsColumn ? items.filter { matches($0, sessions: content.sessions(of: $0.id)) } : []
        let shownSessions = showsColumn ? sessions.filter(matches) : []
        let total = items.count + sessions.count
        let shown = shownItems.count + shownSessions.count
        let isNarrowed = isSearching || model.boardFilter.isActive
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: column.icon)
                    .foregroundStyle(color)
                Text(column.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isNarrowed ? "\(shown) / \(total)" : "\(total)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .frame(height: 38)

            Divider()

            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(shownItems) { item in
                        insertionLine(before: .item(item.id), in: column.id, color: color)
                        itemCard(item, sessions: content.sessions(of: item.id).filter(matches), column: column.id)
                    }
                    ForEach(shownSessions) { tab in
                        insertionLine(before: .session(tab.id), in: column.id, color: color)
                        sessionCard(tab, column: column.id)
                    }
                    if dropTarget == .init(column: column.id, before: nil) {
                        line(color)
                    }
                    if shown == 0 && addingIn != column.id {
                        Text(isNarrowed && total > 0 ? "No matches" : "Empty")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .foregroundStyle(Color.primary.opacity(0.15)))
                    }
                    if settings.mode != .sessions {
                        addCard(in: column.id)
                    }
                }
                .padding(8)
            }
        }
        .frame(width: Self.columnWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(column.color == .none ? 0.03 : 0.05)))
        .overlay(alignment: .top) {
            // The column's color runs along its top edge, as on Orca.
            UnevenRoundedRectangle(topLeadingRadius: 10, topTrailingRadius: 10)
                .fill(color.opacity(0.75))
                .frame(height: 2)
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        // Dropped anywhere else in the column, a card goes to its end.
        .onDrop(of: [.plainText], delegate: dropDelegate(.init(column: column.id, before: nil)))
    }

    @ViewBuilder
    private func insertionLine(before card: SessionBoardCardID, in column: String, color: Color) -> some View {
        if dropTarget == .init(column: column, before: card), dragging != card, dragging?.isSameKind(as: card) == true {
            line(color)
        }
    }

    private func line(_ color: Color) -> some View {
        Capsule()
            .fill(color == Color(nsColor: .secondaryLabelColor) ? Color.accentColor : color)
            .frame(height: 2)
    }

    /// A card dropped on a card of its own kind goes before it. A session dropped on a
    /// work item is linked to it, and a work item dropped on a session links the
    /// session to it. Together, a linked session dragged anywhere else leaves its item.
    private func dropDelegate(_ target: SessionBoardDropTarget) -> SessionBoardDropDelegate {
        SessionBoardDropDelegate(target: target, dragging: $dragging, dropTarget: $dropTarget) { moved, target in
            switch (moved, target.before) {
            case (.session(let id), .item(let item)?):
                window(of: id)?.workItemID = item
            case (.item(let item), .session(let id)?):
                window(of: id)?.workItemID = item
            case (.session(let id), _):
                if settings.mode == .together { window(of: id)?.workItemID = nil }
                model.moveOnBoard(id, to: target.column, before: target.before?.session)
            case (.item(let id), _):
                store.move(id, to: target.column, before: target.before?.item, settings: settings)
            }
        }
    }

    private func window(of id: ObjectIdentifier) -> TerminalWindow? {
        tabs.first { $0.id == id }?.window
    }

    /// Whether the card would be linked to what is dragged over it.
    private func isLinkTarget(_ card: SessionBoardCardID, in column: String) -> Bool {
        guard let dragging, dropTarget == .init(column: column, before: card) else { return false }
        return !dragging.isSameKind(as: card)
    }

    // MARK: Cards

    private func sessionCard(_ tab: TabSidebarModel.Tab, column: String) -> some View {
        draggable(SessionBoardCard(
            model: model, tab: tab, isLinkTarget: isLinkTarget(.session(tab.id), in: column), open: { open(tab) }),
            as: .session(tab.id))
            .onDrop(of: [.plainText], delegate: dropDelegate(.init(column: column, before: .session(tab.id))))
    }

    /// A session under its work item: the same card as on its own, dragged out to
    /// leave the item. Dropped on, it is the item that takes the drop.
    private func nestedSessionCard(_ tab: TabSidebarModel.Tab) -> some View {
        draggable(SessionBoardCard(model: model, tab: tab, open: { open(tab) }), as: .session(tab.id))
    }

    private func draggable<Card: View>(_ card: Card, as id: SessionBoardCardID) -> some View {
        card
            .opacity(dragging == id ? 0.4 : 1)
            .onDrag {
                TabSidebarHoverCard.shared.hideNow()
                dragging = id
                return NSItemProvider(object: SessionBoardDropTarget.dragText as NSString)
            }
    }

    private func itemCard(_ item: WorkItem, sessions: [TabSidebarModel.Tab], column: String) -> some View {
        let nested = settings.mode == .together ? sessions : []
        return WorkItemCard(
            item: item,
            hasSessions: !nested.isEmpty,
            linkedCount: content(of: item.id),
            isLinkTarget: isLinkTarget(.item(item.id), in: column),
            model: model,
            isRenaming: renaming == item.id,
            renameDraft: $renameDraft,
            renameFocus: $focus,
            renameField: Field.rename,
            openNotes: { openNotes(item) },
            beginRename: { beginRename(item) },
            commitRename: commitRename,
            sessions: {
                ForEach(nested) { tab in nestedSessionCard(tab) }
            })
            .opacity(dragging == .item(item.id) ? 0.4 : 1)
            .onDrag {
                TabSidebarHoverCard.shared.hideNow()
                dragging = .item(item.id)
                return NSItemProvider(object: SessionBoardDropTarget.dragText as NSString)
            }
            .onDrop(of: [.plainText], delegate: dropDelegate(.init(column: column, before: .item(item.id))))
    }

    /// How many sessions of this window are linked to the item.
    private func content(of id: UUID) -> Int {
        tabs.filter { $0.workItemID == id }.count
    }

    @ViewBuilder
    private func addCard(in column: String) -> some View {
        if addingIn == column {
            TextField("Card title", text: $newTitle, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...4)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6)))
                .focused($focus, equals: .newCard)
                .onSubmit { addCard(to: column) }
                .onChange(of: focus) { field in
                    // Clicking away ends adding, keeping what was typed as a card.
                    if field != .newCard, addingIn == column { addCard(to: column, keepsAdding: false) }
                }
        } else {
            Button {
                newTitle = ""
                addingIn = column
                DispatchQueue.main.async { focus = .newCard }
            } label: {
                Label("Add a card", systemImage: "plus")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }

    /// Adds what was typed as a card, and keeps the field for the next one, as Return
    /// does on a kanban board.
    private func addCard(to column: String, keepsAdding: Bool = true) {
        let title = newTitle
        newTitle = ""
        store.add(title, to: column)
        if keepsAdding {
            DispatchQueue.main.async { focus = .newCard }
        } else {
            addingIn = nil
        }
    }

    private func beginRename(_ item: WorkItem) {
        renameDraft = item.title
        renaming = item.id
        DispatchQueue.main.async { focus = .rename }
    }

    private func commitRename() {
        if let renaming { store.rename(renaming, to: renameDraft) }
        renaming = nil
    }

    private func openNotes(_ item: WorkItem) {
        guard let window = model.window else { return }
        window.documentPaneModel.show(store.preparedNotes(of: item), title: item.title)
        window.documentPaneModel.isEditing = true
    }

    // MARK: Search and Filters

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var words: [Substring] { query.lowercased().split(separator: " ") }

    /// A session by the filters, and by what its card shows, so a card never hides for
    /// something not on it.
    private func matches(_ tab: TabSidebarModel.Tab) -> Bool {
        guard model.boardFilter.shows(folder: tab.folderID, group: tab.groupID, color: tab.fillColor) else { return false }
        guard !words.isEmpty else { return true }
        let info = model.infos[tab.id]
        let text = [tab.title, SessionBoardCard.folderName(tab), info?.branch, info?.model]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return words.allSatisfy { text.contains($0) }
    }

    /// An item by its color, and by its title or a session shown under it.
    private func matches(_ item: WorkItem, sessions: [TabSidebarModel.Tab]) -> Bool {
        guard model.boardFilter.colors.isEmpty || model.boardFilter.colors.contains(item.color) else { return false }
        guard !words.isEmpty else { return true }
        let title = item.title.lowercased()
        if words.allSatisfy({ title.contains($0) }) { return true }
        return settings.mode == .together && sessions.contains { isSearching && matches($0) }
    }

    // MARK: Actions

    private func open(_ tab: TabSidebarModel.Tab) {
        guard let window = tab.window else { return }
        close()
        model.select(window)
    }

    private func close() {
        model.isBoardOpen = false
    }

    /// Esc ends adding or renaming a card, then clears the search, then closes the board.
    /// The editing keys go straight to the board's text field being typed in, so the
    /// terminal under the board never takes them.
    private func watchEscape() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model, model.isBoardOpen, event.window === model.window else { return event }
            if let action = SessionBoardEditing.action(for: event),
               let editor = event.window?.firstResponder as? NSTextView,
               NSApp.sendAction(action, to: editor, from: nil) {
                return nil
            }
            guard event.keyCode == 53 else { return event }
            if addingIn != nil {
                newTitle = ""
                addingIn = nil
            } else if renaming != nil {
                renaming = nil
            } else if focus == .search, !query.isEmpty {
                query = ""
            } else {
                model.isBoardOpen = false
            }
            return nil
        }
    }

    private func stopWatchingEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }
}

/// The standard editing keys, for the board's text fields.
enum SessionBoardEditing {
    /// What ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z and ⇧⌘Z do in a text field, or nil for another key.
    static func action(for event: NSEvent) -> Selector? {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch (modifiers, event.charactersIgnoringModifiers?.lowercased()) {
        case ([.command], "x"): return #selector(NSText.cut(_:))
        case ([.command], "c"): return #selector(NSText.copy(_:))
        case ([.command], "v"): return #selector(NSText.paste(_:))
        case ([.command], "a"): return #selector(NSText.selectAll(_:))
        case ([.command], "z"): return Selector(("undo:"))
        case ([.command, .shift], "z"): return Selector(("redo:"))
        default: return nil
        }
    }
}

/// A card on the board: a session's, or a work item's.
enum SessionBoardCardID: Hashable {
    case session(ObjectIdentifier)
    case item(UUID)

    var session: ObjectIdentifier? {
        if case .session(let id) = self { return id }
        return nil
    }

    var item: UUID? {
        if case .item(let id) = self { return id }
        return nil
    }

    /// Items go among items, sessions among sessions.
    func isSameKind(as other: Self) -> Bool {
        (session != nil) == (other.session != nil)
    }
}

/// What each column holds in the board's mode, apart from the views so it can be tested.
struct SessionBoardContent {
    let mode: SessionBoardMode
    let tabs: [TabSidebarModel.Tab]
    let items: [WorkItem]
    let settings: SessionBoardSettings
    let sessionLanes: [String: [ObjectIdentifier]]

    private var itemIDs: Set<UUID> { Set(items.map(\.id)) }

    /// The work items in `column`, in order. None in the sessions view.
    func items(in column: String) -> [WorkItem] {
        guard mode != .sessions else { return [] }
        return items
            .filter { settings.column(for: $0.column) == column }
            .sorted { ($0.order, $0.createdAt) < ($1.order, $1.createdAt) }
    }

    /// The sessions shown as cards of their own in `column`: all of them in the sessions
    /// view, none in the work items view, and those linked to no item when together.
    func sessions(in column: String) -> [TabSidebarModel.Tab] {
        let byID = Dictionary(tabs.map { ($0.id, $0) }) { first, _ in first }
        let lane = (sessionLanes[column] ?? []).compactMap { byID[$0] }
        switch mode {
        case .sessions: return lane
        case .workItems: return []
        case .together: return lane.filter { tab in tab.workItemID.map { !itemIDs.contains($0) } ?? true }
        }
    }

    /// The sessions linked to the item, in sidebar order.
    func sessions(of item: UUID) -> [TabSidebarModel.Tab] {
        tabs.filter { $0.workItemID == item }
    }
}

/// Where a dragged card would land: in `column`, before the card `before`, or at the end.
struct SessionBoardDropTarget: Equatable {
    let column: String
    let before: SessionBoardCardID?

    /// What a dragged card carries. The card itself is known from the drag's start.
    static let dragText = "maggie-session-board-card"
}

private struct SessionBoardDropDelegate: DropDelegate {
    let target: SessionBoardDropTarget
    @Binding var dragging: SessionBoardCardID?
    @Binding var dropTarget: SessionBoardDropTarget?
    let perform: (SessionBoardCardID, SessionBoardDropTarget) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        dropTarget = target
    }

    func dropExited(info: DropInfo) {
        if dropTarget == target { dropTarget = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer {
            dragging = nil
            dropTarget = nil
        }
        guard let moved = dragging else { return false }
        guard target.before != moved else { return true }
        perform(moved, target)
        return true
    }
}

// MARK: - Work Item Card

/// A work item on the board: its title, with its sessions' cards under it when the
/// board shows them together, or how many it has. Clicking it opens its notes beside
/// the board; double-clicking renames it. A session dropped on it is linked to it.
private struct WorkItemCard<Field: Hashable, Sessions: View>: View {
    let item: WorkItem
    let hasSessions: Bool
    let linkedCount: Int
    let isLinkTarget: Bool
    @ObservedObject var model: TabSidebarModel
    let isRenaming: Bool
    @Binding var renameDraft: String
    var renameFocus: FocusState<Field?>.Binding
    let renameField: Field
    let openNotes: () -> Void
    let beginRename: () -> Void
    let commitRename: () -> Void
    @ViewBuilder let sessions: () -> Sessions

    @ObservedObject private var settings = SessionBoardSettings.shared
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 6) {
                if isRenaming {
                    TextField("Card title", text: $renameDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused(renameFocus, equals: renameField)
                        .onSubmit(commitRename)
                } else {
                    Text(item.title)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isHovering && !isRenaming {
                    Button(action: openNotes) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 10))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Open Notes")
                } else if !hasSessions, linkedCount > 0 {
                    Label("\(linkedCount)", systemImage: "apple.terminal")
                        .labelStyle(SessionBoardCompactLabel())
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help(linkedCount == 1 ? "1 session linked" : "\(linkedCount) sessions linked")
                }
            }
            .font(.system(size: 13, weight: .medium))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: beginRename)
            .onTapGesture(perform: openNotes)

            if let label = settings.label(of: item.color), let color = item.color.displayColor {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 7, height: 7)
                    Text(label)
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
                .help("\(item.color.localizedName): \(label)")
            }

            if hasSessions {
                VStack(spacing: 6) {
                    sessions()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isLinkTarget ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: isLinkTarget ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .help(isLinkTarget ? "Drop to link the session to \(item.title)" : item.title)
        .contextMenu { menu }
    }

    /// A card given a color is filled with it as a session row given one is; one
    /// without keeps a card's faint fill.
    private var fill: Color {
        if isLinkTarget { return Color.accentColor.opacity(0.14) }
        guard let color = item.color.displayColor else { return Color.primary.opacity(isHovering ? 0.1 : 0.065) }
        return Color(nsColor: color).opacity(isHovering ? 0.55 : 0.4)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Open Notes", action: openNotes)
        Button("Rename…", action: beginRename)
        TabSidebarColorMenu(
            title: "Card Color", choices: WorkItem.colorChoices, selected: item.color,
            name: settings.name(of:)
        ) { color in
            WorkItemStore.shared.setColor(color, of: item.id)
        }
        Menu("Move to Status") {
            ForEach(settings.columns) { column in
                Toggle(isOn: Binding(
                    get: { settings.column(for: item.column) == column.id },
                    set: { _ in WorkItemStore.shared.move(item.id, to: column.id, before: nil, settings: settings) })) {
                    Label {
                        Text(column.label)
                    } icon: {
                        if let image = column.menuImage { Image(nsImage: image) }
                    }
                }
            }
        }
        let tabs = model.boardTabs
        if !tabs.isEmpty {
            Menu("Link Sessions") {
                ForEach(tabs) { tab in
                    Toggle(tab.title, isOn: Binding(
                        get: { tab.workItemID == item.id },
                        set: { linked in tab.window?.workItemID = linked ? item.id : nil }))
                }
            }
        }
        Divider()
        Button("Delete Card") { WorkItemStore.shared.delete(item.id) }
    }
}

// MARK: - Card

/// A session on the board: what it is doing, its title, its folder and branch, and the
/// model it runs. It takes the session's color as its sidebar row does, shows the
/// row's card on hover and the row's menu on a right click, and closes from its ✕.
private struct SessionBoardCard: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab

    /// A work item is dragged over it, to be linked to it.
    var isLinkTarget = false
    let open: () -> Void

    @State private var isHovering = false

    /// Where the card is in the window, for the hover card to show beside it.
    @State private var frame: CGRect = .zero

    private var info: TabSidebarSessionInfo? { model.infos[tab.id] }
    private var colors: TabSidebarRowColors { TabSidebarRowColors(tab: tab) }

    static func folderName(_ tab: TabSidebarModel.Tab) -> String? {
        UserTabFolderStore.shared[tab.folderID]?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                light
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if isHovering {
                    Button {
                        TabSidebarHoverCard.shared.hide(tab.id)
                        tab.window.map(model.close)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Close Session")
                } else {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        if let time = time(at: context.date) {
                            Text(time)
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .opacity(0.6)
                        }
                    }
                }
            }

            if Self.folderName(tab) != nil || info?.branch != nil || info?.model != nil {
                HStack(spacing: 6) {
                    if let folder = Self.folderName(tab) {
                        Text(folder)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    }
                    if let branch = info?.branch {
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .labelStyle(SessionBoardCompactLabel())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    if let model = info?.model {
                        Text(TabSidebarHoverCardView.shortName(model))
                            .lineLimit(1)
                            .opacity(0.6)
                    }
                }
                .font(.system(size: 11))
                .opacity(0.8)
                .padding(.leading, 18)
            }
        }
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(cardBackground))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isLinkTarget ? Color.accentColor : outline, lineWidth: isLinkTarget ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { frame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { frame = $0 }
        })
        .onHover { inside in
            isHovering = inside
            if inside { showHoverCard() } else { TabSidebarHoverCard.shared.hide(tab.id) }
        }
        .onDisappear { TabSidebarHoverCard.shared.hide(tab.id) }
        .onTapGesture {
            TabSidebarHoverCard.shared.hide(tab.id)
            open()
        }
        .contextMenu { TabSidebarSessionMenu(model: model, tab: tab) }
    }

    /// The row's fill; a session with no color keeps a card's faint one.
    private var cardBackground: Color {
        if case .none = colors.fill {
            return Color.primary.opacity(tab.isSelected ? 0.12 : (isHovering ? 0.09 : 0.05))
        }
        return colors.background(isHovering: isHovering)
    }

    private var outline: Color {
        if tab.isSelected { return colors.outline ?? Color.accentColor.opacity(0.7) }
        return Color.primary.opacity(0.06)
    }

    private func showHoverCard() {
        let tab = tab
        let info = info
        let tint = colors.symbolTint
        TabSidebarHoverCard.shared.show(
            tab.id, from: model.window, sidebarWidth: TabSidebarSettings.shared.width,
            leadingX: frame.maxX + 8
        ) {
            TabSidebarHoverCardView(tab: tab, info: info, tint: tint)
        }
    }

    @ViewBuilder
    private var light: some View {
        if let light = tab.claudeCodeState?.light {
            Image(systemName: light.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(colors.symbolTint ?? Color(nsColor: light.tabColor.displayColor ?? .secondaryLabelColor))
                .frame(width: 12)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 6, height: 6)
                .frame(width: 12)
        }
    }

    private func time(at now: Date) -> String? {
        let activity = tab.claudeCodeActivity
        if tab.claudeCodeState?.light == .working, let since = activity.workingSince {
            return ClaudeCodeActivity.elapsed(since: since, at: now)
        }
        return (activity.stoppedSince ?? info?.lastActive).map { ClaudeCodeActivity.ago($0, at: now) }
    }
}

private struct SessionBoardCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 9))
            configuration.title
        }
    }
}

// MARK: - Filters

/// The board's filters, on the header's line next to the search: a menu each for
/// folders, groups, status and color, offering only what some session has, and a ✕
/// that clears them all. The sidebar shares them, in a menu of its own.
private struct SessionBoardFilterBar: View {
    @ObservedObject var model: TabSidebarModel
    let tabs: [TabSidebarModel.Tab]
    let items: [WorkItem]
    let mode: SessionBoardMode

    @ObservedObject private var board = SessionBoardSettings.shared

    var body: some View {
        let options = SessionBoardFilterOptions(model: model, tabs: tabs, items: items, mode: mode, board: board)
        HStack(spacing: 6) {
            SessionBoardFilterMenu(
                title: "Folder", plural: "Folders",
                options: options.folders,
                selection: $model.boardFilter.folders)

            SessionBoardFilterMenu(
                title: "Group", plural: "Groups",
                options: options.groups,
                selection: $model.boardFilter.groups)

            SessionBoardFilterMenu(
                title: "Status", plural: "Statuses",
                options: options.columns,
                selection: $model.boardFilter.columns)

            SessionBoardFilterMenu(
                title: "Color", plural: "Colors",
                options: options.colors,
                selection: $model.boardFilter.colors)

            if model.boardFilter.isActive {
                Button {
                    model.boardFilter = SessionBoardFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(width: 18, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear Filters")
            }
        }
    }
}

/// One filter: a pill that names what it picks, opening a menu of choices that each
/// toggle. With nothing to choose between, it is left out.
private struct SessionBoardFilterMenu<Value: Hashable>: View {
    let title: String
    let plural: String
    let options: [SessionBoardFilterOption<Value>]
    @Binding var selection: Set<Value>

    var body: some View {
        if !options.isEmpty {
            Menu {
                SessionBoardFilterToggles(options: options, selection: $selection)
            } label: {
                HStack(spacing: 4) {
                    Text(label)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 12, weight: selection.isEmpty ? .regular : .medium))
                .foregroundStyle(selection.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.accentColor))
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selection.isEmpty ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.15)))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(selection.isEmpty ? "Filter by \(title)" : "Showing \(label)")
        }
    }

    /// `Folder`, the one picked, or how many.
    private var label: String {
        SessionBoardFilterOptions.label(title, plural: plural, options: options, selection: selection)
    }
}

// MARK: - Columns

/// Renames, recolors, reorders, adds and removes the board's columns. A removed
/// column's sessions move to the column before it.
private struct SessionBoardColumnsEditor: View {
    @ObservedObject var settings: SessionBoardSettings

    @State private var pickingIconFor: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Columns")
                .font(.system(size: 13, weight: .semibold))

            ForEach(Array(settings.columns.enumerated()), id: \.element.id) { index, column in
                HStack(spacing: 6) {
                    Button {
                        pickingIconFor = column.id
                    } label: {
                        Image(systemName: column.icon)
                            .foregroundStyle(Color(nsColor: column.displayColor))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .help("Icon")
                    .popover(isPresented: Binding(
                        get: { pickingIconFor == column.id },
                        set: { if !$0 { pickingIconFor = nil } })) {
                        SessionBoardIconPicker(selected: column.icon, color: Color(nsColor: column.displayColor)) { icon in
                            settings.update(column.id) { $0.icon = icon }
                            pickingIconFor = nil
                        }
                    }

                    TextField("Name", text: Binding(
                        get: { column.label },
                        set: { label in settings.update(column.id) { $0.label = label } }))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)

                    Menu {
                        ForEach(SessionBoardSettings.colors, id: \.self) { color in
                            Button { settings.update(column.id) { $0.color = color } } label: {
                                Label {
                                    Text(color == column.color ? "\(color.localizedName) ✓" : color.localizedName)
                                } icon: {
                                    Image(nsImage: color.swatchImage(selected: false))
                                }
                            }
                        }
                    } label: {
                        Circle()
                            .fill(Color(nsColor: column.displayColor))
                            .frame(width: 12, height: 12)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Color")

                    Button { settings.moveColumn(column.id, by: -1) } label: { Image(systemName: "chevron.left") }
                        .disabled(index == 0)
                        .help("Move \(column.label) Left")
                    Button { settings.moveColumn(column.id, by: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(index == settings.columns.count - 1)
                        .help("Move \(column.label) Right")
                    Button {
                        if let target = settings.removeColumn(column.id) {
                            TerminalWindow.moveBoardSessions(from: column.id, to: target)
                            WorkItemStore.shared.moveItems(from: column.id, to: target)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(settings.columns.count <= 1)
                    .help("Remove \(column.label); its work items and sessions move to the column before it")
                }
                .buttonStyle(.borderless)
            }

            Divider()

            HStack {
                Button("Add Column") { settings.addColumn() }
                Spacer()
                Button("Reset") { settings.columns = SessionBoardSettings.defaultColumns }
                    .help("Go back to Todo, In progress, In review and Done")
            }
            .buttonStyle(.borderless)

            Divider()

            Text("Colors")
                .font(.system(size: 13, weight: .semibold))
            Text("Name what a color means, such as Urgent. Cards show it, and the menus and the filter use it.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 6) {
                ForEach(WorkItem.colorChoices.filter { $0.displayColor != nil }, id: \.self) { color in
                    HStack(spacing: 6) {
                        Image(nsImage: color.swatchImage(selected: false))
                        TextField(color.localizedName, text: Binding(
                            get: { settings.typedLabel(of: color) },
                            set: { settings.setLabel($0, of: color) }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .padding(14)
        .frame(width: 400)
    }
}

/// A grid of the symbols a column can be given.
private struct SessionBoardIconPicker: View {
    let selected: String
    let color: Color
    let pick: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 4), count: 5), spacing: 4) {
            ForEach(SessionBoardSettings.icons, id: \.self) { icon in
                Button {
                    pick(icon)
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(icon == selected ? Color.white : color)
                        .frame(width: 30, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(icon == selected ? Color.accentColor : Color.primary.opacity(0.05)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(icon)
            }
        }
        .padding(10)
    }
}

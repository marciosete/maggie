import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The session board: the sessions of a window's sidebar as cards in columns such as
/// Todo, In progress, In review and Done. It covers the terminal, beside the sidebar,
/// and ⌘K shows or hides it. Dragging a card moves the session to another column or
/// another place in its own; nothing else moves it. Clicking a card goes to the session
/// and closes the board.
struct SessionBoardView: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = SessionBoardSettings.shared

    @State private var query = ""
    @State private var dragging: ObjectIdentifier?
    @State private var dropTarget: SessionBoardDropTarget?
    @State private var isEditingColumns = false
    @State private var escapeMonitor: Any?
    @FocusState private var searchFocused: Bool

    static let columnWidth: CGFloat = 280

    private var tabs: [TabSidebarModel.Tab] { model.boardTabs }

    private var lanes: [String: [ObjectIdentifier]] { model.boardLanes() }

    var body: some View {
        let tabsByID = Dictionary(tabs.map { ($0.id, $0) }) { first, _ in first }
        let lanes = lanes
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(settings.columns) { column in
                        lane(column, tabs: (lanes[column.id] ?? []).compactMap { tabsByID[$0] }, lanes: lanes)
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
            Text("Session Board")
                .font(.system(size: 14, weight: .semibold))

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search sessions", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .frame(width: 220, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

            SessionBoardFilterBar(model: model, tabs: tabs)

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

    private func lane(_ column: SessionBoardColumn, tabs: [TabSidebarModel.Tab], lanes: [String: [ObjectIdentifier]]) -> some View {
        let color = Color(nsColor: column.displayColor)
        // Every column stays; filtered by status, only the picked ones keep their cards.
        let shown = model.boardFilter.shows(column: column.id) ? tabs.filter(matches) : []
        let isNarrowed = isSearching || model.boardFilter.isActive
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: column.icon)
                    .foregroundStyle(color)
                Text(column.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isNarrowed ? "\(shown.count) / \(tabs.count)" : "\(tabs.count)")
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
                    ForEach(shown) { tab in
                        if dropTarget == .init(column: column.id, before: tab.id), dragging != tab.id {
                            insertionLine(color)
                        }
                        SessionBoardCard(model: model, tab: tab, open: { open(tab) })
                            .opacity(dragging == tab.id ? 0.4 : 1)
                            .onDrag {
                                TabSidebarHoverCard.shared.hideNow()
                                dragging = tab.id
                                return NSItemProvider(object: SessionBoardDropTarget.dragText as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: SessionBoardDropDelegate(
                                target: .init(column: column.id, before: tab.id),
                                dragging: $dragging, dropTarget: $dropTarget) { moved, target in
                                    move(moved, to: target.column, before: target.before)
                                })
                    }
                    if dropTarget == .init(column: column.id, before: nil) {
                        insertionLine(color)
                    }
                    if shown.isEmpty {
                        Text(isNarrowed && !tabs.isEmpty ? "No matches" : "Empty")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 56)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .foregroundStyle(Color.primary.opacity(0.15)))
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
        .onDrop(of: [.plainText], delegate: SessionBoardDropDelegate(
            target: .init(column: column.id, before: nil),
            dragging: $dragging, dropTarget: $dropTarget) { moved, target in
                move(moved, to: target.column, before: target.before)
            })
    }

    private func insertionLine(_ color: Color) -> some View {
        Capsule()
            .fill(color == Color(nsColor: .secondaryLabelColor) ? Color.accentColor : color)
            .frame(height: 2)
    }

    // MARK: Search and Filters

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// By the filters, and by what the card shows, so a card never hides for
    /// something not on it.
    private func matches(_ tab: TabSidebarModel.Tab) -> Bool {
        guard model.boardFilter.shows(folder: tab.folderID, group: tab.groupID, color: tab.color) else { return false }
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let info = model.infos[tab.id]
        let text = [tab.title, SessionBoardCard.folderName(tab), info?.branch, info?.model]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return words.allSatisfy { text.contains($0) }
    }

    // MARK: Actions

    private func move(_ moved: ObjectIdentifier, to column: String, before: ObjectIdentifier?) {
        model.moveOnBoard(moved, to: column, before: before)
    }

    private func open(_ tab: TabSidebarModel.Tab) {
        guard let window = tab.window else { return }
        close()
        model.select(window)
    }

    private func close() {
        model.isBoardOpen = false
    }

    /// Esc closes the board, unless it clears the search first.
    private func watchEscape() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard event.keyCode == 53, let model, model.isBoardOpen,
                  event.window === model.window else { return event }
            if searchFocused, !query.isEmpty {
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

/// Where a dragged card would land: in `column`, before the card `before`, or at the end.
struct SessionBoardDropTarget: Equatable {
    let column: String
    let before: ObjectIdentifier?

    /// What a dragged card carries. The card itself is known from the drag's start.
    static let dragText = "maggie-session-board-card"
}

private struct SessionBoardDropDelegate: DropDelegate {
    let target: SessionBoardDropTarget
    @Binding var dragging: ObjectIdentifier?
    @Binding var dropTarget: SessionBoardDropTarget?
    let perform: (ObjectIdentifier, SessionBoardDropTarget) -> Void

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
        if target.before != moved { perform(moved, target) }
        return true
    }
}

// MARK: - Card

/// A session on the board: what it is doing, its title, its folder and branch, and the
/// model it runs. It takes the session's color as its sidebar row does, shows the
/// row's card on hover and the row's menu on a right click, and closes from its ✕.
private struct SessionBoardCard: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab
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
                .strokeBorder(outline, lineWidth: 1))
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
/// that clears them all.
private struct SessionBoardFilterBar: View {
    @ObservedObject var model: TabSidebarModel
    let tabs: [TabSidebarModel.Tab]

    @ObservedObject private var board = SessionBoardSettings.shared

    var body: some View {
        HStack(spacing: 6) {
            SessionBoardFilterMenu(
                title: "Folder", plural: "Folders",
                options: folderOptions,
                selection: $model.boardFilter.folders)

            SessionBoardFilterMenu(
                title: "Group", plural: "Groups",
                options: groupOptions,
                selection: $model.boardFilter.groups)

            SessionBoardFilterMenu(
                title: "Status", plural: "Statuses",
                options: board.columns.map { .init(value: $0.id, label: $0.label, image: $0.menuImage) },
                selection: $model.boardFilter.columns)

            SessionBoardFilterMenu(
                title: "Color", plural: "Colors",
                options: TerminalTabColor.allCases
                    .filter { color in tabs.contains { $0.color == color } }
                    .map { .init(value: $0, label: $0.localizedName, image: $0.swatchImage(selected: false)) },
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

    /// Every folder open in the sidebar, as it lists them, even one with no sessions,
    /// and any other folder a session is in; then the sessions in none.
    private var folderOptions: [SessionBoardFilterMenu<UUID?>.Option] {
        let folderImage = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        var folders = model.foldersInWindow
        for tab in tabs {
            guard let id = tab.folderID, !folders.contains(where: { $0.id == id }),
                  let folder = UserTabFolderStore.shared[id] else { continue }
            folders.append(folder)
        }
        var options: [SessionBoardFilterMenu<UUID?>.Option] = folders.map {
            .init(value: $0.id, label: $0.name, image: folderImage)
        }
        if tabs.contains(where: { $0.folderID == nil }), !options.isEmpty {
            options.append(.init(value: nil, label: "No Folder", image: NSImage(systemSymbolName: "tray", accessibilityDescription: nil)))
        }
        return options
    }

    /// The groups the sessions are in, in sidebar order, then the sessions in none.
    private var groupOptions: [SessionBoardFilterMenu<UUID?>.Option] {
        var seen = Set<UUID?>()
        var options: [SessionBoardFilterMenu<UUID?>.Option] = []
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
}

/// One filter: a pill that names what it picks, opening a menu of choices that each
/// toggle. With nothing to choose between, it is left out.
private struct SessionBoardFilterMenu<Value: Hashable>: View {
    struct Option {
        let value: Value
        let label: String
        let image: NSImage?
    }

    let title: String
    let plural: String
    let options: [Option]
    @Binding var selection: Set<Value>

    var body: some View {
        if !options.isEmpty {
            Menu {
                ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                    Toggle(isOn: Binding(
                        get: { selection.contains(option.value) },
                        set: { _ in SessionBoardFilter.toggle(option.value, in: &selection) })) {
                        Label {
                            Text(option.label)
                        } icon: {
                            if let image = option.image { Image(nsImage: image) }
                        }
                    }
                }
                if !selection.isEmpty {
                    Divider()
                    Button("Show All") { selection = [] }
                }
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
        let picked = options.filter { selection.contains($0.value) }
        switch picked.count {
        case 0: return title
        case 1: return picked[0].label
        default: return "\(picked.count) \(plural)"
        }
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
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(settings.columns.count <= 1)
                    .help("Remove \(column.label); its sessions move to the column before it")
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

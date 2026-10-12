import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The session board: the sessions of a window's sidebar as cards in columns such as
/// Todo, In progress, In review and Done. It covers the terminal, beside the sidebar.
/// Dragging a card moves the session to another column or another place in its own;
/// nothing else moves it. Clicking a card goes to the session and closes the board.
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
        .onDisappear(perform: stopWatchingEscape)
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
            .frame(width: 260, height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))

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
            .help("Close the Board (Esc)")
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
        let shown = tabs.filter(matches)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: column.icon)
                    .foregroundStyle(color)
                Text(column.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(isSearching ? "\(shown.count) / \(tabs.count)" : "\(tabs.count)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                Spacer()
                Button {
                    newSession(in: column.id, lanes: lanes)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Session in \(column.label)")
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
                        SessionBoardCard(
                            tab: tab,
                            info: model.infos[tab.id],
                            columns: settings.columns,
                            open: { open(tab) },
                            moveTo: { move(tab.id, to: $0, before: nil, lanes: lanes) },
                            close: { tab.window.map(model.close) })
                            .opacity(dragging == tab.id ? 0.4 : 1)
                            .onDrag {
                                dragging = tab.id
                                return NSItemProvider(object: SessionBoardDropTarget.dragText as NSString)
                            }
                            .onDrop(of: [.plainText], delegate: SessionBoardDropDelegate(
                                target: .init(column: column.id, before: tab.id),
                                dragging: $dragging, dropTarget: $dropTarget) { moved, target in
                                    move(moved, to: target.column, before: target.before, lanes: lanes)
                                })
                    }
                    if dropTarget == .init(column: column.id, before: nil) {
                        insertionLine(color)
                    }
                    if shown.isEmpty {
                        Text(isSearching && !tabs.isEmpty ? "No matches" : "Empty")
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
                move(moved, to: target.column, before: target.before, lanes: lanes)
            })
    }

    private func insertionLine(_ color: Color) -> some View {
        Capsule()
            .fill(color == Color(nsColor: .secondaryLabelColor) ? Color.accentColor : color)
            .frame(height: 2)
    }

    // MARK: Search

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Only by what the card shows, so a card never hides for something not on it.
    private func matches(_ tab: TabSidebarModel.Tab) -> Bool {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return true }
        let info = model.infos[tab.id]
        let text = [tab.title, SessionBoardCard.folderName(tab), info?.branch, info?.model]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        return words.allSatisfy { text.contains($0) }
    }

    // MARK: Actions

    private func move(_ moved: ObjectIdentifier, to column: String, before: ObjectIdentifier?, lanes: [String: [ObjectIdentifier]]) {
        model.moveOnBoard(moved, to: column, before: before)
    }

    private func open(_ tab: TabSidebarModel.Tab) {
        guard let window = tab.window else { return }
        close()
        model.select(window)
    }

    private func newSession(in column: String, lanes: [String: [ObjectIdentifier]]) {
        close()
        guard let window = model.newTab() else { return }
        window.boardPlace = SessionBoardPlace(column: column, order: Double(lanes[column]?.count ?? 0))
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
/// model it runs.
private struct SessionBoardCard: View {
    let tab: TabSidebarModel.Tab
    let info: TabSidebarSessionInfo?
    let columns: [SessionBoardColumn]
    let open: () -> Void
    let moveTo: (String) -> Void
    let close: () -> Void

    @State private var isHovering = false

    static func folderName(_ tab: TabSidebarModel.Tab) -> String? {
        UserTabFolderStore.shared[tab.folderID]?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                light
                Text(tab.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    if let time = time(at: context.date) {
                        Text(time)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
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
                        Text(model)
                            .lineLimit(1)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(isHovering ? 0.09 : 0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tab.isSelected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: open)
        .help("Click to go to \(tab.title)")
        .contextMenu {
            Button("Go to Session", action: open)
            Menu("Move to") {
                ForEach(columns) { column in
                    Button(column.label) { moveTo(column.id) }
                        .disabled(column.id == SessionBoardSettings.shared.column(for: tab.boardPlace?.column))
                }
            }
            Divider()
            Button("Close Session", action: close)
        }
    }

    @ViewBuilder
    private var light: some View {
        if let light = tab.claudeCodeState?.light {
            Image(systemName: light.symbolName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: light.tabColor.displayColor ?? .secondaryLabelColor))
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

// MARK: - Columns

/// Renames, recolors, reorders, adds and removes the board's columns. A removed
/// column's sessions move to the column before it.
private struct SessionBoardColumnsEditor: View {
    @ObservedObject var settings: SessionBoardSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Columns")
                .font(.system(size: 13, weight: .semibold))

            ForEach(Array(settings.columns.enumerated()), id: \.element.id) { index, column in
                HStack(spacing: 6) {
                    Menu {
                        ForEach(SessionBoardSettings.icons, id: \.self) { icon in
                            Button { settings.update(column.id) { $0.icon = icon } } label: {
                                Label(icon, systemImage: icon)
                            }
                        }
                    } label: {
                        Image(systemName: column.icon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(Color(nsColor: column.displayColor))
                    .help("Icon")

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

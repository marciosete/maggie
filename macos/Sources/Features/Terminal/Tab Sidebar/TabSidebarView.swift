import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Lays out the tab sidebar next to the terminal content of a window.
///
/// When the sidebar is active the window uses a full size content view with a transparent
/// titlebar so the sidebar can run the full height of the window, behind the traffic
/// lights. The terminal content stays below the titlebar, and the titlebar area above it
/// is painted with the terminal background color so it looks like a normal titlebar.
struct TabSidebarContainerView<Content: View>: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = TabSidebarSettings.shared
    let sourceControl: SourceControlPanelModel
    @ObservedObject var sourceControlSettings = SourceControlSettings.shared
    @ObservedObject var usageSettings = UsageSettings.shared
    @ObservedObject var documentPane: DocumentPaneModel
    @ObservedObject var documentPaneSettings = DocumentPaneSettings.shared
    @ObservedObject var statusBar = StatusBarSettings.shared
    let content: Content

    init(
        model: TabSidebarModel,
        sourceControl: SourceControlPanelModel,
        documentPane: DocumentPaneModel,
        @ViewBuilder content: () -> Content
    ) {
        self.model = model
        self.sourceControl = sourceControl
        self.documentPane = documentPane
        self.content = content()
    }

    // The panes keep their place whether the status bar shows or not, so showing it
    // doesn't make the terminal again.
    var body: some View {
        VStack(spacing: 0) {
            panes
            if statusBar.isVisible {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                StatusBarView()
                    .background(statusBarBackground)
            }
        }
        .ignoresSafeArea(.container, edges: model.isActive ? .top : [])
    }

    /// The terminal's background where it has one, so the bar reads as the window's
    /// edge; the sidebar's material otherwise.
    @ViewBuilder
    private var statusBarBackground: some View {
        if let color = model.titlebarColor {
            Color(nsColor: color)
        } else {
            TabSidebarVisualEffectBackground()
        }
    }

    @ViewBuilder
    private var panes: some View {
        if model.isActive {
            HStack(spacing: 0) {
                if !settings.isCollapsed {
                    TabSidebarView(model: model, topInset: model.titlebarHeight)
                        .frame(width: settings.width)

                    separator
                }

                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(nsColor: model.titlebarColor ?? .clear))
                        .frame(height: model.titlebarHeight)

                    content
                        // The board covers the terminal, beside the sidebar, and leaves
                        // it running underneath.
                        .overlay {
                            if model.isBoardOpen {
                                SessionBoardView(model: model)
                            }
                        }
                }

                rightPanels(topInset: model.titlebarHeight)
            }
            .ignoresSafeArea(.container, edges: .top)
        } else {
            HStack(spacing: 0) {
                content
                rightPanels(topInset: 0)
            }
        }
    }

    @ViewBuilder
    private func rightPanels(topInset: CGFloat) -> some View {
        if documentPane.isVisible {
            separator
            DocumentPaneView(model: documentPane, topInset: topInset)
                .frame(width: documentPaneSettings.width)
        }

        if sourceControlSettings.isVisible {
            separator
            SourceControlPanelView(model: sourceControl, topInset: topInset)
                .frame(width: sourceControlSettings.width)
        }

        if usageSettings.isVisible {
            separator
            UsagePanelView(topInset: topInset)
                .frame(width: usageSettings.width)
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
    }
}

// MARK: - Sidebar

struct TabSidebarView: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject var settings = TabSidebarSettings.shared
    @ObservedObject private var statusBar = StatusBarSettings.shared
    let topInset: CGFloat

    @State private var dropAtEnd = false
    @State private var resizeStartWidth: CGFloat?

    /// The sessions in their folders and groups.
    private var rows: some View {
        ForEach(model.shownRows) { row in
            switch row {
            case .tab(let tab):
                TabSidebarSession(model: model, tab: tab, group: nil, indent: 0)

            case .group(let section):
                TabSidebarGroupSection(model: model, section: section, indent: 0)

            case .folder(let section):
                TabSidebarFolderSection(model: model, section: section, indent: 0)

            case .folderGroup(let section):
                TabSidebarFolderGroupSection(model: model, section: section)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Leave room for the traffic lights and the titlebar.
            Color.clear.frame(height: max(topInset, 8))

            TabSidebarSearchField(model: model)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)

            TabSidebarLostSessionsBanner()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: TabSidebarStyle.rowSpacing(settings.rowStyle)) {
                        if model.isSearching && model.shownRows.isEmpty {
                            Text("No sessions match")
                                .font(TabSidebarStyle.titleFont)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 12)
                        }

                        if settings.groupBy == .status {
                            TabSidebarStatusSections(model: model)
                        } else {
                            rows
                        }

                        // Dropping below the last tab moves a tab to the end, outside any
                        // group or folder. A directory dropped from the Finder opens as a folder.
                        Color.clear
                            .frame(height: 32)
                            .overlay(alignment: .top) {
                                if dropAtEnd { TabSidebarDropIndicator() }
                            }
                            .onDrop(of: [.plainText, .fileURL], delegate: TabSidebarDropDelegate(
                                model: model,
                                target: .end,
                                height: 32,
                                placement: Binding(
                                    get: { dropAtEnd ? .before : nil },
                                    set: { dropAtEnd = $0 != nil })))
                            .onReceive(TabSidebarDragState.shared.$endedDrags.dropFirst()) { _ in dropAtEnd = false }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
                .onChange(of: model.revealRequest) { _ in
                    // After what was folded has unfolded, so the row is there to scroll to.
                    DispatchQueue.main.async {
                        guard let id = model.selectedTabID else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    model.newTab()
                } label: {
                    Label("New Session", systemImage: "plus")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Session")

                Button {
                    model.presentOpenFolderPanel()
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Folder…")

                Button {
                    model.revealSelected()
                } label: {
                    Image(systemName: "scope")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reveal Active Session")

                Button {
                    model.isBoardOpen.toggle()
                } label: {
                    Image(systemName: "rectangle.split.3x1")
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.isBoardOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .help(model.isBoardOpen ? "Hide Session Board" : "Show Session Board")

                if !statusBar.shows(.caffeine) {
                    CaffeineButton()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(TabSidebarVisualEffectBackground())
        .overlay(alignment: .trailing) { resizeHandle }
    }

    private var resizeHandle: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = resizeStartWidth ?? settings.width
                        resizeStartWidth = start
                        settings.width = TabSidebarSettings.clampWidth(start + value.translation.width)
                    }
                    .onEnded { _ in resizeStartWidth = nil }
            )
    }
}

// MARK: - Lost Sessions

/// Sessions whose processes ended together, as when they are killed from outside the app,
/// with the choice to reopen them where they were or let them go. They stay in the saved
/// workspace until one is picked, so nothing is lost by leaving it.
private struct TabSidebarLostSessionsBanner: View {
    @ObservedObject private var workspace = TerminalWorkspace.shared

    var body: some View {
        if let loss = workspace.pendingLoss {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(loss.count) sessions closed at once")
                        .font(TabSidebarStyle.titleFont.weight(.semibold))
                }
                Text("Their processes ended together, as when they are killed from outside. They stay saved until you choose.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Reopen") { workspace.reopenLostSessions() }
                        .buttonStyle(.borderedProminent)
                    Button("Keep Closed") { workspace.dismissLostSessions() }
                }
                .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }
}

// MARK: - Search

/// Finds sessions by title, group, project, branch or folder. The arrow keys move through
/// the matches, Return opens one, and Escape clears the search.
private struct TabSidebarSearchField: View {
    @ObservedObject var model: TabSidebarModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("Search", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(TabSidebarStyle.titleFont)
                .focused($focused)
                .onSubmit { model.openSearchHighlight() }
                .onExitCommand { model.endSearch() }
                .backport.onKeyPress(.downArrow) { _ in
                    model.moveSearchHighlight(by: 1)
                    return .handled
                }
                .backport.onKeyPress(.upArrow) { _ in
                    model.moveSearchHighlight(by: -1)
                    return .handled
                }

            if !model.searchQuery.isEmpty {
                Button {
                    model.endSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear Search")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(focused ? 0.1 : 0.06)))
        .help("Search Sessions (⇧⌘O)")
        .onChange(of: model.searchFocusRequest) { _ in focused = true }
    }
}

// MARK: - Folder Group

private struct TabSidebarFolderGroupSection: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var settings = TabSidebarSettings.shared
    let section: TabSidebarModel.FolderGroupSection

    var body: some View {
        VStack(alignment: .leading, spacing: TabSidebarStyle.rowSpacing(settings.rowStyle)) {
            TabSidebarFolderGroupHeader(model: model, section: section)

            if !section.group.isCollapsed {
                ForEach(section.folders) { folder in
                    TabSidebarFolderSection(model: model, section: folder, indent: TabSidebarStyle.indent)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct TabSidebarFolderGroupHeader: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarModel.FolderGroupSection

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    private var group: UserTabFolderGroup { section.group }
    private var isEditing: Bool { model.editingFolderGroupID == group.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Image(systemName: "rectangle.stack")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if isEditing {
                TextField("Folder Group Name", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .font(TabSidebarStyle.titleFont)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                Text(group.name)
                    .font(TabSidebarStyle.titleFont.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(Color.primary.opacity(0.85))
            }

            // The sessions in its folders, not the folders: empty ones count for nothing.
            if group.isCollapsed {
                Text("(\(section.tabs.count))")
                    .font(TabSidebarStyle.titleFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // A collapsed folder group still says what its sessions are doing.
            if group.isCollapsed && !(isHovering && !isEditing) {
                if section.hasFinishedUnseen {
                    TabSidebarUnseenDot()
                }
                if let light = section.claudeCodeLight, let color = light.tabColor.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                        .help(light.label)
                }
            }

            if isHovering && !isEditing {
                Button {
                    model.presentOpenFolderPanel(inFolderGroup: group.id)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open Folder in Group…")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: TabSidebarStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.toggleCollapsed(folderGroup: group.id) }
        }
        .overlay {
            // A folder dropped on the group joins it.
            if placement == .into {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay(alignment: placement == .after ? .bottom : .top) {
            if placement == .before || placement == .after {
                TabSidebarDropIndicator()
            }
        }
        // Dragging the header moves the group with all its folders.
        .onDrag {
            NSItemProvider(object: TabSidebarDragState.shared.begin(folderGroup: group.id) as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .folderGroup(group.id),
            height: TabSidebarStyle.rowHeight,
            placement: $placement))
        .onReceive(TabSidebarDragState.shared.$endedDrags.dropFirst()) { _ in placement = nil }
        .contextMenu { contextMenu }
    }

    private var background: Color {
        if group.isCollapsed && section.containsSelectedTab { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open Folder in Group…") { model.presentOpenFolderPanel(inFolderGroup: group.id) }
        Button("Rename Folder Group…") { model.beginRename(folderGroup: group.id) }
        Button(group.isCollapsed ? "Expand Folder Group" : "Collapse Folder Group") {
            model.toggleCollapsed(folderGroup: group.id)
        }
        Divider()
        Button("Ungroup Folders") { model.ungroupFolders(group.id) }
        Button("Close Folder Group") { model.closeFolderGroup(group.id) }
            .help("Close every folder in the group with its sessions")
    }
}

// MARK: - Folder

private struct TabSidebarFolderSection: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var settings = TabSidebarSettings.shared
    let section: TabSidebarModel.FolderSection

    /// How far the folder is set in, inside a folder group.
    let indent: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: TabSidebarStyle.rowSpacing(settings.rowStyle)) {
            TabSidebarFolderHeader(model: model, section: section)
                .padding(.leading, indent)

            if !section.folder.isCollapsed {
                if section.rows.isEmpty {
                    Text("No sessions yet")
                        .font(TabSidebarStyle.titleFont)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, indent + TabSidebarStyle.indent + 8)
                        .frame(height: TabSidebarStyle.rowHeight)
                }

                ForEach(section.rows) { row in
                    switch row {
                    case .tab(let tab):
                        TabSidebarSession(model: model, tab: tab, group: nil, indent: indent + TabSidebarStyle.indent)

                    case .group(let group):
                        TabSidebarGroupSection(model: model, section: group, indent: indent + TabSidebarStyle.indent)

                    case .folder, .folderGroup:
                        // Folders don't nest.
                        EmptyView()
                    }
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct TabSidebarFolderHeader: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarModel.FolderSection

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    private var folder: UserTabFolder { section.folder }
    private var isEditing: Bool { model.editingFolderID == folder.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(folder.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            Image(systemName: "folder")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            if isEditing {
                TextField("Folder Name", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .font(TabSidebarStyle.titleFont)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                Text(folder.name)
                    .font(TabSidebarStyle.titleFont.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Color.primary.opacity(0.85))
            }

            if folder.isCollapsed {
                Text("(\(section.tabs.count))")
                    .font(TabSidebarStyle.titleFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // A collapsed folder still says what its sessions are doing.
            if folder.isCollapsed && !(isHovering && !isEditing) {
                if section.hasFinishedUnseen {
                    TabSidebarUnseenDot()
                }
                if let light = section.claudeCodeLight, let color = light.tabColor.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                        .help(light.label)
                }
            }

            if isHovering && !isEditing {
                Button {
                    model.newTab(inFolder: folder.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Session in Folder")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: TabSidebarStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .contentShape(Rectangle())
        .help(folder.abbreviatedPath)
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.toggleCollapsed(folder: folder.id) }
        }
        .overlay {
            // A tab or group dropped on the folder joins it; a folder or folder group
            // goes next to it.
            if placement == .into {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay(alignment: placement == .after ? .bottom : .top) {
            if placement == .before || placement == .after {
                TabSidebarDropIndicator()
            }
        }
        // Dragging the header moves the folder with everything in it.
        .onDrag {
            NSItemProvider(object: TabSidebarDragState.shared.begin(folder: folder.id) as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .folder(folder.id),
            height: TabSidebarStyle.rowHeight,
            placement: $placement))
        .onReceive(TabSidebarDragState.shared.$endedDrags.dropFirst()) { _ in placement = nil }
        .contextMenu { contextMenu }
    }

    private var background: Color {
        if folder.isCollapsed && section.containsSelectedTab { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("New Session in Folder") { model.newTab(inFolder: folder.id) }
        Button("New Group in Folder") { model.createGroup(inFolder: folder.id) }
        Button("Rename Folder…") { model.beginRename(folder: folder.id) }
        Button(folder.isCollapsed ? "Expand Folder" : "Collapse Folder") {
            model.toggleCollapsed(folder: folder.id)
        }
        Divider()
        Button("Reveal in Finder") { model.revealInFinder(folder: folder.id) }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(folder.path, forType: .string)
        }
        Divider()
        Button("Add Folder to New Group") { model.createFolderGroup(with: folder.id) }
        let otherGroups = model.folderGroupsInWindow.filter { $0.id != folder.groupID }
        if !otherGroups.isEmpty {
            Menu("Add Folder to Group") {
                ForEach(otherGroups) { group in
                    Button(group.name) { model.add(folder: folder.id, toFolderGroup: group.id) }
                }
            }
        }
        if folder.groupID != nil {
            Button("Remove Folder from Group") { model.removeFolderFromGroup(folder.id) }
        }
        Divider()
        Button("Remove Folder") { model.removeFolder(folder.id) }
            .help("Take the folder out of the sidebar and keep its sessions")
        Button("Close Folder") { model.closeFolder(folder.id) }
            .help("Close the folder's sessions and take it out of the sidebar")
    }
}

// MARK: - Group

private struct TabSidebarGroupSection: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var settings = TabSidebarSettings.shared
    let section: TabSidebarModel.GroupSection

    /// How far the group is set in, inside a folder.
    let indent: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: TabSidebarStyle.rowSpacing(settings.rowStyle)) {
            TabSidebarGroupHeader(model: model, section: section)
                .padding(.leading, indent)

            if !section.group.isCollapsed {
                ForEach(section.tabs) { tab in
                    TabSidebarSession(model: model, tab: tab, group: section.group, indent: indent + TabSidebarStyle.indent)
                }
            }
        }
        .padding(.top, 4)
    }
}

private struct TabSidebarGroupHeader: View {
    @ObservedObject var model: TabSidebarModel
    let section: TabSidebarModel.GroupSection

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    private var group: UserTabGroup { section.group }
    private var isEditing: Bool { model.editingGroupID == group.id }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(group.isCollapsed ? 0 : 90))
                .foregroundStyle(.secondary)
                .frame(width: 10)

            if isEditing {
                TextField("Group Name", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .font(TabSidebarStyle.titleFont)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                nameLabel
            }

            if group.isCollapsed {
                Text("(\(section.tabs.count))")
                    .font(TabSidebarStyle.titleFont)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            // A collapsed group still says what its sessions are doing.
            if group.isCollapsed && !(isHovering && !isEditing) {
                if section.hasFinishedUnseen {
                    TabSidebarUnseenDot()
                }
                if let light = section.claudeCodeLight, let color = light.tabColor.displayColor {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 8, height: 8)
                        .help(light.label)
                }
            }

            if isHovering && !isEditing {
                Button {
                    model.newTab(inGroup: group.id)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("New Session in Group")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: TabSidebarStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6).fill(background))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            guard !isEditing else { return }
            withAnimation(.easeOut(duration: 0.15)) { model.toggleCollapsed(group.id) }
        }
        .overlay {
            // A tab dropped on the group joins it; a group or folder goes next to it.
            if placement == .into {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay(alignment: placement == .after ? .bottom : .top) {
            if placement == .before || placement == .after {
                TabSidebarDropIndicator()
            }
        }
        // Dragging the header moves the group with all its sessions.
        .onDrag {
            NSItemProvider(object: TabSidebarDragState.shared.begin(group: group.id) as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .group(group.id),
            height: TabSidebarStyle.rowHeight,
            placement: $placement))
        .onReceive(TabSidebarDragState.shared.$endedDrags.dropFirst()) { _ in placement = nil }
        .contextMenu { contextMenu }
    }

    private var background: Color {
        if group.isCollapsed && section.containsSelectedTab { return Color.primary.opacity(0.14) }
        if isHovering { return Color.primary.opacity(0.06) }
        return .clear
    }

    @ViewBuilder
    private var nameLabel: some View {
        if let color = group.color.displayColor {
            Text(group.name)
                .font(TabSidebarStyle.titleFont)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 1)
                .foregroundStyle(Color(nsColor: color.isLightColor ? .black : .white))
                .background(Capsule().fill(Color(nsColor: color)))
        } else {
            Text(group.name)
                .font(TabSidebarStyle.titleFont)
                .lineLimit(1)
                .foregroundStyle(Color.primary.opacity(0.8))
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("New Session in Group") { model.newTab(inGroup: group.id) }
        Button("Rename Group…") { model.beginRename(group: group.id) }
        TabSidebarColorMenu(title: "Group Color", choices: TerminalTabColor.groupChoices, selected: group.color) { color in
            model.setColor(color, forGroup: group.id)
        }
        Button(group.isCollapsed ? "Expand Group" : "Collapse Group") {
            model.toggleCollapsed(group.id)
        }
        Divider()
        let folderID = model.folder(ofGroup: group.id)
        let otherFolders = model.foldersInWindow.filter { $0.id != folderID }
        if !otherFolders.isEmpty {
            Menu("Add Group to Folder") {
                ForEach(otherFolders) { folder in
                    Button(folder.name) { model.add(group: group.id, toFolder: folder.id) }
                }
            }
        }
        if folderID != nil {
            Button("Remove Group from Folder") { model.removeGroupFromFolder(group.id) }
        }
        Divider()
        Button("Ungroup") { model.ungroup(group.id) }
        Button("Close Group") { model.closeGroup(group.id) }
    }
}

// MARK: - By Status

/// The sessions under their columns on the session board, in board order, when the
/// sidebar is grouped by status. A column with no sessions isn't shown. A column's
/// header folds it, and takes a session dropped on it.
private struct TabSidebarStatusSections: View {
    @ObservedObject var model: TabSidebarModel
    @ObservedObject private var board = SessionBoardSettings.shared
    @ObservedObject private var settings = TabSidebarSettings.shared

    var body: some View {
        // What the search leaves, in board order.
        let tabs = model.shownRows.flatMap(\.allTabs)
        let byID = Dictionary(tabs.map { ($0.id, $0) }) { first, _ in first }
        let lanes = model.boardLanes(of: tabs)
        ForEach(board.columns) { column in
            let lane = (lanes[column.id] ?? []).compactMap { byID[$0] }
            if !lane.isEmpty {
                let isCollapsed = settings.collapsedStatuses.contains(column.id) && !model.isSearching
                TabSidebarStatusHeader(model: model, column: column, count: lane.count, isCollapsed: isCollapsed)
                if !isCollapsed {
                    ForEach(lane) { tab in
                        TabSidebarSession(model: model, tab: tab, group: nil, indent: TabSidebarStyle.indent)
                    }
                }
            }
        }
    }
}

private struct TabSidebarStatusHeader: View {
    @ObservedObject var model: TabSidebarModel
    let column: SessionBoardColumn
    let count: Int
    let isCollapsed: Bool

    @ObservedObject private var settings = TabSidebarSettings.shared
    @State private var isHovering = false
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: column.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(nsColor: column.displayColor))
                .frame(width: 14)
            Text(column.label)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if isCollapsed || isHovering {
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            if isHovering {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isTargeted ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isCollapsed {
                    settings.collapsedStatuses.remove(column.id)
                } else {
                    settings.collapsedStatuses.insert(column.id)
                }
            }
        }
        .help(isCollapsed ? "Show \(column.label)" : "Hide \(column.label)")
        .onDrop(of: [.plainText], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            let model = model
            let column = column.id
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let token = object as? String else { return }
                DispatchQueue.main.async {
                    guard case .tab(let window) = TabSidebarDragState.shared.take(token: token) else { return }
                    model.moveOnBoard(window, to: column)
                }
            }
            return true
        }
        .contextMenu {
            Menu("Group By") {
                ForEach(TabSidebarSettings.GroupBy.allCases, id: \.self) { groupBy in
                    Button(groupBy == settings.groupBy ? "\(groupBy.localizedName) ✓" : groupBy.localizedName) {
                        settings.groupBy = groupBy
                    }
                }
            }
        }
    }
}

// MARK: - Session

/// A session's row, with the subagents and teammates its Claude Code started set in
/// below it.
private struct TabSidebarSession: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab
    let group: UserTabGroup?
    let indent: CGFloat

    @ObservedObject private var subagents = ClaudeSubagents.shared
    @ObservedObject private var settings = TabSidebarSettings.shared

    private var sessions: [UUID] {
        (model.infos[tab.id]?.sessions ?? []).compactMap { session -> UUID? in
            if case .claude(let claude) = session { return claude.id }
            return nil
        }
    }

    var body: some View {
        let sessions = sessions
        let agents = settings.showsSubagents ? subagents.agents(of: sessions) : []
        let isCollapsed = subagents.isCollapsed(sessions)
        VStack(alignment: .leading, spacing: TabSidebarStyle.rowSpacing(settings.rowStyle)) {
            TabSidebarTabRow(model: model, tab: tab, group: group, indent: indent)
            if !agents.isEmpty {
                TabSidebarSubagentsHeader(
                    agents: agents,
                    isCollapsed: isCollapsed,
                    toggle: {
                        withAnimation(.easeInOut(duration: 0.15)) { subagents.setCollapsed(sessions, !isCollapsed) }
                    },
                    clear: {
                        withAnimation(.easeInOut(duration: 0.15)) { subagents.clearFinished(of: sessions) }
                    })
                .padding(.leading, indent + TabSidebarStyle.indent)
                if !isCollapsed {
                    ForEach(agents) { agent in
                        TabSidebarSubagentRow(model: model, tab: tab, agent: agent, indent: indent + TabSidebarStyle.indent)
                    }
                }
            }
        }
        // What Reveal Active Session scrolls to.
        .id(tab.id)
        .onAppear { subagents.start() }
    }
}

/// Folds a session's subagents away, and counts them by what they are doing so the
/// folded list still tells whether any is at work.
private struct TabSidebarSubagentsHeader: View {
    let agents: [ClaudeSubagent]
    let isCollapsed: Bool
    let toggle: () -> Void
    let clear: () -> Void

    @State private var isHovering = false

    var body: some View {
        TabSidebarSubagentsHeaderLabel(agents: agents, isCollapsed: isCollapsed, isHovering: isHovering, clear: clear)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(perform: toggle)
            .help(isCollapsed ? "Show the subagents" : "Hide the subagents")
    }
}

/// The header's look: a disclosure chevron, the count, a count for each state, and,
/// once any is over, a button that clears those off the list.
struct TabSidebarSubagentsHeaderLabel: View {
    let agents: [ClaudeSubagent]
    let isCollapsed: Bool
    var isHovering = false
    var clear: () -> Void = {}

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .foregroundStyle(.tertiary)
                .frame(width: 9)
            Text(agents.count == 1 ? "1 subagent" : "\(agents.count) subagents")
                .lineLimit(1)
            Spacer(minLength: 4)
            ForEach(ClaudeSubagent.State.shownOrder, id: \.self) { state in
                let count = agents.filter { $0.state == state }.count
                if count > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: state.symbolName)
                            .font(.system(size: 8, weight: .semibold))
                        Text("\(count)")
                            .monospacedDigit()
                    }
                    .foregroundStyle(state.color)
                }
            }
            if agents.contains(where: { $0.state.isOver }) {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(agents.allSatisfy(\.state.isOver) ? "Clear the subagents" : "Clear the finished subagents")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: 18)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
    }
}

extension ClaudeSubagent.State {
    /// The order the header counts them in: what is at work first.
    static let shownOrder: [Self] = [.working, .idle, .failed, .finished]

    var symbolName: String {
        switch self {
        case .working: return ClaudeCodeLight.working.symbolName
        case .idle: return "moon.zzz"
        case .finished: return ClaudeCodeLight.clean.symbolName
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// The session lights' colors: blue at work, green done, red failed, and yellow for
    /// a teammate waiting on its next message.
    var color: Color {
        let tabColor: TerminalTabColor
        switch self {
        case .working: tabColor = .blue
        case .idle: tabColor = .yellow
        case .finished: tabColor = .green
        case .failed: tabColor = .red
        }
        return tabColor.displayColor.map { Color(nsColor: $0) } ?? .secondary
    }
}

/// A subagent or teammate of a session: what it was asked to do, and whether it works,
/// waits for its next message or is done. Clicking it reads its transcript beside the
/// session.
private struct TabSidebarSubagentRow: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab
    let agent: ClaudeSubagent
    let indent: CGFloat

    @State private var isHovering = false

    var body: some View {
        TabSidebarSubagentLabel(agent: agent, isHovering: isHovering)
            .padding(.leading, indent)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture { open() }
            .help(help)
    }

    private var help: String {
        let state: String
        switch agent.state {
        case .working: state = "Working"
        case .idle: state = "Waiting for a message"
        case .finished: state = "Done"
        case .failed: state = "Failed on an API error"
        }
        let what = [agent.runsAs ?? agent.agentType, agent.name].compactMap { $0 }.joined(separator: " · ")
        return [agent.title, what.isEmpty ? nil : what, state, agent.transcript == nil ? nil : "Click to read its transcript"]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private func open() {
        guard let window = tab.window else { return }
        model.select(window)
        guard let transcript = agent.transcript else { return }
        window.documentPaneModel.show(transcript, title: agent.title)
    }
}

/// What a subagent's row shows: a turn arrow, its task, its type, and a symbol for what
/// it is doing. Smaller than a session's row, so it reads as belonging to it.
struct TabSidebarSubagentLabel: View {
    let agent: ClaudeSubagent
    var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(agent.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let type = agent.shownType {
                Text(type)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Image(systemName: agent.state.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(agent.state.color)
                .frame(width: 12)
        }
        .font(.system(size: 11))
        .foregroundStyle(agent.state.isOver ? Color.secondary : Color.primary.opacity(0.85))
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
    }
}

// MARK: - Tab

private struct TabSidebarTabRow: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab
    let group: UserTabGroup?

    /// How far the row is set in, inside a group or folder.
    let indent: CGFloat

    @State private var isHovering = false
    @State private var placement: TabSidebarDropPlacement?
    @FocusState private var fieldFocused: Bool

    @ObservedObject private var modifiers = TabSidebarModifierMonitor.shared
    @ObservedObject private var settings = TabSidebarSettings.shared

    private var isExtended: Bool { settings.rowStyle == .extended }
    private var height: CGFloat { isExtended ? TabSidebarStyle.extendedRowHeight : TabSidebarStyle.rowHeight }
    private var cornerRadius: CGFloat { isExtended ? 8 : 6 }
    private var titleFont: Font { isExtended ? TabSidebarStyle.extendedTitleFont : TabSidebarStyle.titleFont }
    private var info: TabSidebarSessionInfo? { model.infos[tab.id] }
    private var isSearchHighlight: Bool { model.highlightedTab?.id == tab.id }

    private var isEditing: Bool { model.editingTabID == tab.id }
    private var colors: TabSidebarRowColors { TabSidebarRowColors(tab: tab) }
    private var finishedUnseen: Bool { tab.claudeCodeActivity.finishedUnseen && !tab.isSelected }

    /// Shortcut labels only show while their modifiers are held, like the menu bar's.
    private var showsShortcut: Bool {
        guard let jump = model.jumpModifiers, !jump.isEmpty else { return false }
        return modifiers.held == jump
    }

    private var recedes: Bool {
        tab.claudeCodeState?.light == .working && !tab.isSelected && !isHovering
    }

    /// Whether the row shows the magpie in place of a title the terminal hasn't set.
    private var wearsGlyph: Bool {
        Maggie.isMaggie && tab.title == Maggie.placeholderTitle && !isEditing
    }

    var body: some View {
        HStack(spacing: 6) {
            if wearsGlyph {
                // A session the terminal hasn't named yet wears the magpie, as tall
                // as the row allows: its spread wings need the room to read. It sits
                // beside both lines of an extended row, so it is centered in the row
                // instead of riding the title line above the location.
                Image("MaggieGlyph")
                    .resizable()
                    .scaledToFit()
                    .frame(height: isExtended ? 30 : 22)
                    .accessibilityLabel(Maggie.appName)
            }

            VStack(alignment: .leading, spacing: 2) {
                titleLine

                if isExtended && !isEditing {
                    HStack(spacing: 6) {
                        locationLine
                        Spacer(minLength: 0)
                        modelLabel
                        speakerButton
                    }
                }
            }
        }
        .font(tab.isSelected ? titleFont.weight(.semibold) : titleFont)
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: cornerRadius).fill(colors.background(isHovering: isHovering)))
        // A session that is working needs nothing yet, so it steps back and the ones
        // waiting for an answer or finished stand out.
        .opacity(recedes ? 0.7 : 1)
        .animation(.easeOut(duration: 0.15), value: recedes)
        .overlay {
            if tab.isSelected, let outline = colors.outline {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(outline, lineWidth: 1)
            }
        }
        .overlay {
            if isSearchHighlight {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay(alignment: .leading) { groupMarker }
        .overlay(alignment: placement == .after ? .bottom : .top) {
            if placement != nil { TabSidebarDropIndicator() }
        }
        .padding(.leading, indent)
        .contentShape(Rectangle())
        .onHover { inside in
            isHovering = inside
            if inside {
                showHoverCard()
            } else {
                TabSidebarHoverCard.shared.hide(tab.id)
            }
        }
        .onDisappear { TabSidebarHoverCard.shared.hide(tab.id) }
        .onTapGesture {
            TabSidebarHoverCard.shared.hide(tab.id)
            guard !isEditing, let window = tab.window else { return }

            // Each click of a double click arrives here, so the first click selects
            // the tab immediately and the second starts renaming it.
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 {
                model.beginRename(window)
            } else {
                model.select(window)
            }
        }
        .onDrag {
            TabSidebarHoverCard.shared.hide(tab.id)
            guard let window = tab.window else { return NSItemProvider() }
            return NSItemProvider(object: TabSidebarDragState.shared.begin(window) as NSString)
        }
        .onDrop(of: [.plainText], delegate: TabSidebarDropDelegate(
            model: model,
            target: .tab(tab.window),
            height: height,
            placement: $placement))
        .onReceive(TabSidebarDragState.shared.$endedDrags.dropFirst()) { _ in placement = nil }
        .contextMenu { TabSidebarSessionMenu(model: model, tab: tab) }
    }

    private var titleLine: some View {
        HStack(spacing: 6) {
            if tab.isZoomed {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .help("A split is zoomed")
            }

            if isEditing {
                TextField("Session Title", text: $model.editingDraft)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                    .onSubmit { model.commitEditing() }
                    .onExitCommand { model.cancelEditing() }
                    .onChange(of: fieldFocused) { focused in
                        if !focused && isEditing { model.commitEditing() }
                    }
            } else {
                if finishedUnseen {
                    TabSidebarUnseenDot()
                }

                // The magpie standing in for a missing title is drawn by the row itself.
                if !wearsGlyph {
                    Text(tab.title)
                        .fontWeight(finishedUnseen ? .semibold : nil)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 0)

            // An extended row has it at the end of its second line instead.
            if !isExtended && !isEditing {
                speakerButton
            }

            // Only one of these shows at a time, but all of them take their space, so the
            // speaker before them doesn't move when the close button shows on hover.
            let showsClose = isHovering && !isEditing
            let showsKey = !showsClose && showsShortcut && tab.keyEquivalent != nil
            ZStack(alignment: .trailing) {
                if let state = tab.claudeCodeState {
                    TabSidebarClaudeCodeStatus(
                        state: state,
                        activity: tab.claudeCodeActivity,
                        lastActive: info?.lastActive,
                        tint: colors.symbolTint)
                        .opacity(showsClose || showsKey ? 0 : 1)
                }
                if let keyEquivalent = tab.keyEquivalent {
                    Text(keyEquivalent)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .frame(minHeight: 16)
                        .background(Capsule().fill(colors.foreground.opacity(0.18)))
                        .opacity(showsKey ? 1 : 0)
                }
                Button {
                    if let window = tab.window { model.close(window) }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(showsClose ? 0.8 : 0)
                .allowsHitTesting(showsClose)
                .help("Close Session")
            }
        }
    }

    /// Reads the session's last response aloud, or stops reading it.
    @ViewBuilder
    private var speakerButton: some View {
        if tab.canSpeak {
            Button {
                if let window = tab.window { ClaudeCodeSpeaker.shared.toggle(window) }
            } label: {
                Image(systemName: tab.isSpeaking ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 10, weight: .medium))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(tab.isSpeaking ? 1 : 0.6)
            .help(tab.isSpeaking ? "Stop Reading" : "Read Last Response Aloud")
        }
    }

    /// Where the session works: its project and branch, its project's worktree, or its
    /// directory outside a repository. A worktree's branch is left to the hover card,
    /// since worktrees get made up names.
    @ViewBuilder
    private var locationLine: some View {
        if let info, let location = Self.location(of: info) {
            HStack(spacing: 4) {
                Image(systemName: location.symbol)
                    .font(.system(size: 9, weight: .semibold))
                Text(location.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 11))
            .opacity(0.6)
        } else {
            // Keeps the row's layout while the info is read.
            Text(" ").font(.system(size: 11))
        }
    }

    /// The model the session's agent is using. It keeps its width, and the location
    /// before it is cut short instead.
    @ViewBuilder
    private var modelLabel: some View {
        if let model = info?.model {
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 9, weight: .semibold))
                Text(TabSidebarHoverCardView.shortName(model))
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .opacity(0.6)
            .fixedSize()
            .help(model)
        }
    }

    static func location(of info: TabSidebarSessionInfo) -> (symbol: String, text: String)? {
        if let checkout = info.checkout {
            if checkout.isLinkedWorktree {
                return ("square.stack.3d.up", "\(checkout.project) · worktree")
            }
            if let branch = checkout.branch {
                return ("arrow.triangle.branch", "\(checkout.project) · \(branch)")
            }
            return ("arrow.triangle.branch", checkout.project)
        }
        return info.abbreviatedDirectory.map { ("folder", $0) }
    }

    private func showHoverCard() {
        let tab = tab
        let info = info
        let tint = colors.symbolTint
        TabSidebarHoverCard.shared.show(tab.id, from: model.window, sidebarWidth: settings.width) {
            TabSidebarHoverCardView(tab: tab, info: info, tint: tint)
        }
    }

    /// A thin bar in the group's color marks tabs that belong to a colored group.
    @ViewBuilder
    private var groupMarker: some View {
        if let group, let color = group.color.displayColor {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: color))
                .frame(width: 3, height: height - 10)
                .offset(x: -8)
        }
    }
}

/// A session's menu, the same on its sidebar row and its card on the session board.
struct TabSidebarSessionMenu: View {
    @ObservedObject var model: TabSidebarModel
    let tab: TabSidebarModel.Tab

    @ObservedObject private var settings = TabSidebarSettings.shared

    private var info: TabSidebarSessionInfo? { model.infos[tab.id] }

    var body: some View {
        if let window = tab.window {
            Button("Rename Session…") { model.beginRename(window) }
            TabSidebarColorMenu(title: "Session Color", choices: TerminalTabColor.tabChoices, selected: tab.assignedColor) { color in
                model.setColor(color, for: window)
            }
            // Every session reads with the same voice.
            Menu("Voice") {
                ForEach(ElevenLabs.voices, id: \.id) { voice in
                    Button(ElevenLabs.voiceID == voice.id ? "\(voice.name) ✓" : voice.name) {
                        TerminalWindow.pickVoice(voice.id)
                    }
                }
            }
            if let state = tab.claudeCodeState, !state.landableWorktrees.isEmpty {
                Button("Land on \(state.landingBranch ?? "Main Checkout")") {
                    ClaudeCodeLights.shared.land(window)
                }
                .help("Rebase the session's commits onto the branch, then fast-forward it")
            }

            if tab.claudeCodeState != nil,
               !tab.claudeCodeActivity.finishedUnseen,
               tab.claudeCodeActivity.workingSince == nil {
                Button("Mark as Unread") { window.markClaudeCodeActivityUnseen() }
            }

            // Hand the session to the other agent, in the same directory: fresh, or
            // carrying the conversation so far.
            let session = info?.sessions.first
            ForEach(CodingAgentSettings.shared.pivotTargets(from: session?.agent), id: \.self) { agent in
                Menu(session == nil ? "Start \(agent.displayName) Here" : "Pivot to \(agent.displayName)") {
                    Button("New Session") { model.pivot(window, to: agent, carryingConversation: false) }
                    if session?.transcript != nil {
                        Button("Continue the Conversation") { model.pivot(window, to: agent, carryingConversation: true) }
                            .help("Writes the conversation out and starts \(agent.displayName) reading it")
                    }
                }
            }

            if let info, info.directory != nil || info.branch != nil || !info.sessions.isEmpty {
                Divider()
                if let directory = info.directory {
                    Button("Copy Path") { Self.copy(directory) }
                }
                if let branch = info.branch {
                    Button("Copy Branch") { Self.copy(branch) }
                }
                if let session = info.sessions.first {
                    Button("Copy Session ID") { Self.copy(session.id.uuidString.lowercased()) }
                }
            }

            Divider()

            Menu("Move to Status") {
                let current = SessionBoardSettings.shared.column(for: tab.boardPlace?.column)
                ForEach(SessionBoardSettings.shared.columns) { column in
                    Toggle(isOn: Binding(
                        get: { column.id == current },
                        set: { _ in model.moveOnBoard(window, to: column.id) })) {
                        Label {
                            Text(column.label)
                        } icon: {
                            if let image = column.menuImage { Image(nsImage: image) }
                        }
                    }
                }
            }

            // Linked by hand: on the board's Together view the session shows under it.
            let items = WorkItemStore.shared.items
            if !items.isEmpty {
                Menu("Work Item") {
                    ForEach(items) { item in
                        Toggle(item.title, isOn: Binding(
                            get: { tab.workItemID == item.id },
                            set: { linked in window.workItemID = linked ? item.id : nil }))
                    }
                    if tab.workItemID != nil {
                        Divider()
                        Button("Unlink") { window.workItemID = nil }
                    }
                }
            }

            Divider()

            Button("Add Session to New Group") { model.createGroup(with: window) }
            let otherGroups = model.groupsInWindow.filter { $0.id != tab.groupID }
            if !otherGroups.isEmpty {
                Menu("Add Session to Group") {
                    ForEach(otherGroups) { group in
                        Button(group.name) { model.add(window, to: group.id) }
                    }
                }
            }
            if tab.groupID != nil {
                Button("Remove from Group") { model.removeFromGroup(window) }
            }

            Divider()

            // A grouped session moves with its group.
            let otherFolders = model.foldersInWindow.filter { $0.id != tab.folderID }
            if !otherFolders.isEmpty {
                Menu(tab.groupID == nil ? "Add Session to Folder" : "Add Group to Folder") {
                    ForEach(otherFolders) { folder in
                        Button(folder.name) { model.add(window, toFolder: folder.id) }
                    }
                }
            }
            if tab.folderID != nil {
                Button(tab.groupID == nil ? "Remove from Folder" : "Remove Group from Folder") {
                    model.removeFromFolder(window)
                }
            }

            Divider()

            Button("Move Session to New Window") { model.moveToNewWindow(window) }

            Divider()

            Button("Close Session") { model.close(window) }
            Button("Close Other Sessions") { model.closeOthers(window) }
            Button("Close Sessions Below") { model.closeBelow(window) }

            Divider()

            Menu("Row Style") {
                ForEach(TabSidebarSettings.RowStyle.allCases, id: \.self) { style in
                    Button(style == settings.rowStyle ? "\(style.localizedName) ✓" : style.localizedName) {
                        settings.rowStyle = style
                    }
                }
            }
            Menu("Group By") {
                ForEach(TabSidebarSettings.GroupBy.allCases, id: \.self) { groupBy in
                    Button(groupBy == settings.groupBy ? "\(groupBy.localizedName) ✓" : groupBy.localizedName) {
                        settings.groupBy = groupBy
                    }
                }
            }
            Button(settings.showsSubagents ? "Show Subagents ✓" : "Show Subagents") {
                settings.showsSubagents.toggle()
            }
        }
    }

    private static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// How a session's row shows its color: picked by hand, it fills the row; following
/// the session, it tints it. The board's cards show it the same way.
struct TabSidebarRowColors {
    let tab: TabSidebarModel.Tab

    private var tabColor: NSColor? { tab.color.displayColor }

    /// How the row shows its color.
    enum Fill {
        /// A color picked by hand, filling the row.
        case solid(NSColor)

        /// What the session is doing, as a pastel tint, so a column of them stays calm.
        case pastel(NSColor)

        /// No color.
        case none
    }

    var fill: Fill {
        guard let tabColor else { return .none }
        switch tab.assignedColor {
        case .auto:
            return .pastel(tabColor)
        case .attention:
            // Only a session that needs something is filled.
            switch tab.claudeCodeState?.light {
            case .waiting, .pending, .unlanded: return .pastel(tabColor)
            case .working, .clean, nil: return .none
            }
        default:
            return .solid(tabColor)
        }
    }

    func background(isHovering: Bool) -> Color {
        switch fill {
        case .solid(let color):
            // Fully when selected, and lighter otherwise so the selected tab stands out.
            let opacity = tab.isSelected ? 1.0 : (isHovering ? 0.55 : 0.4)
            return Color(nsColor: color).opacity(opacity)

        case .pastel(let color):
            let pastel = color.blended(withFraction: 0.35, of: .white) ?? color
            let opacity = tab.isSelected ? 0.3 : (isHovering ? 0.22 : 0.14)
            return Color(nsColor: pastel).opacity(opacity)

        case .none:
            if tab.isSelected { return Color.primary.opacity(0.14) }
            if isHovering { return Color.primary.opacity(0.06) }
            return .clear
        }
    }

    /// The border of the selected row. A solid row stands out by its fill alone.
    var outline: Color? {
        switch fill {
        case .solid: return nil
        case .pastel(let color): return Color(nsColor: color).opacity(0.6)
        case .none: return Color.primary.opacity(0.08)
        }
    }

    var foreground: Color {
        if case .solid(let color) = fill, tab.isSelected {
            return Color(nsColor: color.isLightColor ? .black : .white)
        }

        return tab.isSelected ? .primary : .primary.opacity(0.8)
    }

    /// A row following its session colors the status symbol at full strength, since its
    /// fill is faint or missing.
    var symbolTint: Color? {
        guard tab.assignedColor.followsClaudeCode else { return nil }
        return tabColor.map { Color(nsColor: $0) }
    }
}

// MARK: - Shared Pieces

/// Sizes shared by tab rows and group headers so they line up.
private enum TabSidebarStyle {
    static let titleFont = Font.system(size: 12)
    static let rowHeight: CGFloat = 28

    static let extendedTitleFont = Font.system(size: 13)
    static let extendedRowHeight: CGFloat = 44

    /// How far each level of nesting sets a row in.
    static let indent: CGFloat = 12

    static func rowSpacing(_ style: TabSidebarSettings.RowStyle) -> CGFloat {
        style == .extended ? 4 : 2
    }
}

/// A submenu that picks a tab color, showing a swatch for each color.
private struct TabSidebarColorMenu: View {
    let title: String
    let choices: [TerminalTabColor]
    let selected: TerminalTabColor
    let onSelect: (TerminalTabColor) -> Void

    var body: some View {
        Menu(title) {
            ForEach(choices, id: \.self) { color in
                Button {
                    onSelect(color)
                } label: {
                    Label {
                        Text(color == selected ? "\(color.localizedName) ✓" : color.localizedName)
                    } icon: {
                        Image(nsImage: color.swatchImage(selected: false))
                    }
                }
            }
        }
    }
}

/// Marks a session that finished while it wasn't looked at, like an unread message. It
/// takes the text's color, since the accent color could be read as a light.
private struct TabSidebarUnseenDot: View {
    var body: some View {
        Circle()
            .frame(width: 6, height: 6)
            .help("Finished while you were away")
    }
}

/// What a session's Claude Code is doing, as a symbol and a few characters, so it reads
/// without telling the row's colors apart: how long it has been working, that it waits
/// for an answer, how many files or commits are left, or how long ago it finished.
private struct TabSidebarClaudeCodeStatus: View {
    let state: ClaudeCodeTabState
    let activity: ClaudeCodeActivity
    let lastActive: Date?
    let tint: Color?

    private var stoppedSince: Date? { state.stoppedSince(activity, lastActive: lastActive) }

    var body: some View {
        // A session found already done says nothing more than its color does.
        if state.light != .clean || stoppedSince != nil {
            status
        }
    }

    private var status: some View {
        // Only a working session counts seconds.
        TimelineView(.periodic(from: .now, by: state.light == .working ? 1 : 30)) { context in
            HStack(spacing: 3) {
                Image(systemName: state.light.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint ?? Color.primary)
                if let text = text(at: context.date) {
                    Text(text)
                        .font(.system(size: 11))
                        .monospacedDigit()
                }
            }
            .opacity(0.85)
            .help(state.summary(activity, lastActive: lastActive, at: context.date))
        }
    }

    private func text(at now: Date) -> String? {
        switch state.light {
        case .working:
            return activity.workingSince.map { ClaudeCodeActivity.elapsed(since: $0, at: now) }
        case .waiting:
            return nil
        case .pending, .unlanded:
            return state.badge.map(String.init)
        case .clean:
            return stoppedSince.map { ClaudeCodeActivity.ago($0, at: now) }
        }
    }

}

extension ClaudeCodeLight {
    /// The symbol shown for the light, so it reads without telling colors apart.
    var symbolName: String {
        switch self {
        case .working: return "circle.dashed"
        case .waiting: return "exclamationmark.bubble"
        case .pending: return "pencil"
        case .unlanded: return "arrow.triangle.merge"
        case .clean: return "checkmark"
        }
    }
}

/// The modifier keys held down, once they have been held for a moment, so shortcut
/// labels don't flash while a shortcut is typed.
final class TabSidebarModifierMonitor: ObservableObject {
    static let shared = TabSidebarModifierMonitor()

    private static let delay: TimeInterval = 0.2

    @Published private(set) var held: NSEvent.ModifierFlags = []

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pending: DispatchWorkItem?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(event.modifierFlags)
            return event
        }

        // Modifiers released in another app are never seen.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.update([]) }
    }

    private func update(_ flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .option, .control, .shift])
        pending?.cancel()
        pending = nil
        if !held.isEmpty { held = [] }
        guard !flags.isEmpty else { return }

        let item = DispatchWorkItem { [weak self] in self?.held = flags }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: item)
    }
}

private struct TabSidebarDropIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(height: 2)
    }
}

struct TabSidebarVisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// The × in the header of a panel beside the terminal, for those who don't know its
/// shortcut. `help` names the shortcut.
struct SidePanelCloseButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .frame(width: 20, height: 20)
        .help(help)
        .accessibilityLabel("Close")
    }
}

// MARK: - Drag and Drop

/// Where a drop lands relative to the row under the pointer: before it, after it, or, for
/// a header, inside what it heads. A header is three zones top to bottom: between, over,
/// between.
enum TabSidebarDropPlacement {
    case before
    case after
    case into
}

/// Tracks the tab being dragged. The drag pasteboard only carries a token; the window
/// itself is looked up here once the token is verified, so an unrelated text drop can
/// never move a tab.
final class TabSidebarDragState: ObservableObject {
    static let shared = TabSidebarDragState()

    /// Changed when a drag ends, however it ends. A drag let go outside the sidebar, or
    /// cancelled, never tells the rows it last passed over, so they wait for this to
    /// take down the line showing where it would have landed.
    @Published private(set) var endedDrags = 0

    /// How often a drag is checked for having ended.
    private static let endCheckInterval: TimeInterval = 0.25
    private var endCheck: Timer?

    /// What is dragged: a tab, or a group, folder or folder group with everything in it.
    enum Payload {
        case tab(TerminalWindow)
        case group(UUID)
        case folder(UUID)
        case folderGroup(UUID)
    }

    private(set) weak var window: TerminalWindow?
    private(set) var groupID: UUID?
    private(set) var folderID: UUID?
    private(set) var folderGroupID: UUID?
    private var token: String?

    /// Whether anything that can be dropped is being dragged.
    var isDragging: Bool { window != nil || isDraggingBlock }

    /// Whether a group, folder or folder group is dragged, which go next to a group
    /// rather than into it.
    var isDraggingBlock: Bool { groupID != nil || isDraggingFolderOrGroupOfThem }

    /// Whether a folder or folder group is dragged, which go next to a folder.
    var isDraggingFolderOrGroupOfThem: Bool { folderID != nil || isDraggingFolderGroup }

    var isDraggingFolderGroup: Bool { folderGroupID != nil }

    func begin(_ window: TerminalWindow) -> String {
        begin { $0.window = window }
    }

    func begin(group groupID: UUID) -> String {
        begin { $0.groupID = groupID }
    }

    func begin(folder folderID: UUID) -> String {
        begin { $0.folderID = folderID }
    }

    func begin(folderGroup groupID: UUID) -> String {
        begin { $0.folderGroupID = groupID }
    }

    private func begin(_ set: (TabSidebarDragState) -> Void) -> String {
        let token = "ghostty-tab:\(UUID().uuidString)"
        clear()
        set(self)
        self.token = token
        watchForEnd()
        return token
    }

    private func clear() {
        window = nil
        groupID = nil
        folderID = nil
        folderGroupID = nil
    }

    /// Ends the drag once the mouse button is up. The timer runs in the drag's own run
    /// loop mode too.
    private func watchForEnd() {
        endCheck?.invalidate()
        let timer = Timer(timeInterval: Self.endCheckInterval, repeats: true) { [weak self] _ in
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self?.end()
        }
        RunLoop.main.add(timer, forMode: .common)
        endCheck = timer
    }

    private func end() {
        endCheck?.invalidate()
        endCheck = nil
        endedDrags += 1
    }

    func take(token: String) -> Payload? {
        guard token == self.token else { return nil }
        self.token = nil
        defer { clear() }
        if let folderGroupID { return .folderGroup(folderGroupID) }
        if let folderID { return .folder(folderID) }
        if let groupID { return .group(groupID) }
        return window.map(Payload.tab)
    }
}

private struct TabSidebarDropDelegate: DropDelegate {
    enum Target {
        case tab(TerminalWindow?)
        case group(UUID)
        case folder(UUID)
        case folderGroup(UUID)
        case end
    }

    let model: TabSidebarModel
    let target: Target
    let height: CGFloat
    @Binding var placement: TabSidebarDropPlacement?

    /// Whether the drop is a directory from outside, which opens as a folder. Only the
    /// space after the tabs takes one.
    private func isFolderDrop(_ info: DropInfo) -> Bool {
        guard case .end = target, !TabSidebarDragState.shared.isDragging else { return false }
        return info.hasItemsConforming(to: [.fileURL])
    }

    func validateDrop(info: DropInfo) -> Bool {
        if isFolderDrop(info) { return true }
        let drag = TabSidebarDragState.shared
        guard drag.isDragging, info.hasItemsConforming(to: [.plainText]) else { return false }

        return true
    }

    func dropEntered(info: DropInfo) {
        placement = placement(for: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = placement(for: info)
        return DropProposal(operation: isFolderDrop(info) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        placement = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let finalPlacement = placement(for: info)
        placement = nil

        if isFolderDrop(info) {
            return openDirectories(info)
        }

        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let model = model
        let target = target
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let token = object as? String else { return }
            DispatchQueue.main.async {
                let after = finalPlacement == .after
                let payload = TabSidebarDragState.shared.take(token: token)

                // Listed by status, a session dropped on another takes its column and
                // its place there; it leaves its folder and group alone.
                if TabSidebarSettings.shared.groupBy == .status {
                    if case .tab(let window) = payload, case .tab(let targetWindow?) = target, window !== targetWindow {
                        model.moveOnBoard(window, nextTo: targetWindow, after: after)
                    }
                    return
                }

                switch (payload, target) {
                case (nil, _):
                    return

                case (.tab(let window), .tab(let targetWindow)):
                    guard let targetWindow else { return }
                    model.drop(window, relativeTo: targetWindow, after: after)
                case (.tab(let window), .group(let groupID)):
                    if finalPlacement == .into {
                        model.drop(window, ontoGroup: groupID)
                    } else {
                        model.drop(window, beside: .group(groupID), after: after)
                    }
                case (.tab(let window), .folder(let folderID)):
                    if finalPlacement == .into {
                        model.drop(window, ontoFolder: folderID)
                    } else {
                        model.drop(window, beside: .folder(folderID), after: after)
                    }
                case (.tab(let window), .folderGroup(let groupID)):
                    model.drop(window, beside: .folderGroup(groupID), after: after)
                case (.tab(let window), .end):
                    model.dropAtEnd(window)

                case (.group(let groupID), .tab(let targetWindow)):
                    guard let targetWindow else { return }
                    model.moveGroup(groupID, to: .tab(targetWindow), after: after)
                case (.group(let groupID), .group(let targetID)):
                    model.moveGroup(groupID, to: .group(targetID), after: after)
                case (.group(let groupID), .folder(let folderID)):
                    if finalPlacement == .into {
                        model.drop(group: groupID, ontoFolder: folderID)
                    } else {
                        model.moveGroup(groupID, to: .folder(folderID), after: after)
                    }
                case (.group(let groupID), .folderGroup(let targetID)):
                    model.moveGroup(groupID, to: .folderGroup(targetID), after: after)
                case (.group(let groupID), .end):
                    model.moveGroup(groupID, to: .end, after: false)

                case (.folder(let folderID), .tab(let targetWindow)):
                    guard let targetWindow else { return }
                    model.moveFolder(folderID, to: .tab(targetWindow), after: after)
                case (.folder(let folderID), .group(let targetID)):
                    model.moveFolder(folderID, to: .group(targetID), after: after)
                case (.folder(let folderID), .folder(let targetID)):
                    model.moveFolder(folderID, to: .folder(targetID), after: after)
                case (.folder(let folderID), .folderGroup(let groupID)):
                    if finalPlacement == .into {
                        model.drop(folder: folderID, ontoFolderGroup: groupID)
                    } else {
                        model.moveFolder(folderID, to: .folderGroup(groupID), after: after)
                    }
                case (.folder(let folderID), .end):
                    model.moveFolder(folderID, to: .end, after: false)

                case (.folderGroup(let groupID), .tab(let targetWindow)):
                    guard let targetWindow else { return }
                    model.moveFolderGroup(groupID, to: .tab(targetWindow), after: after)
                case (.folderGroup(let groupID), .group(let targetID)):
                    model.moveFolderGroup(groupID, to: .group(targetID), after: after)
                case (.folderGroup(let groupID), .folder(let targetID)):
                    model.moveFolderGroup(groupID, to: .folder(targetID), after: after)
                case (.folderGroup(let groupID), .folderGroup(let targetID)):
                    model.moveFolderGroup(groupID, to: .folderGroup(targetID), after: after)
                case (.folderGroup(let groupID), .end):
                    model.moveFolderGroup(groupID, to: .end, after: false)
                }
            }
        }

        return true
    }

    /// Opens every directory dropped from the Finder as a folder. Files are ignored.
    private func openDirectories(_ info: DropInfo) -> Bool {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let model = model
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return }
                DispatchQueue.main.async { model.openFolder(at: url) }
            }
        }
        return true
    }

    private func placement(for info: DropInfo) -> TabSidebarDropPlacement {
        let drag = TabSidebarDragState.shared
        switch target {
        case .tab:
            return info.location.y < height / 2 ? .before : .after
        case .group:
            // A tab can go in a group; a group, folder or folder group goes beside it.
            return zone(info, canEnter: !drag.isDraggingBlock)
        case .folder:
            // A tab or group can go in a folder; a folder or folder group goes beside it.
            return zone(info, canEnter: !drag.isDraggingFolderOrGroupOfThem)
        case .folderGroup:
            // Only a folder can go in a folder group.
            return zone(info, canEnter: drag.isDraggingFolderOrGroupOfThem && !drag.isDraggingFolderGroup)
        case .end:
            return .before
        }
    }

    /// How far from a header's top or bottom edge a drop still means beside it rather
    /// than into it.
    private static let edge: CGFloat = 7

    /// A header's zones: between above, over, between below. Without entering, the two
    /// halves are before and after.
    private func zone(_ info: DropInfo, canEnter: Bool) -> TabSidebarDropPlacement {
        let y = info.location.y
        guard canEnter else { return y < height / 2 ? .before : .after }
        if y < Self.edge { return .before }
        if y > height - Self.edge { return .after }
        return .into
    }
}

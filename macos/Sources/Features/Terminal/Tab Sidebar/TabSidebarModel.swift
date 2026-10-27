import AppKit
import Combine
import GhosttyKit

extension Notification.Name {
    /// Posted by a `TerminalWindow` when something shown in the tab sidebar changes
    /// (tab color, group, keyboard shortcut label, zoom state). The object is the window.
    static let terminalTabSidebarItemDidChange = Notification.Name("com.mitchellh.ghostty.tabSidebarItemDidChange")
}

/// The state behind the vertical tab sidebar of a single terminal window.
///
/// Every tab is its own `TerminalWindow` inside a native `NSWindowTabGroup`, and every
/// window hosts its own sidebar. Only the selected tab's window is visible at a time,
/// so each model independently mirrors the native tab group it belongs to. The native
/// tab order is the source of truth, so keyboard shortcuts such as `goto_tab` always
/// match what the sidebar shows.
final class TabSidebarModel: ObservableObject {
    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        weak var window: TerminalWindow?
        let index: Int
        let title: String

        /// The color the tab is shown in (see `TerminalWindow.shownTabColor`).
        let color: TerminalTabColor

        /// The color assigned to the tab, which the color menu shows as selected.
        let assignedColor: TerminalTabColor

        /// For an `auto` tab, what its Claude Code sessions are doing.
        let claudeCodeState: ClaudeCodeTabState?

        /// When its Claude Code sessions changed what they were doing.
        let claudeCodeActivity: ClaudeCodeActivity
        /// Whether the tab offers to read its session's last response aloud, and whether it is.
        let canSpeak: Bool
        let isSpeaking: Bool
        let speechVoiceID: String?
        let keyEquivalent: String?
        let isSelected: Bool
        let isZoomed: Bool

        /// The groups the tab is in, outermost first: its group, and the groups that is
        /// in, inside its folder when it has one.
        let groupPath: [UUID]
        let folderID: UUID?

        /// The groups its folder is in, outermost first.
        let outerGroupPath: [UUID]

        /// Its place on the session board, once moved there.
        var boardPlace: SessionBoardPlace?

        /// The work item it is linked to.
        var workItemID: UUID?

        init(
            id: ObjectIdentifier,
            window: TerminalWindow? = nil,
            index: Int,
            title: String,
            color: TerminalTabColor,
            assignedColor: TerminalTabColor,
            claudeCodeState: ClaudeCodeTabState?,
            claudeCodeActivity: ClaudeCodeActivity,
            canSpeak: Bool,
            isSpeaking: Bool,
            speechVoiceID: String?,
            keyEquivalent: String?,
            isSelected: Bool,
            isZoomed: Bool,
            groupPath: [UUID] = [],
            folderID: UUID? = nil,
            outerGroupPath: [UUID] = [],
            boardPlace: SessionBoardPlace? = nil,
            workItemID: UUID? = nil
        ) {
            self.id = id
            self.window = window
            self.index = index
            self.title = title
            self.color = color
            self.assignedColor = assignedColor
            self.claudeCodeState = claudeCodeState
            self.claudeCodeActivity = claudeCodeActivity
            self.canSpeak = canSpeak
            self.isSpeaking = isSpeaking
            self.speechVoiceID = speechVoiceID
            self.keyEquivalent = keyEquivalent
            self.isSelected = isSelected
            self.isZoomed = isZoomed
            self.groupPath = groupPath
            self.folderID = folderID
            self.outerGroupPath = outerGroupPath
            self.boardPlace = boardPlace
            self.workItemID = workItemID
        }

        /// The group the tab is in directly, if any.
        var groupID: UUID? { groupPath.last }

        /// Every group the tab is in, outermost first: its folder's, then its own.
        var allGroupIDs: [UUID] { outerGroupPath + groupPath }

        /// What the tab is in, outermost first.
        var path: [TabSidebarOrder.Block] {
            outerGroupPath.map(TabSidebarOrder.Block.group)
                + (folderID.map { [TabSidebarOrder.Block.folder($0)] } ?? [])
                + groupPath.map(TabSidebarOrder.Block.group)
        }

        /// The color the row is filled with, which is what the color filter goes by:
        /// `color`, except that a tab colored `attention` is filled only while its
        /// session needs something, and shows none otherwise.
        var fillColor: TerminalTabColor {
            guard assignedColor == .attention else { return color }
            switch claudeCodeState?.light {
            case .waiting, .pending, .unlanded: return color
            case .working, .clean, nil: return .none
            }
        }

        /// Whether the row's color is a pastel tint of what its session is doing, as
        /// against a color picked by hand, which fills it.
        var isTinted: Bool { assignedColor.followsClaudeCode }

        static func == (lhs: Tab, rhs: Tab) -> Bool {
            lhs.id == rhs.id &&
                lhs.index == rhs.index &&
                lhs.title == rhs.title &&
                lhs.color == rhs.color &&
                lhs.assignedColor == rhs.assignedColor &&
                lhs.claudeCodeState == rhs.claudeCodeState &&
                lhs.claudeCodeActivity == rhs.claudeCodeActivity &&
                lhs.canSpeak == rhs.canSpeak &&
                lhs.isSpeaking == rhs.isSpeaking &&
                lhs.speechVoiceID == rhs.speechVoiceID &&
                lhs.keyEquivalent == rhs.keyEquivalent &&
                lhs.isSelected == rhs.isSelected &&
                lhs.isZoomed == rhs.isZoomed &&
                lhs.groupPath == rhs.groupPath &&
                lhs.folderID == rhs.folderID &&
                lhs.outerGroupPath == rhs.outerGroupPath &&
                lhs.boardPlace == rhs.boardPlace &&
                lhs.workItemID == rhs.workItemID
        }
    }

    /// A group with the sessions, groups and folders in it.
    struct GroupSection: Identifiable, Equatable {
        let group: UserTabGroup
        let rows: [Row]

        init(group: UserTabGroup, rows: [Row]) {
            self.group = group
            self.rows = rows
        }

        /// A group of sessions alone.
        init(group: UserTabGroup, tabs: [Tab]) {
            self.init(group: group, rows: tabs.map(Row.tab))
        }

        /// A group's members are kept contiguous, but until that is enforced the same
        /// group can briefly appear twice, so the id includes the first tab index.
        var id: String { "\(group.id)-\(tabs.first?.index ?? -1)" }

        /// Every session in the group, those of the groups and folders in it too.
        var tabs: [Tab] { rows.flatMap(\.allTabs) }

        /// Every folder in the group, those of the groups in it too.
        var folders: [FolderSection] { rows.flatMap(\.allFolders) }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }

        /// What the members' Claude Code sessions are doing, shown on the header while
        /// the group is collapsed: the one that needs attention most.
        var claudeCodeLight: ClaudeCodeLight? {
            ClaudeCodeLight.mostUrgent(tabs.compactMap { $0.claudeCodeState?.light })
        }

        /// A member finished a request that hasn't been looked at.
        var hasFinishedUnseen: Bool { tabs.contains { $0.claudeCodeActivity.finishedUnseen } }
    }

    /// A folder with the sessions and groups in it. A folder can have none.
    struct FolderSection: Identifiable, Equatable {
        let folder: UserTabFolder

        /// Sessions and groups only; folders don't nest.
        let rows: [Row]

        /// Like a group's, in case a folder briefly shows twice.
        var id: String { "\(folder.id)-\(tabs.first?.index ?? -1)" }

        var tabs: [Tab] { rows.flatMap(\.allTabs) }

        var containsSelectedTab: Bool { tabs.contains(where: \.isSelected) }

        var claudeCodeLight: ClaudeCodeLight? {
            ClaudeCodeLight.mostUrgent(tabs.compactMap { $0.claudeCodeState?.light })
        }

        var hasFinishedUnseen: Bool { tabs.contains { $0.claudeCodeActivity.finishedUnseen } }
    }

    enum Row: Identifiable, Equatable {
        case tab(Tab)
        case group(GroupSection)
        case folder(FolderSection)

        var id: String {
            switch self {
            case .tab(let tab): return "tab-\(tab.id.hashValue)"
            case .group(let section): return "group-\(section.id)"
            case .folder(let section): return "folder-\(section.id)"
            }
        }

        /// Every session in the row, shown or collapsed away.
        var allTabs: [Tab] {
            switch self {
            case .tab(let tab): return [tab]
            case .group(let section): return section.tabs
            case .folder(let section): return section.tabs
            }
        }

        /// Every folder the row is or holds.
        var allFolders: [FolderSection] {
            switch self {
            case .tab: return []
            case .group(let section): return section.folders
            case .folder(let section): return [section]
            }
        }
    }

    /// The rows to display: in native tab order, then the folders with no sessions in
    /// the order they were opened, each in its group where that group shows.
    @Published private(set) var rows: [Row] = []

    /// True when this window shows the sidebar instead of the native tab bar. This is
    /// set by the window.
    @Published var isActive: Bool = false {
        didSet {
            guard isActive != oldValue else { return }
            setNeedsRefresh()
        }
    }

    /// The color to paint the titlebar area above the terminal when the sidebar is active,
    /// since the titlebar itself is made transparent so the sidebar can extend under it.
    @Published var titlebarColor: NSColor?

    /// The modifiers of the `goto_tab` shortcuts. The shortcut labels show while exactly
    /// these are held.
    @Published private(set) var jumpModifiers: NSEvent.ModifierFlags?

    /// Where each tab's sessions work, by tab id. Read after the rows, so it can lag them.
    @Published private(set) var infos: [ObjectIdentifier: TabSidebarSessionInfo] = [:]

    /// The height of the titlebar that the sidebar and terminal content extend under.
    @Published var titlebarHeight: CGFloat = 0

    /// Whether the session board covers the terminal. While it does, the window doesn't
    /// show the title of the session underneath.
    @Published var isBoardOpen = false {
        didSet {
            guard isBoardOpen != oldValue else { return }
            hostWindow?.hidesTitleForBoard(isBoardOpen)
        }
    }

    /// What the sidebar and the board show: the window's one filter, so it holds from
    /// tab to tab, the board opens on what the sidebar lists, and what is picked on the
    /// board narrows the sidebar when it closes. Another window keeps a filter of its
    /// own, since it shows other sessions. A session that stops matching goes from the
    /// sidebar as it changes, and one that comes to match appears, since the rows are
    /// refreshed on each change and narrowed by the filter as they are read.
    var boardFilter: SessionBoardFilter {
        get { hostWindow.map { filterStore[$0.folderSpace.id] } ?? SessionBoardFilter() }
        set {
            guard let hostWindow else { return }
            filterStore[hostWindow.folderSpace.id] = newValue
        }
    }

    private let filterStore: SessionBoardFilterStore

    /// Whether the filter leaves some sessions out.
    var isFiltering: Bool { boardFilter.isActive }

    /// Goes up each time the selected session is to be scrolled into view.
    @Published private(set) var revealRequest = 0

    /// The session the sidebar scrolls to on `revealRequest`.
    var selectedTabID: ObjectIdentifier? {
        rows.lazy.flatMap(\.allTabs).first(where: \.isSelected)?.id
    }

    /// Unfolds whatever holds the selected session and scrolls the sidebar to it. A
    /// search, and then a filter, that hides it is cleared.
    func revealSelected() {
        guard let tab = rows.lazy.flatMap(\.allTabs).first(where: \.isSelected) else { return }
        func isHidden() -> Bool { !shownRows.flatMap(\.allTabs).contains(where: { $0.id == tab.id }) }
        if isSearching, isHidden() {
            searchQuery = ""
        }
        if isFiltering, isHidden() {
            boardFilter = SessionBoardFilter()
        }
        for groupID in tab.allGroupIDs {
            UserTabGroupStore.shared.update(groupID) { $0.isCollapsed = false }
        }
        if let folderID = tab.folderID {
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        }
        TabSidebarSettings.shared.collapsedStatuses.remove(SessionBoardSettings.shared.column(for: tab.boardPlace?.column))
        revealRequest += 1
    }

    /// The tab currently being renamed inline, if any.
    @Published var editingTabID: ObjectIdentifier?

    /// The group currently being renamed inline, if any.
    @Published var editingGroupID: UUID?

    /// The folder currently being renamed inline, if any.
    @Published var editingFolderID: UUID?

    /// Whether the window is being named inline.
    @Published var isEditingWindowName = false

    /// The text typed so far while renaming a tab, group, folder or the window inline.
    @Published var editingDraft = ""

    /// What the window is called, shared by its tabs.
    @Published private(set) var windowName: String?

    /// Whether another window has a sidebar too, which is when a name tells them apart.
    @Published private(set) var hasOtherWindows = false

    /// What is typed in the search field. The sidebar shows only the sessions matching it.
    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { searchHighlight = nil } }
    }

    /// The session the arrow keys moved to while searching, which Return opens. Nil for
    /// the first match.
    @Published private(set) var searchHighlight: ObjectIdentifier?

    /// Changed to put the keyboard in the search field.
    @Published private(set) var searchFocusRequest = 0

    private weak var hostWindow: TerminalWindow?

    /// The window showing this sidebar.
    var window: TerminalWindow? { hostWindow }
    private weak var observedTabGroup: NSWindowTabGroup?
    private var tabGroupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var refreshScheduled = false
    private let infoReader = TabSidebarSessionInfoReader()
    private var infoReadScheduled = false
    private var infoTimer: Timer?

    /// How often the info is read again while the sidebar shows, to catch a branch
    /// switched in the shell.
    private static let infoInterval: TimeInterval = 10

    /// `filterStore` is the app's, but for a test's.
    init(hostWindow: TerminalWindow, filterStore: SessionBoardFilterStore = .shared) {
        self.hostWindow = hostWindow
        self.filterStore = filterStore

        // The filter is read through this model, so a change to it is a change to this.
        filterStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: .terminalTabSidebarItemDidChange),
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification)
        )
        .sink { [weak self] _ in self?.setNeedsRefresh() }
        .store(in: &cancellables)

        UserTabGroupStore.shared.$groups
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)

        UserTabFolderStore.shared.$folders
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
    }

    deinit {
        infoTimer?.invalidate()
        tabGroupObservations.forEach { $0.invalidate() }
        titleObservations.values.forEach { $0.invalidate() }
    }

    // MARK: Refresh

    /// Coalesces refreshes to once per main loop turn. This also means we never mutate
    /// KVO observations from inside a KVO callback, which AppKit does not like.
    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Refreshes right away instead of on the next main loop turn. A window that is
    /// about to be shown for the first time uses this so its first frame already lists
    /// the tabs instead of showing an empty sidebar that fills in a moment later.
    func refreshNow() {
        refresh()
    }

    private func refresh() {
        refreshScheduled = false

        guard isActive, let hostWindow else {
            rebindTabGroup(nil)
            rebindTitles([])
            if !rows.isEmpty { rows = [] }
            stopReadingInfo()
            return
        }

        let tabGroup = hostWindow.tabGroup
        rebindTabGroup(tabGroup)

        let windows = tabWindows
        rebindTitles(windows)
        unifyFolderSpace(windows)

        let selected = tabGroup?.selectedWindow ?? hostWindow
        let newRows = Self.rows(of: windows, selected: selected, folderIDs: hostWindow.folderSpace.folderIDs)
        if newRows != rows { rows = newRows }

        let name = hostWindow.folderSpace.name
        if name != windowName { windowName = name }
        let others = !otherWindows.isEmpty
        if others != hasOtherWindows { hasOtherWindows = others }

        // Refreshes run on the main loop.
        let jump = MainActor.assumeIsolated {
            hostWindow.terminalController?.ghostty.config.keyboardShortcut(for: "goto_tab:1")
                .map { NSEvent.ModifierFlags(swiftUIFlags: $0.modifiers) }
        }
        if jump != jumpModifiers { jumpModifiers = jump }

        // Only the sidebar that shows reads the info, since every tab's window has one.
        if selected === hostWindow {
            scheduleInfoRead()
        } else {
            stopReadingInfo()
        }

        // If the tab order was changed outside of the sidebar (e.g. "Merge All Windows"
        // or a move_tab keybind), a group or folder can end up split. Put it back
        // together. Only the selected window does this so the windows in a tab group
        // don't all race.
        if selected === hostWindow {
            var ids: [UUID] = []
            func collect(_ rows: [Row]) {
                for row in rows {
                    switch row {
                    case .tab: break
                    case .group(let section):
                        ids.append(section.group.id)
                        collect(section.rows)
                    case .folder(let section):
                        ids.append(section.folder.id)
                        collect(section.rows)
                    }
                }
            }
            collect(newRows)
            if Set(ids).count != ids.count {
                DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
            }
        }
    }

    /// What a tab's window is in, by the stores: the groups its folder is in, its
    /// folder, and its own groups. Only what the stores know nests, except that with
    /// `raw` a group or folder the stores don't know still counts, on its own. A group
    /// of the tab's own that its folder is in too would put the tab in the group twice,
    /// so then the tab counts as in the folder alone.
    private static func place(of window: TerminalWindow, raw: Bool) -> (outer: [UUID], folderID: UUID?, inner: [UUID]) {
        let groups = UserTabGroupStore.shared
        let folders = UserTabFolderStore.shared
        func known(_ path: [UUID], or id: UUID?) -> [UUID] {
            raw && path.isEmpty ? (id.map { [$0] } ?? []) : path
        }
        let folderID = raw ? window.userTabFolderID : folders[window.userTabFolderID]?.id
        let outerGroupID = folders[folderID]?.groupID
        let outer = known(groups.path(of: outerGroupID), or: outerGroupID)
        var inner = known(groups.path(of: window.userTabGroupID), or: window.userTabGroupID)
        if inner.contains(where: outer.contains) { inner = [] }
        return (outer, folderID, inner)
    }

    /// The rows for the tab windows of one native tab group, in tab order, then the
    /// folders in `folderIDs` that have no sessions, each in its group where that group
    /// shows. The mobile companion builds them too, sidebar shown or not.
    static func rows(of windows: [TerminalWindow], selected: NSWindow?, folderIDs: [UUID]) -> [Row] {
        let folders = UserTabFolderStore.shared
        let groups = UserTabGroupStore.shared
        let tabs = windows.enumerated().map { index, window in
            let place = place(of: window, raw: false)
            return Tab(
                id: ObjectIdentifier(window),
                window: window,
                index: index,
                title: window.sessionTitle ?? window.title,
                color: window.shownTabColor,
                assignedColor: window.tabColor,
                claudeCodeState: window.claudeCodeState,
                claudeCodeActivity: window.claudeCodeActivity,
                canSpeak: window.canSpeakClaudeCodeResponse,
                isSpeaking: window.isSpeakingClaudeCodeResponse,
                speechVoiceID: window.speechVoiceID,
                keyEquivalent: window.keyEquivalent.flatMap { $0.isEmpty ? nil : $0 },
                isSelected: window === selected,
                isZoomed: window.surfaceIsZoomed,
                groupPath: place.inner,
                folderID: place.folderID,
                outerGroupPath: place.outer,
                boardPlace: window.boardPlace,
                workItemID: window.workItemID)
        }

        var newRows = Self.rows(of: tabs[...], depth: 0)

        // Folders with no sessions have no place in the tab order, so they come last,
        // except that one in a group that shows goes in with the group, in the groups
        // between where they show.
        let shownFolders = Set(newRows.flatMap(\.allFolders).map(\.folder.id))
        for id in folderIDs where !shownFolders.contains(id) {
            guard let folder = folders[id] else { continue }
            let chain = groups.path(of: folder.groupID).compactMap { groups[$0] }
            Self.insert(FolderSection(folder: folder, rows: []), into: &newRows, through: chain[...])
        }
        return newRows
    }

    /// Puts a folder with no sessions in `rows`, in the last group row showing the first
    /// of `chain` when there is one, and then in there down the chain; where a group of
    /// the chain doesn't show, it is added with the rest of the chain inside it.
    private static func insert(_ section: FolderSection, into rows: inout [Row], through chain: ArraySlice<UserTabGroup>) {
        guard let group = chain.first else {
            rows.append(.folder(section))
            return
        }
        if let index = rows.lastIndex(where: {
            if case .group(let shown) = $0 { return shown.group.id == group.id }
            return false
        }), case .group(let shown) = rows[index] {
            var inner = shown.rows
            insert(section, into: &inner, through: chain.dropFirst())
            rows[index] = .group(.init(group: shown.group, rows: inner))
        } else {
            var inner: [Row] = []
            insert(section, into: &inner, through: chain.dropFirst())
            rows.append(.group(.init(group: group, rows: inner)))
        }
    }

    /// The rows for `tabs`, nesting from `depth` of their paths in: runs of tabs in the
    /// same block become one row each, with the rows of the runs inside it. A tab in
    /// nothing at this depth is a row of its own.
    private static func rows(of tabs: ArraySlice<Tab>, depth: Int) -> [Row] {
        func block(_ tab: Tab) -> TabSidebarOrder.Block? {
            let path = tab.path
            return path.count > depth ? path[depth] : nil
        }

        var result: [Row] = []
        var i = tabs.startIndex
        while i < tabs.endIndex {
            let key = block(tabs[i])
            var j = i + 1
            while j < tabs.endIndex, block(tabs[j]) == key { j += 1 }
            let run = tabs[i..<j]
            i = j

            guard let key else {
                result.append(contentsOf: run.map(Row.tab))
                continue
            }
            let inner = rows(of: run, depth: depth + 1)

            // Only blocks the stores know are in a path, so the lookups don't fail.
            switch key.kind {
            case .folder:
                guard let folder = UserTabFolderStore.shared[key.id] else { continue }
                result.append(.folder(.init(folder: folder, rows: inner)))
            case .group:
                guard let group = UserTabGroupStore.shared[key.id] else { continue }
                result.append(.group(.init(group: group, rows: inner)))
            }
        }
        return result
    }

    /// Points every tab's window at one set of folders: the first tab's, with the folders
    /// of the others added. A tab that joined the tab group with folders of its own
    /// brings them along, and restored tabs each come with a copy of the same folders.
    private func unifyFolderSpace(_ windows: [TerminalWindow]) {
        guard let space = windows.first?.folderSpace else { return }
        let store = UserTabFolderStore.shared
        for window in windows.dropFirst() where window.folderSpace !== space {
            window.folderSpace.folderIDs.forEach { space.add($0) }
            if space.name == nil { space.name = window.folderSpace.name }
            window.folderSpace = space
        }
        for window in windows {
            if let id = window.userTabFolderID {
                if store[id] != nil { space.add(id) } else { window.userTabFolderID = nil }
            }
        }
        space.folderIDs.removeAll { store[$0] == nil }
    }

    // MARK: Search

    var isSearching: Bool { !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty }

    /// The rows to show: all of them, or those the filter shows that match the search.
    var shownRows: [Row] {
        TabSidebarSearch.filter(TabSidebarFilter.filter(rows, by: boardFilter), query: searchQuery, infos: infos)
    }

    /// Whether a search or a filter leaves sessions out.
    var isNarrowed: Bool { isSearching || isFiltering }

    /// The session Return opens while searching.
    var highlightedTab: Tab? {
        guard isSearching else { return nil }
        let tabs = TabSidebarSearch.tabs(in: shownRows)
        return tabs.first { $0.id == searchHighlight } ?? tabs.first
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    /// Moves the highlight `offset` matches down, or up when negative.
    func moveSearchHighlight(by offset: Int) {
        let tabs = TabSidebarSearch.tabs(in: shownRows)
        guard !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == highlightedTab?.id } ?? 0
        searchHighlight = tabs[min(max(current + offset, 0), tabs.count - 1)].id
    }

    /// Opens the highlighted session and ends the search.
    func openSearchHighlight() {
        guard let window = highlightedTab?.window else { return }
        searchQuery = ""
        select(window)
        focusTerminal(of: window)
    }

    /// Clears the search and gives the keyboard back to the terminal.
    func endSearch() {
        searchQuery = ""
        if let hostWindow { focusTerminal(of: hostWindow) }
    }

    private func focusTerminal(of window: TerminalWindow) {
        guard let surface = window.terminalController?.focusedSurface else { return }
        window.makeFirstResponder(surface)
    }

    // MARK: Info

    private func scheduleInfoRead() {
        if infoTimer == nil {
            infoTimer = Timer.scheduledTimer(withTimeInterval: Self.infoInterval, repeats: true) { [weak self] _ in
                self?.scheduleInfoRead()
            }
            infoTimer?.tolerance = 2
        }

        guard !infoReadScheduled else { return }
        infoReadScheduled = true
        // Refreshes come in bursts; read once they settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.readInfo()
        }
    }

    private func stopReadingInfo() {
        infoTimer?.invalidate()
        infoTimer = nil
    }

    private func readInfo() {
        infoReadScheduled = false
        guard isActive else { return }

        // Reads run on the main loop.
        let requests = MainActor.assumeIsolated {
            tabWindows.map { window in
                let controller = window.terminalController
                let surfaces = controller?.surfaceTree.root?.leaves() ?? []
                return TabSidebarSessionInfoReader.Request(
                    id: ObjectIdentifier(window),
                    pids: surfaces.compactMap { $0.surfaceModel?.foregroundPID },
                    directory: controller?.focusedSurface?.pwd)
            }
        }
        infoReader.read(requests) { [weak self] infos in
            guard let self, infos != self.infos else { return }
            self.infos = infos
        }
    }

    private func rebindTabGroup(_ tabGroup: NSWindowTabGroup?) {
        guard observedTabGroup !== tabGroup || (tabGroup != nil && tabGroupObservations.isEmpty) else { return }
        tabGroupObservations.forEach { $0.invalidate() }
        tabGroupObservations = []
        observedTabGroup = tabGroup
        guard let tabGroup else { return }

        tabGroupObservations = [
            tabGroup.observe(\.windows, options: []) { [weak self] _, _ in self?.setNeedsRefresh() },
            tabGroup.observe(\.selectedWindow, options: []) { [weak self] _, _ in self?.setNeedsRefresh() },
        ]
    }

    private func rebindTitles(_ windows: [TerminalWindow]) {
        let ids = Set(windows.map(ObjectIdentifier.init))
        for (id, observation) in titleObservations where !ids.contains(id) {
            observation.invalidate()
            titleObservations[id] = nil
        }

        for window in windows where titleObservations[ObjectIdentifier(window)] == nil {
            titleObservations[ObjectIdentifier(window)] = window.observe(\.title, options: []) { [weak self] _, _ in
                self?.setNeedsRefresh()
            }
        }
    }

    // MARK: Queries

    /// The terminal windows in this window's native tab group, in tab order.
    private var tabWindows: [TerminalWindow] {
        guard let hostWindow else { return [] }
        guard let windows = hostWindow.tabGroup?.windows else { return [hostWindow] }
        return windows.compactMap { $0 as? TerminalWindow }
    }

    /// The groups with tabs or folders in this window, the groups those are in too, in
    /// the order the sidebar shows them.
    var groupsInWindow: [UserTabGroup] {
        let store = UserTabGroupStore.shared
        var seen = Set<UUID>()
        func collect(_ ids: [UUID]) -> [UserTabGroup] {
            ids.compactMap { id in
                guard seen.insert(id).inserted else { return nil }
                return store[id]
            }
        }
        return tabWindows.flatMap { collect(Entry(window: $0).path.groupIDs) }
            + foldersInWindow.flatMap { collect(store.path(of: $0.groupID)) }
    }

    /// The groups in this window that a folder can go in: those in no folder.
    var groupsForFoldersInWindow: [UserTabGroup] {
        groupsInWindow.filter { !isInsideFolder(group: $0.id) }
    }

    /// The folders open in this window, in the order they were opened.
    var foldersInWindow: [UserTabFolder] {
        hostWindow?.folderSpace.folderIDs.compactMap { UserTabFolderStore.shared[$0] } ?? []
    }

    /// The tabs in the group: those in it and the groups inside it, and those in its
    /// folders.
    private func members(of groupID: UUID) -> [TerminalWindow] {
        let block = TabSidebarOrder.Block.group(groupID)
        return tabWindows.filter { Entry(window: $0).path.contains(block) }
    }

    /// The tabs in the group by their own group: those not reached through a folder,
    /// which take the group's folder.
    private func innerMembers(of groupID: UUID) -> [TerminalWindow] {
        let store = UserTabGroupStore.shared
        return tabWindows.filter { store.isGroup($0.userTabGroupID, within: groupID) }
    }

    private func members(ofFolder folderID: UUID) -> [TerminalWindow] {
        tabWindows.filter { $0.userTabFolderID == folderID }
    }

    /// The folder a group is in: its first member's, by the member's own group. A group
    /// reached only through its folders is in none.
    func folder(ofGroup groupID: UUID) -> UUID? {
        innerMembers(of: groupID).first?.userTabFolderID
    }

    /// Whether the group is in a folder, which is when it can't hold folders.
    func isInsideFolder(group groupID: UUID) -> Bool {
        folder(ofGroup: groupID) != nil
    }

    /// Whether the group holds a folder, in it or in a group inside it, which is when it
    /// can't go in a folder.
    func holdsFolders(group groupID: UUID) -> Bool {
        let store = UserTabGroupStore.shared
        return foldersInWindow.contains { store.isGroup($0.groupID, within: groupID) }
    }

    /// The folders in the group, those in the groups inside it too, in this window.
    private func folders(inGroup groupID: UUID) -> [UserTabFolder] {
        let store = UserTabGroupStore.shared
        return foldersInWindow.filter { store.isGroup($0.groupID, within: groupID) }
    }

    /// The group the group is in, if any.
    func parent(ofGroup groupID: UUID) -> UUID? {
        UserTabGroupStore.shared[groupID]?.parentID
    }

    /// The outermost of a tab's own groups, which is what moves with it between folders.
    private func rootGroup(of window: TerminalWindow) -> UUID? {
        UserTabGroupStore.shared.path(of: window.userTabGroupID).first
    }

    /// The group as `TabSidebarOrder` drops it: one that holds folders stays outside them.
    private func dropped(group groupID: UUID) -> TabSidebarOrder.Dropped {
        holdsFolders(group: groupID) ? .groupOfFolders : .group
    }

    // MARK: Tab Actions

    func select(_ window: TerminalWindow) {
        commitEditing()
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ window: TerminalWindow) {
        guard let controller = window.terminalController else { return }

        // A confirmation sheet can only be shown on a visible window, so bring the tab
        // forward first if closing it will need one.
        if window !== hostWindow?.tabGroup?.selectedWindow,
           controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { controller.closeTab(nil) }
            return
        }

        controller.closeTab(nil)
    }

    func closeOthers(_ window: TerminalWindow) {
        window.terminalController?.closeOtherTabs(nil)
    }

    func closeBelow(_ window: TerminalWindow) {
        window.terminalController?.closeTabsOnTheRight(nil)
    }

    func moveToNewWindow(_ window: TerminalWindow) {
        window.moveTabToNewWindow(nil)
    }

    func beginRename(_ window: TerminalWindow) {
        commitEditing()
        editingDraft = window.terminalController?.renameDraft ?? window.title
        editingTabID = ObjectIdentifier(window)
    }

    func setColor(_ color: TerminalTabColor, for window: TerminalWindow) {
        window.pickTabColor(color)
    }

    /// Opens a new tab. With a group, the tab is added to the end of that group, in the
    /// group's folder; with a folder, to the end of that folder; otherwise it is added to
    /// the end of the tab list in neither. The new tab inherits the working directory of
    /// a terminal in that group, so it opens in the group's project even when the
    /// selected tab belongs to another group. Without a group, it inherits from this
    /// window's focused terminal. In a folder, it starts in the folder's directory
    /// whatever it would inherit. With `configuration`, its directory, input and
    /// environment override all of that: a pivot starts another agent in a session's
    /// own directory. Returns the new tab's window.
    @discardableResult
    func newTab(
        inGroup groupID: UUID? = nil,
        inFolder: UUID? = nil,
        configuration: Ghostty.SurfaceConfiguration? = nil
    ) -> TerminalWindow? {
        guard let hostWindow,
              let hostController = hostWindow.terminalController else { return nil }

        // Named apart from `folder(ofGroup:)`: a local `folder` next to that call reads
        // as a circular reference to Xcode 26's compiler.
        let folderID = groupID.flatMap { self.folder(ofGroup: $0) } ?? (groupID == nil ? inFolder : nil)
        let tabFolder = UserTabFolderStore.shared[folderID]

        let anchor: NSWindow
        var source: TerminalWindow = hostWindow
        if let groupID, let last = members(of: groupID).last {
            anchor = last
            if let selected = hostWindow.tabGroup?.selectedWindow as? TerminalWindow,
               Entry(window: selected).path.contains(.group(groupID)) {
                source = selected
            } else {
                source = last
            }
        } else if let folderID, let last = members(ofFolder: folderID).last {
            anchor = last
            source = last
        } else {
            anchor = tabWindows.last ?? hostWindow
        }

        var baseConfig: Ghostty.SurfaceConfiguration?
        if let surface = source.terminalController?.focusedSurface?.surface {
            baseConfig = .init(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_TAB))
        }
        if let tabFolder {
            var config = baseConfig ?? Ghostty.SurfaceConfiguration()
            config.workingDirectory = tabFolder.path
            baseConfig = config
        }
        if let configuration {
            var config = baseConfig ?? Ghostty.SurfaceConfiguration()
            config.workingDirectory = configuration.workingDirectory ?? config.workingDirectory
            config.initialInput = configuration.initialInput
            config.environmentVariables.merge(configuration.environmentVariables) { _, new in new }
            baseConfig = config
        }

        guard let controller = TerminalController.newTab(
            hostController.ghostty,
            from: anchor,
            withBaseConfig: baseConfig,
            // The anchor of a folder with no sessions is another folder's tab, whose
            // directory must not replace this folder's.
            inheritsPlace: false),
              let window = controller.window as? TerminalWindow else { return nil }

        window.userTabGroupID = groupID
        window.userTabFolderID = tabFolder?.id
        if let groupID {
            expand(groupTree: groupID)
        }
        if let tabFolder {
            UserTabFolderStore.shared.update(tabFolder.id) { $0.isCollapsed = false }
        }

        // The group changed after the new tab was prepared, so the sidebar it shows
        // first would still list it under the old group.
        window.prepareTabSidebarForDisplay()

        // The tab group takes a main loop turn to settle after adding a tab.
        DispatchQueue.main.async { [weak self] in self?.normalizeOrder() }
        return window
    }

    /// Unfolds the group and the groups it is in, so what was put in it shows.
    private func expand(groupTree groupID: UUID) {
        for id in UserTabGroupStore.shared.path(of: groupID) {
            UserTabGroupStore.shared.update(id) { $0.isCollapsed = false }
        }
    }

    // MARK: Pivoting

    /// The handoff each pivoted session started from, so a session pivoted again
    /// carries the whole chain with it, not just its own part.
    private var handoffs: [ObjectIdentifier: URL] = [:]

    /// Opens a new session of `agent` beside `window`, in the same group and in the
    /// directory of `window`'s session, which is its worktree when it has one, so the
    /// files carry over. With `carryingConversation`, the session's conversation is
    /// written out and the new agent starts by reading it. The old session stays.
    func pivot(_ window: TerminalWindow, to agent: CodingAgent, carryingConversation: Bool) {
        let info = infos[ObjectIdentifier(window)]
        let session = info?.sessions.first
        let directory = session?.cwd ?? info?.directory
            ?? window.terminalController?.focusedSurface?.pwd

        var prompt: String?
        if carryingConversation, let session, let transcript = session.transcript {
            let earlier = handoffs[ObjectIdentifier(window)].flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            let entries = AgentHandoff.entries(inTranscript: transcript, of: session.agent)
            let markdown = AgentHandoff.markdown(entries: entries, from: session.agent, to: agent, earlier: earlier)
            do {
                let handoff = try AgentHandoff.write(markdown, from: session.agent, session: session.id)
                prompt = AgentHandoff.prompt(from: session.agent, handoff: handoff)
                pendingHandoff = handoff
            } catch {
                Self.showPivotFailure(error, in: window)
                return
            }
        }

        var config = Ghostty.SurfaceConfiguration()
        config.workingDirectory = directory
        config.initialInput = AgentHandoff.command(for: agent, prompt: prompt) + "\n"
        config.environmentVariables = [
            AgentStart.environmentVariable: "1",
            AgentStart.agentEnvironmentVariable: agent.rawValue,
        ]
        let opened = newTab(inGroup: window.userTabGroupID, inFolder: window.userTabFolderID, configuration: config)
        if let opened, let handoff = pendingHandoff {
            handoffs[ObjectIdentifier(opened)] = handoff
        }
        pendingHandoff = nil
    }

    private var pendingHandoff: URL?

    private static func showPivotFailure(_ error: Error, in window: NSWindow) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The conversation couldn't be written out"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    // MARK: Folder Actions

    /// Opens a directory as a folder in this window's sidebar, with no sessions yet.
    /// Returns the folder's id.
    @discardableResult
    func openFolder(at url: URL) -> UUID? {
        guard let hostWindow else { return nil }
        let folder = UserTabFolderStore.shared.create(path: url.path)
        hostWindow.folderSpace.add(folder.id)
        hostWindow.invalidateRestorableState()
        hostWindow.postTabSidebarItemDidChange()
        return folder.id
    }

    /// Asks for directories to open as folders.
    func presentOpenFolderPanel() {
        presentOpenFolderPanel { [weak self] urls in
            urls.forEach { self?.openFolder(at: $0) }
        }
    }

    /// Asks for directories to open as folders in the group.
    func presentOpenFolderPanel(inGroup groupID: UUID) {
        guard !isInsideFolder(group: groupID) else { return }
        presentOpenFolderPanel { [weak self] urls in
            for url in urls {
                guard let folderID = self?.openFolder(at: url) else { continue }
                UserTabFolderStore.shared.update(folderID) { $0.groupID = groupID }
            }
            self?.expand(groupTree: groupID)
            self?.normalizeOrder()
        }
    }

    private func presentOpenFolderPanel(_ open: @escaping ([URL]) -> Void) {
        guard let hostWindow else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        panel.message = "Choose a folder to open sessions in"
        panel.beginSheetModal(for: hostWindow) { response in
            guard response == .OK else { return }
            open(panel.urls)
        }
    }

    func add(_ window: TerminalWindow, toFolder folderID: UUID) {
        // A grouped session takes its group along, with the groups that is in.
        if let groupID = rootGroup(of: window) {
            add(group: groupID, toFolder: folderID)
            return
        }
        window.userTabFolderID = folderID
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    func removeFromFolder(_ window: TerminalWindow) {
        if let groupID = rootGroup(of: window) {
            removeGroupFromFolder(groupID)
            return
        }
        window.userTabFolderID = nil
        normalizeOrder()
    }

    /// Puts the group in the folder, out of any group it was in, since that stays where
    /// it is. Not a group with folders in it, which stays outside folders.
    func add(group groupID: UUID, toFolder folderID: UUID) {
        guard !holdsFolders(group: groupID) else { return }
        UserTabGroupStore.shared.update(groupID) { $0.parentID = nil }
        for window in innerMembers(of: groupID) {
            window.userTabFolderID = folderID
        }
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        normalizeOrder()
    }

    /// Takes the group out of its folder, and out of any group it was in.
    func removeGroupFromFolder(_ groupID: UUID) {
        UserTabGroupStore.shared.update(groupID) { $0.parentID = nil }
        for window in innerMembers(of: groupID) {
            window.userTabFolderID = nil
        }
        normalizeOrder()
    }

    /// Opens a new session in the folder and puts it in a new group, then starts
    /// renaming the group. A group can't be empty.
    func createGroup(inFolder folderID: UUID) {
        guard let window = newTab(inFolder: folderID) else { return }
        createGroup(with: window)
    }

    func beginRename(folder folderID: UUID) {
        commitEditing()
        editingDraft = UserTabFolderStore.shared[folderID]?.name ?? ""
        editingFolderID = folderID
    }

    func toggleCollapsed(folder folderID: UUID) {
        UserTabFolderStore.shared.update(folderID) { $0.isCollapsed.toggle() }
    }

    func revealInFinder(folder folderID: UUID) {
        guard let folder = UserTabFolderStore.shared[folderID] else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder.url])
    }

    /// Takes the folder out of the sidebar. Its sessions stay, outside any folder.
    func removeFolder(_ folderID: UUID) {
        guard let hostWindow else { return }
        for window in members(ofFolder: folderID) {
            window.userTabFolderID = nil
        }
        Self.forget([folderID], in: hostWindow.folderSpace)
    }

    /// Takes folders out of a sidebar's folders and the registry, and has the sidebar
    /// redraw. The windows showing them are found through the space, since the one that
    /// asked may be closing.
    private static func forget(_ folderIDs: [UUID], in space: TabSidebarFolderSpace) {
        let store = UserTabFolderStore.shared
        for folderID in folderIDs {
            space.remove(folderID)
            store.remove(folderID)
        }
        for case let window as TerminalWindow in NSApp.windows where window.folderSpace === space {
            window.invalidateRestorableState()
            window.postTabSidebarItemDidChange()
        }
    }

    /// Closes the folder's sessions, then takes the folder out of the sidebar.
    func closeFolder(_ folderID: UUID) {
        close(
            windows: members(ofFolder: folderID),
            folders: [folderID],
            actionName: "Close Folder",
            messageText: "Close Folder?",
            informativeText: "At least one session in this folder still has a running process. If you close the folder the processes will be killed.")
    }

    /// Closes the sessions of `windows`, confirming when one has a running process,
    /// then takes `folders` out of the sidebar.
    private func close(windows: [TerminalWindow], folders folderIDs: [UUID], actionName: String, messageText: String, informativeText: String) {
        guard let hostWindow, let hostController = hostWindow.terminalController else { return }
        let controllers = windows.compactMap(\.terminalController)
        let space = hostWindow.folderSpace
        guard !controllers.isEmpty else {
            Self.forget(folderIDs, in: space)
            return
        }

        let closeAll = {
            hostController.undoManager?.beginUndoGrouping()
            defer {
                hostController.undoManager?.setActionName(actionName)
                hostController.undoManager?.endUndoGrouping()
            }

            TerminalWorkspace.shared.closeWindows {
                for controller in controllers {
                    controller.closeTabImmediately(registerRedo: false)
                }
            }
            Self.forget(folderIDs, in: space)
        }

        let needsConfirm = controllers.contains { controller in
            controller.surfaceTree.contains(where: { $0.needsConfirmQuit })
        }
        guard needsConfirm else {
            closeAll()
            return
        }

        hostController.confirmClose(messageText: messageText, informativeText: informativeText) {
            closeAll()
        }
    }

    /// Creates a new group containing the given folder, where the folder is, and starts
    /// renaming it.
    func createGroup(withFolder folderID: UUID) {
        let store = UserTabGroupStore.shared
        let group = store.create(name: store.nextDefaultName(), parentID: UserTabFolderStore.shared[folderID]?.groupID)
        UserTabFolderStore.shared.update(folderID) { $0.groupID = group.id }
        normalizeOrder()
        beginRename(group: group.id)
    }

    /// Puts the folder in the group, at its end. Not in a group that is in a folder.
    func add(folder folderID: UUID, toGroup groupID: UUID) {
        guard !isInsideFolder(group: groupID) else { return }
        UserTabFolderStore.shared.update(folderID) { $0.groupID = groupID }
        expand(groupTree: groupID)
        normalizeOrder()
    }

    /// Takes the folder out of its group, into the one that is in, if any.
    func removeFolderFromGroup(_ folderID: UUID) {
        let store = UserTabGroupStore.shared
        guard let groupID = UserTabFolderStore.shared[folderID]?.groupID else { return }
        UserTabFolderStore.shared.update(folderID) { $0.groupID = store[groupID]?.parentID }
        normalizeOrder()
    }

    // MARK: Group Actions

    /// Creates a new group containing the given tab and starts renaming it. A tab that
    /// was in a group stays in it: the new group is made inside that one, so the tab
    /// stays where it was.
    func createGroup(with window: TerminalWindow) {
        let store = UserTabGroupStore.shared
        let group = store.create(name: store.nextDefaultName(), parentID: window.userTabGroupID)
        window.userTabGroupID = group.id
        normalizeOrder()
        beginRename(group: group.id)
    }

    /// Opens a new session in the group and puts it in a new group inside it, then
    /// starts renaming the new group.
    func createGroup(inGroup groupID: UUID) {
        guard let window = newTab(inGroup: groupID) else { return }
        createGroup(with: window)
    }

    /// Puts the group in a new group where it was, and starts renaming that: the way
    /// to make a group of groups from one that exists.
    func createGroup(around groupID: UUID) {
        let store = UserTabGroupStore.shared
        guard let group = store[groupID] else { return }
        let parent = store.create(name: store.nextDefaultName(), parentID: group.parentID)
        store.update(groupID) { $0.parentID = parent.id }
        normalizeOrder()
        beginRename(group: parent.id)
    }

    /// Adds a tab to a group, and so to the group's folder, or out of its folder for a
    /// group in none.
    func add(_ window: TerminalWindow, to groupID: UUID) {
        window.userTabFolderID = folder(ofGroup: groupID)
        window.userTabGroupID = groupID
        expand(groupTree: groupID)
        normalizeOrder()
    }

    /// Takes the tab out of its group, into the group that was in, if any.
    func removeFromGroup(_ window: TerminalWindow) {
        window.userTabGroupID = window.userTabGroupID.flatMap(parent(ofGroup:))
        normalizeOrder()
    }

    /// Puts the group in another group, at its end, and so in that group's folder. Not
    /// into itself or a group inside it, and a group with folders in it not into a group
    /// in a folder.
    func add(group groupID: UUID, toGroup targetID: UUID) {
        let store = UserTabGroupStore.shared
        guard groupID != targetID, !store.isGroup(targetID, within: groupID) else { return }
        guard !(holdsFolders(group: groupID) && isInsideFolder(group: targetID)) else { return }
        let folderID = folder(ofGroup: targetID)
        store.update(groupID) { $0.parentID = targetID }
        for window in innerMembers(of: groupID) {
            window.userTabFolderID = folderID
        }
        expand(groupTree: targetID)
        normalizeOrder()
    }

    /// Takes the group out of the group it is in, into the one that is in, if any. It
    /// stays in its folder.
    func removeGroupFromGroup(_ groupID: UUID) {
        let store = UserTabGroupStore.shared
        guard let parentID = store[groupID]?.parentID else { return }
        store.update(groupID) { $0.parentID = store[parentID]?.parentID }
        normalizeOrder()
    }

    func beginRename(group groupID: UUID) {
        commitEditing()
        editingDraft = UserTabGroupStore.shared[groupID]?.name ?? ""
        editingGroupID = groupID
    }

    func setColor(_ color: TerminalTabColor, forGroup groupID: UUID) {
        UserTabGroupStore.shared.update(groupID) { $0.color = color }
    }

    func toggleCollapsed(_ groupID: UUID) {
        UserTabGroupStore.shared.update(groupID) { $0.isCollapsed.toggle() }
    }

    /// Dissolves the group. What was in it, sessions, groups and folders, stays where
    /// it was, in whatever the group was in.
    func ungroup(_ groupID: UUID) {
        let store = UserTabGroupStore.shared
        let parentID = store[groupID]?.parentID
        for window in tabWindows where window.userTabGroupID == groupID {
            window.userTabGroupID = parentID
        }
        for child in store.children(of: groupID) {
            store.update(child.id) { $0.parentID = parentID }
        }
        for folder in UserTabFolderStore.shared.folders.values where folder.groupID == groupID {
            UserTabFolderStore.shared.update(folder.id) { $0.groupID = parentID }
        }
        store.remove(groupID)
    }

    /// Closes every session in the group, those in its folders too, then takes its
    /// folders out of the sidebar.
    func closeGroup(_ groupID: UUID) {
        let folderIDs = folders(inGroup: groupID).map(\.id)
        let windows = members(of: groupID)
        guard !windows.isEmpty || !folderIDs.isEmpty else { return }
        close(
            windows: windows,
            folders: folderIDs,
            actionName: "Close Group",
            messageText: "Close Group?",
            informativeText: "At least one session in this group still has a running process. If you close the group the processes will be killed.")
    }

    /// Finishes an inline rename, keeping what was typed. This is called whenever
    /// something else happens (switching tabs, the window losing focus, starting another
    /// rename) so a rename can never be left half done.
    func commitEditing() {
        let name = editingDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if let tabID = editingTabID,
           let window = tabWindows.first(where: { ObjectIdentifier($0) == tabID }) {
            // An empty title goes back to the title set by the terminal.
            window.terminalController?.titleOverride = name.isEmpty ? nil : name
        } else if let groupID = editingGroupID, !name.isEmpty {
            UserTabGroupStore.shared.update(groupID) { $0.name = name }
        } else if let folderID = editingFolderID, !name.isEmpty {
            UserTabFolderStore.shared.update(folderID) { $0.name = name }
        } else if isEditingWindowName {
            // An empty name takes the name away.
            setWindowName(name.isEmpty ? nil : name)
        }

        endEditing()
    }

    /// Abandons an inline rename.
    func cancelEditing() {
        endEditing()
    }

    private func endEditing() {
        guard editingTabID != nil || editingGroupID != nil || editingFolderID != nil || isEditingWindowName else { return }
        editingTabID = nil
        editingGroupID = nil
        editingFolderID = nil
        isEditingWindowName = false

        // Inline editing takes focus away from the terminal, so give it back.
        guard let hostWindow,
              let surface = hostWindow.terminalController?.focusedSurface else { return }
        hostWindow.makeFirstResponder(surface)
    }

    // MARK: Windows

    func beginRenameWindow() {
        commitEditing()
        editingDraft = windowName ?? ""
        isEditingWindowName = true
    }

    /// Names the window, or takes its name away with nil. Every tab saves it.
    func setWindowName(_ name: String?) {
        guard let hostWindow, hostWindow.folderSpace.name != name else { return }
        hostWindow.folderSpace.name = name
        for window in tabWindows {
            window.invalidateRestorableState()
        }
        // Every sidebar refreshes, since the others list this window by its name.
        for case let window as TerminalWindow in NSApp.windows {
            window.postTabSidebarItemDidChange()
        }
    }

    /// The other windows with a sidebar, each by the tab it shows, by name.
    var otherWindows: [TerminalWindow] {
        guard let hostWindow else { return [] }
        let ours = hostWindow.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(hostWindow)
        var seen: Set<ObjectIdentifier> = [ours]
        var result: [TerminalWindow] = []
        for case let window as TerminalWindow in NSApp.windows
        where window.supportsTabSidebar && window.terminalController != nil {
            let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            guard seen.insert(key).inserted else { continue }
            result.append(window.tabGroup?.selectedWindow as? TerminalWindow ?? window)
        }
        return result.sorted {
            Self.displayName(of: $0).localizedStandardCompare(Self.displayName(of: $1)) == .orderedAscending
        }
    }

    /// What a window is listed as: its name, or else the session it shows.
    static func displayName(of window: TerminalWindow) -> String {
        window.folderSpace.name ?? window.sessionTitle ?? window.title
    }

    /// Moves a tab, or a group or folder with everything in it, to the end of another
    /// window's sidebar.
    func move(_ payload: TabSidebarDragState.Payload, toWindow target: TerminalWindow) {
        let model = target.tabSidebarModel
        switch payload {
        case .tab(let window): model.dropAtEnd(window)
        case .group(let id): model.moveGroup(id, to: .end, after: false)
        case .folder(let id): model.moveFolder(id, to: .end, after: false)
        }
    }

    /// Moves a tab, or a group or folder with everything in it, to a window of its own.
    /// The first of its tabs is moved out natively, and the rest follow it.
    func moveToNewWindow(_ payload: TabSidebarDragState.Payload) {
        guard let block = Self.block(of: payload) else {
            if case .tab(let window) = payload { moveToNewWindow(window) }
            return
        }
        guard let first = tabWindows.first(where: { Entry(window: $0).path.contains(block) }) else { return }
        let groupID = first.userTabGroupID
        let folderID = first.userTabFolderID

        // Moving a tab out natively takes it out of its group and folder, so it is put
        // back in them for the rest to join. A group goes without the folder it is in,
        // which would otherwise open, empty, in the new window; a folder in the group
        // goes with it.
        first.moveTabToNewWindow(nil)
        first.userTabGroupID = groupID
        let keepsFolder: Bool
        switch block.kind {
        case .folder: keepsFolder = true
        case .group: keepsFolder = UserTabGroupStore.shared.isGroup(UserTabFolderStore.shared[folderID]?.groupID, within: block.id)
        }
        if keepsFolder {
            first.userTabFolderID = folderID
        }

        // The new window takes a main loop turn to settle.
        DispatchQueue.main.async { [weak self] in
            self?.move(payload, toWindow: first)
        }
    }

    /// Whether moving the payload to a window of its own makes sense: it must have a
    /// session to move out first.
    func canMoveToNewWindow(_ payload: TabSidebarDragState.Payload) -> Bool {
        guard let block = Self.block(of: payload) else { return true }
        return tabWindows.contains { Entry(window: $0).path.contains(block) }
    }

    private static func block(of payload: TabSidebarDragState.Payload) -> TabSidebarOrder.Block? {
        switch payload {
        case .tab: return nil
        case .group(let id): return .group(id)
        case .folder(let id): return .folder(id)
        }
    }

    /// Brings into this window what of `block` is in other windows: its tabs, after this
    /// window's own, and the folders it holds, empty ones too, out of the other windows'
    /// sidebars. A block dragged in from another window then moves like one of this
    /// window's own. A folder brought in alone leaves its group behind.
    private func adopt(_ block: TabSidebarOrder.Block) {
        // A window on its own may have no tab group yet; it gets one with the first tab.
        guard let hostWindow else { return }
        let store = UserTabFolderStore.shared
        let groups = UserTabGroupStore.shared
        let space = hostWindow.folderSpace

        // The other windows, a tab group at a time, each in its tab order.
        var sources: [[TerminalWindow]] = []
        var seen: Set<ObjectIdentifier> = [hostWindow.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(hostWindow)]
        for case let window as TerminalWindow in NSApp.windows {
            let key = window.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            guard seen.insert(key).inserted else { continue }
            sources.append(window.tabGroup?.windows.compactMap { $0 as? TerminalWindow } ?? [window])
        }
        guard !sources.isEmpty else { return }

        let folderIDs: [UUID]
        switch block.kind {
        case .folder:
            folderIDs = [block.id]
        case .group:
            folderIDs = sources.flatMap { $0.first?.folderSpace.folderIDs ?? [] }
                .filter { groups.isGroup(store[$0]?.groupID, within: block.id) }
        }

        var changed: [TerminalWindow] = []
        for windows in sources {
            guard let first = windows.first else { continue }
            let leaving = folderIDs.filter { first.folderSpace.folderIDs.contains($0) }
            leaving.forEach { first.folderSpace.remove($0) }

            let moving = windows.filter { Entry(window: $0).path.contains(block) }
            for window in moving {
                window.tabGroup?.removeWindow(window)
                window.folderSpace = space
                (hostWindow.tabGroup?.windows.last ?? hostWindow).addTabbedWindowSafely(window, ordered: .above)
            }
            if !leaving.isEmpty || !moving.isEmpty {
                changed.append(contentsOf: windows.filter { !moving.contains($0) })
            }
        }
        guard !changed.isEmpty else { return }

        folderIDs.forEach { space.add($0) }
        if block.kind == .folder, store[block.id]?.groupID != nil {
            store.update(block.id) { $0.groupID = nil }
        }
        for window in changed + tabWindows {
            window.invalidateRestorableState()
            window.postTabSidebarItemDidChange()
        }
    }

    // MARK: Reordering

    /// A tab as `TabSidebarOrder` sees it. The path is read from the window and the
    /// stores as they are, so it is live. A group or folder the stores don't know still
    /// orders, on its own.
    private struct Entry: TabSidebarOrderItem {
        let window: NSWindow

        var path: [TabSidebarOrder.Block] {
            guard let window = window as? TerminalWindow else { return [] }
            let place = TabSidebarModel.place(of: window, raw: true)
            return place.outer.map(TabSidebarOrder.Block.group)
                + (place.folderID.map { [TabSidebarOrder.Block.folder($0)] } ?? [])
                + place.inner.map(TabSidebarOrder.Block.group)
        }

        static func == (lhs: Entry, rhs: Entry) -> Bool { lhs.window === rhs.window }
    }

    /// Drops a tab before or after another tab. The dropped tab joins the target's group
    /// and folder.
    func drop(_ window: TerminalWindow, relativeTo target: TerminalWindow, after: Bool) {
        guard window !== target else { return }
        let others = tabWindows.filter { $0 !== window }
        guard let targetIndex = others.firstIndex(of: target) else { return }
        move(window,
             to: after ? targetIndex + 1 : targetIndex,
             groupID: target.userTabGroupID,
             folderID: target.userTabFolderID)
    }

    /// Drops a tab onto a group header, adding it to the start of that group, in the
    /// group's folder.
    func drop(_ window: TerminalWindow, ontoGroup groupID: UUID) {
        drop(window, into: .group(groupID))
    }

    /// Drops a tab onto a folder header, adding it to the start of that folder, in no
    /// group. An empty folder shows after every tab, so the tab goes to the end.
    func drop(_ window: TerminalWindow, ontoFolder folderID: UUID) {
        drop(window, into: .folder(folderID))
    }

    /// Drops a tab into a group or folder, at its start. Into a block with no tabs is the
    /// end, in the block.
    private func drop(_ window: TerminalWindow, into block: TabSidebarOrder.Block) {
        let others = tabWindows.filter { $0 !== window }
        let entries = others.map(Entry.init)
        let index = entries.firstIndex { $0.path.contains(block) } ?? others.count
        let path = TabSidebarOrder.path(of: .tab, droppedAt: .into(block), among: entries) ?? storePath(of: block)
        move(window, to: index, groupID: path.groupID, folderID: path.folderID)
    }

    /// Drops a tab before or after a group or folder, outside it: beside a group it
    /// stays in whatever the group is in; beside a folder it leaves the folder. Beside a
    /// block with no tabs, such as an empty folder, is the end.
    func drop(_ window: TerminalWindow, beside block: TabSidebarOrder.Block, after: Bool) {
        let others = tabWindows.filter { $0 !== window }
        let entries = others.map(Entry.init)
        guard let first = entries.first(where: { $0.path.contains(block) }),
              let depth = first.path.firstIndex(of: block) else {
            dropAtEnd(window)
            return
        }

        let landing = TabSidebarOrder.landing(beside: first, from: depth, of: .tab, among: entries)
        let anchor = after ? landing.anchors.last : landing.anchors.first
        guard let anchor, let position = others.firstIndex(where: { $0 === anchor.window }) else {
            dropAtEnd(window)
            return
        }
        move(window,
             to: after ? position + 1 : position,
             groupID: landing.path.groupID,
             folderID: landing.path.folderID)
    }

    /// Drops a tab below the last tab, moving it to the end outside any group or folder.
    func dropAtEnd(_ window: TerminalWindow) {
        let others = tabWindows.filter { $0 !== window }
        move(window, to: others.count, groupID: nil, folderID: nil)
    }

    /// Moves a tab to a new position. `index` is the position among the other tabs
    /// (i.e. excluding the moved tab), and `groupID` and `folderID` are the group and
    /// folder it should now belong to. The tab may come from another window's tab group,
    /// in which case it moves here, leaving that window's folders behind.
    func move(_ window: TerminalWindow, to index: Int, groupID: UUID?, folderID: UUID?) {
        guard let hostWindow else { return }

        // If the tab comes from another window, move it into our tab group first.
        if let tabGroup = hostWindow.tabGroup, !tabGroup.windows.contains(window) {
            window.tabGroup?.removeWindow(window)
            window.folderSpace = TabSidebarFolderSpace()
            let anchor = tabGroup.windows.last ?? hostWindow
            anchor.addTabbedWindowSafely(window, ordered: .above)
        }

        window.userTabGroupID = groupID
        window.userTabFolderID = folderID
        if let groupID {
            expand(groupTree: groupID)
        }
        if let folderID {
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        }

        var order: [NSWindow] = hostWindow.tabGroup?.windows.filter { $0 !== window } ?? []
        order.insert(window, at: min(max(index, 0), order.count))
        apply(order: nestedOrder(order), select: window)
    }

    /// Where a dragged group or folder is dropped.
    enum BlockDestination {
        /// Next to a tab, or next to whatever it is in.
        case tab(TerminalWindow)

        /// Next to a group, or whatever it is in.
        case group(UUID)

        /// Next to a folder, or whatever it is in.
        case folder(UUID)

        /// At the start of a group or folder, inside it.
        case inside(TabSidebarOrder.Block)

        /// After every tab.
        case end
    }

    /// Moves every tab of a group together, before or after `destination`, outside
    /// whatever that is, or into it. The tabs keep their order and their groups, and the
    /// group takes the group and the folder of where it lands (see
    /// `TabSidebarOrder.landing`); a group with folders in it lands outside folders. A
    /// group with no tabs, holding empty folders, moves too.
    func moveGroup(_ groupID: UUID, to destination: BlockDestination, after: Bool) {
        adopt(.group(groupID))
        let block = TabSidebarOrder.Block.group(groupID)
        let store = UserTabGroupStore.shared
        let dropped = self.dropped(group: groupID)

        let order: [NSWindow]?
        let path: [TabSidebarOrder.Block]
        if let moved = Self.order(tabWindows, moving: block, to: destination, after: after) {
            order = moved.order
            path = moved.path ?? storePath(of: destination, holding: dropped)
        } else {
            guard let landing = landing(forEmpty: block, dropped: dropped, at: destination) else { return }
            order = nil
            path = landing
        }

        // Not into itself or a group inside it.
        let parentID = path.groupID
        guard parentID != groupID, !store.isGroup(parentID, within: groupID) else { return }
        let folderID = path.folderID
        store.update(groupID) { $0.parentID = parentID }
        for window in innerMembers(of: groupID) {
            window.userTabFolderID = folderID
        }
        if let parentID {
            expand(groupTree: parentID)
        }
        if let folderID {
            UserTabFolderStore.shared.update(folderID) { $0.isCollapsed = false }
        }
        if let order {
            apply(order: nestedOrder(order), select: nil)
        } else {
            normalizeOrder()
            hostWindow?.postTabSidebarItemDidChange()
        }
    }

    /// Drops a group onto a folder header, adding it to the start of that folder.
    func drop(group groupID: UUID, ontoFolder folderID: UUID) {
        moveGroup(groupID, to: .inside(.folder(folderID)), after: false)
    }

    /// Drops a group onto another group's header, adding it to the start of that group.
    func drop(group groupID: UUID, ontoGroup targetID: UUID) {
        moveGroup(groupID, to: .inside(.group(targetID)), after: false)
    }

    /// Moves every tab of a folder together, before or after `destination`, outside
    /// whatever that is, or into it. The tabs keep their order, their groups and their
    /// folder, and the folder takes the group of where it lands. A folder with no
    /// sessions moves too: into or out of a group.
    func moveFolder(_ folderID: UUID, to destination: BlockDestination, after: Bool) {
        adopt(.folder(folderID))
        let block = TabSidebarOrder.Block.folder(folderID)
        let store = UserTabFolderStore.shared

        let order: [NSWindow]?
        let path: [TabSidebarOrder.Block]
        if let moved = Self.order(tabWindows, moving: block, to: destination, after: after) {
            order = moved.order
            path = moved.path ?? storePath(of: destination, holding: .folder)
        } else {
            guard let landing = landing(forEmpty: block, dropped: .folder, at: destination) else { return }
            order = nil
            path = landing
        }

        let groupID = path.outerGroupID
        store.update(folderID) { $0.groupID = groupID }
        if let groupID {
            expand(groupTree: groupID)
        }
        if let order {
            apply(order: nestedOrder(order), select: nil)
        } else {
            normalizeOrder()
            hostWindow?.postTabSidebarItemDidChange()
        }
    }

    /// Drops a folder onto a group header, adding it to the start of that group.
    func drop(folder folderID: UUID, ontoGroup groupID: UUID) {
        moveFolder(folderID, to: .inside(.group(groupID)), after: false)
    }

    /// `windows` with the tabs of a block moved to `destination`, and the path the block
    /// takes there (nil at the end, or into or beside a block with no tabs), or nil when
    /// the move makes no sense, such as next to one of its own tabs, or when the block
    /// has no tabs.
    static func order(
        _ windows: [NSWindow],
        moving block: TabSidebarOrder.Block,
        to destination: BlockDestination,
        after: Bool
    ) -> (order: [NSWindow], path: [TabSidebarOrder.Block]?)? {
        let entries = windows.map(Entry.init)
        let target = Self.target(destination)
        guard let order = TabSidebarOrder.order(entries, moving: block, to: target, after: after) else { return nil }
        let members = entries.filter { $0.path.contains(block) }
        let others = entries.filter { !$0.path.contains(block) }
        let dropped = TabSidebarOrder.Dropped(block, members: members)
        return (order.map(\.window), TabSidebarOrder.path(of: dropped, droppedAt: target, among: others))
    }

    private static func target(_ destination: BlockDestination) -> TabSidebarOrder.Destination<Entry> {
        switch destination {
        case .tab(let window): return .item(Entry(window: window))
        case .group(let id): return .block(.group(id))
        case .folder(let id): return .block(.folder(id))
        case .inside(let block): return .into(block)
        case .end: return .end
        }
    }

    /// The path a block with no tabs in this window takes at `destination`: from the
    /// tabs there, or else from the stores. Nil for a block that has tabs, whose move
    /// made no sense, for a destination inside the block, and for one that can't hold it.
    private func landing(
        forEmpty block: TabSidebarOrder.Block,
        dropped: TabSidebarOrder.Dropped,
        at destination: BlockDestination
    ) -> [TabSidebarOrder.Block]? {
        let entries = tabWindows.map(Entry.init)
        guard !entries.contains(where: { $0.path.contains(block) }) else { return nil }
        let path = TabSidebarOrder.path(of: dropped, droppedAt: Self.target(destination), among: entries)
            ?? storePath(of: destination, holding: dropped)
        if case .inside(let target) = destination {
            guard target != block, !path.contains(block), TabSidebarOrder.canHold(containers: path[...], dropped) else { return nil }
        }
        return path
    }

    /// What a block is in, by the stores and its first member, and the block itself:
    /// for a block with no tabs, which has no tab to read it from.
    private func storePath(of block: TabSidebarOrder.Block) -> [TabSidebarOrder.Block] {
        let groups = UserTabGroupStore.shared
        switch block.kind {
        case .folder:
            guard let folder = UserTabFolderStore.shared[block.id] else { return [block] }
            return groups.path(of: folder.groupID).map(TabSidebarOrder.Block.group) + [block]
        case .group:
            let inner = groups.path(of: block.id).map(TabSidebarOrder.Block.group)
            guard let folderID = folder(ofGroup: block.id) else { return inner }
            return storePath(of: .folder(folderID)) + inner
        }
    }

    /// The path `dropped` takes at `destination` when the tabs there don't say: nothing
    /// at the end; into a block, the block and what it is in; beside a block with no
    /// tabs, what the block is in that can hold it.
    private func storePath(of destination: BlockDestination, holding dropped: TabSidebarOrder.Dropped) -> [TabSidebarOrder.Block] {
        switch destination {
        case .end, .tab:
            return []
        case .inside(let block):
            return storePath(of: block)
        case .group(let id):
            return container(of: .group(id), holding: dropped)
        case .folder(let id):
            return container(of: .folder(id), holding: dropped)
        }
    }

    /// What a block is in, by the stores, out to the first that can hold `dropped`.
    private func container(of block: TabSidebarOrder.Block, holding dropped: TabSidebarOrder.Dropped) -> [TabSidebarOrder.Block] {
        var path = storePath(of: block).dropLast()
        while !TabSidebarOrder.canHold(containers: path, dropped) {
            path = path.dropLast()
        }
        return Array(path)
    }

    /// Makes sure the members of every group and folder are next to each other in the
    /// tab order. Each is placed where its first member is.
    func normalizeOrder() {
        guard let windows = hostWindow?.tabGroup?.windows else { return }
        let order = nestedOrder(windows)
        guard order != windows else { return }
        apply(order: order, select: nil)
    }

    /// `windows` in the sidebar's order (see `TabSidebarOrder.nested`). A group found
    /// across folders is given its first member's, the groups inside it with it. A tab
    /// whose own group its folder is in too is left in the folder alone.
    private func nestedOrder(_ windows: [NSWindow]) -> [NSWindow] {
        let groups = UserTabGroupStore.shared
        let folders = UserTabFolderStore.shared
        var groupFolders: [UUID: UUID?] = [:]
        for case let window as TerminalWindow in windows {
            let outer = groups.path(of: folders[window.userTabFolderID]?.groupID)
            if groups.path(of: window.userTabGroupID).contains(where: outer.contains) {
                window.userTabGroupID = nil
            }
            guard let groupID = rootGroup(of: window) else { continue }
            if let folderID = groupFolders[groupID] {
                if window.userTabFolderID != folderID { window.userTabFolderID = folderID }
            } else {
                groupFolders[groupID] = .some(window.userTabFolderID)
            }
        }
        return TabSidebarOrder.nested(windows.map(Entry.init)).map(\.window)
    }

    /// Reorders the native tab group to match `order`.
    private func apply(order: [NSWindow], select: NSWindow?) {
        guard let hostWindow, let tabGroup = hostWindow.tabGroup else { return }
        let selected = select ?? tabGroup.selectedWindow

        if order != tabGroup.windows {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0

            for (index, window) in order.enumerated() {
                // Everything before `index` is already in place, so `window` is somewhere
                // after it. Take it out and put it back directly before the tab currently
                // at `index`.
                let windows = tabGroup.windows
                guard windows.indices.contains(index), windows[index] !== window else { continue }
                let anchor = windows[index]
                tabGroup.removeWindow(window)
                anchor.addTabbedWindowSafely(window, ordered: .below)
            }

            NSAnimationContext.endGrouping()
        }

        if let selected {
            selected.makeKeyAndOrderFront(nil)
        }

        // Keyboard shortcut labels depend on the order.
        (selected?.windowController as? TerminalController ?? hostWindow.terminalController)?.relabelTabs()
        setNeedsRefresh()
    }
}

import AppKit
import Combine

/// Ids for the sessions the device sees. A tab's id lasts as long as its window.
@MainActor
final class RemoteSessionIDs {
    private struct Entry {
        weak var window: TerminalWindow?
        let id: String
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    func id(for window: TerminalWindow) -> String {
        let key = ObjectIdentifier(window)
        if let entry = entries[key], entry.window === window { return entry.id }
        let id = UUID().uuidString
        entries[key] = Entry(window: window, id: id)
        return id
    }

    func id(for tab: ObjectIdentifier) -> String? {
        entries[tab].flatMap { $0.window == nil ? nil : $0.id }
    }

    func window(for id: String) -> TerminalWindow? {
        entries.values.first { $0.id == id }?.window
    }

    func prune() {
        entries = entries.filter { $0.value.window != nil }
    }
}

/// Spaces sidebar updates out to at most one per `interval`, sending the first at once.
struct RemoteCoalescer {
    let interval: TimeInterval
    private(set) var lastFire: Date?

    init(interval: TimeInterval) {
        self.interval = interval
    }

    /// How long a change made at `now` waits before going out.
    func delay(at now: Date) -> TimeInterval {
        guard let lastFire else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastFire))
    }

    mutating func fired(at now: Date) {
        lastFire = now
    }
}

/// The Mac's sidebar as the device sees it: built from the same rows the sidebar shows,
/// whether or not the sidebar is shown, and sent on change, at most four times a second.
@MainActor
final class RemoteSessionFeed {
    private(set) var snapshot = SidebarSnapshot(rows: [])

    /// Called with each new snapshot while active.
    var onChange: ((SidebarSnapshot) -> Void)?

    let ids = RemoteSessionIDs()

    private var active = false
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?
    private var infoTimer: Timer?
    private var pending: DispatchWorkItem?
    private var coalescer = RemoteCoalescer(interval: 0.25)

    private let infoReader = TabSidebarSessionInfoReader()
    private var infos: [ObjectIdentifier: TabSidebarSessionInfo] = [:]

    /// Whether each folder holds a git checkout, read off the main thread.
    private var gitFolders: [String: (hasGit: Bool, readAt: Date)] = [:]
    private var gitReads: Set<String> = []
    private static let gitMaxAge: TimeInterval = 30

    /// Starts following the sidebar while a device subscribes, and stops after.
    func setActive(_ active: Bool) {
        guard active != self.active else { return }
        self.active = active
        guard active else {
            cancellables = []
            pollTimer?.invalidate()
            infoTimer?.invalidate()
            pollTimer = nil
            infoTimer = nil
            pending?.cancel()
            pending = nil
            return
        }

        let center = NotificationCenter.default
        Publishers.MergeMany(
            center.publisher(for: .terminalTabSidebarItemDidChange),
            center.publisher(for: NSWindow.didBecomeKeyNotification),
            center.publisher(for: NSWindow.willCloseNotification)
        )
        .sink { [weak self] _ in self?.setNeedsUpdate() }
        .store(in: &cancellables)
        UserTabGroupStore.shared.$groups.sink { [weak self] _ in self?.setNeedsUpdate() }.store(in: &cancellables)
        UserTabFolderStore.shared.$folders.sink { [weak self] _ in self?.setNeedsUpdate() }.store(in: &cancellables)

        // Titles and lights change without telling the sidebar's notifications; a cheap
        // poll catches them. Only changes are sent.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.setNeedsUpdate() }
        }
        infoTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readInfo() }
        }
        readInfo()
        update()
    }

    func setNeedsUpdate() {
        guard active, pending == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pending = nil
            self.update()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalescer.delay(at: Date()), execute: work)
    }

    /// Builds the snapshot now and sends it if it changed.
    func update() {
        let new = Self.snapshot(windows: currentWindows(), context: Context(
            id: { [ids] tab in
                if let window = tab.window { return ids.id(for: window) }
                return ids.id(for: tab.id) ?? tab.id.debugDescription
            },
            info: { [infos] tab in infos[tab.id] },
            bell: { tab in tab.window?.terminalController?.bell ?? false },
            hasGit: { [weak self] path in self?.hasGit(path) ?? false }
        ))
        ids.prune()
        guard new != snapshot else { return }
        snapshot = new
        coalescer.fired(at: Date())
        onChange?(new)
    }

    /// Every session, in sidebar order.
    func allTabs() -> [TabSidebarModel.Tab] {
        currentWindows().flatMap { $0.rows.flatMap(\.allTabs) }
    }

    /// The sessions of the window `id` names (see `SidebarWindow.id`), in sidebar order,
    /// or every session when it names none or one the Mac no longer has.
    func tabs(inWindow id: String?) -> [TabSidebarModel.Tab] {
        let windows = currentWindows()
        let rows = windows.first { $0.id == id }?.rows ?? windows.flatMap(\.rows)
        return rows.flatMap(\.allTabs)
    }

    /// Every window's native tab group with its sidebar rows.
    private func currentWindows() -> [Window] {
        var seen = Set<ObjectIdentifier>()
        var result: [Window] = []
        let main = NSApp.mainWindow as? TerminalWindow
        let front = main.map { $0.tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier($0) }
        for window in NSApp.windows.compactMap({ $0 as? TerminalWindow }) where window.isVisible || window.tabGroup != nil {
            let tabGroup = window.tabGroup
            let key = tabGroup.map(ObjectIdentifier.init) ?? ObjectIdentifier(window)
            guard seen.insert(key).inserted else { continue }
            let windows = tabGroup?.windows.compactMap { $0 as? TerminalWindow } ?? [window]
            let selected = tabGroup?.selectedWindow as? TerminalWindow ?? window
            result.append(Window(
                id: window.folderSpace.id.uuidString,
                name: window.folderSpace.name,
                title: TabSidebarModel.displayName(of: selected),
                isFront: key == front,
                rows: TabSidebarModel.rows(
                    of: windows,
                    selected: selected,
                    folderIDs: windows.first?.folderSpace.folderIDs ?? [])))
        }
        return result
    }

    private func readInfo() {
        let requests = NSApp.windows.compactMap { $0 as? TerminalWindow }.map { window in
            let controller = window.terminalController
            let surfaces = controller?.surfaceTree.root?.leaves() ?? []
            return TabSidebarSessionInfoReader.Request(
                id: ObjectIdentifier(window),
                pids: surfaces.compactMap { $0.surfaceModel?.foregroundPID },
                directory: controller?.focusedSurface?.pwd)
        }
        infoReader.read(requests) { [weak self] infos in
            MainActor.assumeIsolated {
                guard let self, infos != self.infos else { return }
                self.infos = infos
                self.setNeedsUpdate()
            }
        }
    }

    /// Whether `path` holds a git checkout, as last read. An unread or stale answer is
    /// read again off the main thread and the snapshot redone when it is in.
    private func hasGit(_ path: String) -> Bool {
        let known = gitFolders[path]
        let stale = known.map { Date().timeIntervalSince($0.readAt) > Self.gitMaxAge } ?? true
        if stale, !gitReads.contains(path) {
            gitReads.insert(path)
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let hasGit = Git.checkout(of: URL(fileURLWithPath: path, isDirectory: true)) != nil
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.gitReads.remove(path)
                        let changed = self.gitFolders[path]?.hasGit != hasGit
                        self.gitFolders[path] = (hasGit, Date())
                        if changed { self.setNeedsUpdate() }
                    }
                }
            }
        }
        // Until git answers, a `.git` in the folder is a good guess.
        return known?.hasGit ?? FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    // MARK: Building

    /// What a snapshot needs to know about the Mac beyond the rows.
    struct Context {
        var id: (TabSidebarModel.Tab) -> String
        var info: (TabSidebarModel.Tab) -> TabSidebarSessionInfo?
        var bell: (TabSidebarModel.Tab) -> Bool
        var hasGit: (String) -> Bool
    }

    /// One window's sidebar.
    struct Window {
        var id: String
        var name: String?
        var title: String
        var isFront: Bool
        var rows: [TabSidebarModel.Row]
    }

    /// Every window's rows together, and each window's own, listed by title as the
    /// Mac's sidebar lists the other windows.
    static func snapshot(windows: [Window], context: Context) -> SidebarSnapshot {
        let shown = windows.map { window in
            SidebarWindow(
                id: window.id,
                name: window.name,
                title: window.title,
                isFront: window.isFront,
                rows: sidebarRows(window.rows, context: context))
        }
        return SidebarSnapshot(
            rows: merged(shown.flatMap(\.rows)),
            windows: shown.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
    }

    static func snapshot(rows: [TabSidebarModel.Row], context: Context) -> SidebarSnapshot {
        SidebarSnapshot(rows: merged(sidebarRows(rows, context: context)))
    }

    private static func merged(_ rows: [SidebarRow]) -> [SidebarRow] {
        var result: [SidebarRow] = []
        for row in rows {
            // Two windows can show the same folder; it is listed once, with both's rows.
            if case .folder(let folder) = row,
               let index = result.firstIndex(where: { if case .folder(let shown) = $0 { return shown.id == folder.id } else { return false } }),
               case .folder(var shown) = result[index] {
                shown.rows += folder.rows
                result[index] = .folder(shown)
                continue
            }
            result.append(row)
        }
        return result
    }

    private static func sidebarRows(_ rows: [TabSidebarModel.Row], context: Context) -> [SidebarRow] {
        rows.map { row in
            switch row {
            case .tab(let tab):
                return .session(session(tab, context: context))
            case .group(let section):
                return .group(SidebarGroup(
                    id: section.group.id.uuidString,
                    name: section.group.name,
                    collapsed: section.group.isCollapsed,
                    color: TabColorName(section.group.color),
                    rows: sidebarRows(section.rows, context: context)))
            case .folder(let section):
                return .folder(folder(section, context: context))
            }
        }
    }

    private static func folder(_ section: TabSidebarModel.FolderSection, context: Context) -> SidebarFolder {
        SidebarFolder(
            id: section.folder.id.uuidString,
            name: section.folder.name,
            path: section.folder.path,
            abbreviatedPath: section.folder.abbreviatedPath,
            hasGit: context.hasGit(section.folder.path),
            collapsed: section.folder.isCollapsed,
            groupID: section.folder.groupID?.uuidString,
            rows: sidebarRows(section.rows, context: context))
    }

    private static func session(_ tab: TabSidebarModel.Tab, context: Context) -> SidebarSession {
        let info = context.info(tab)
        let state = tab.claudeCodeState
        let activity = tab.claudeCodeActivity
        return SidebarSession(
            id: context.id(tab),
            title: tab.title,
            agent: info?.sessions.first.flatMap { AgentKind(rawValue: $0.agent.rawValue) },
            light: state.map { SessionLight($0.light) },
            lightLabel: state.map { $0.badgeHelp ?? $0.light.label },
            workingSince: state?.light == .working ? activity.workingSince : nil,
            stoppedSince: state?.stoppedSince(activity, lastActive: info?.lastActive),
            badge: state?.badge,
            finishedUnseen: activity.finishedUnseen && !tab.isSelected,
            model: info?.model,
            branch: info?.branch,
            isWorktree: info?.isLinkedWorktree ?? false,
            directory: info?.directory,
            abbreviatedDirectory: info?.abbreviatedDirectory,
            lastActive: info?.lastActive,
            bell: context.bell(tab),
            isSelected: tab.isSelected,
            color: TabColorName(tab.color))
    }
}

extension SessionLight {
    init(_ light: ClaudeCodeLight) {
        switch light {
        case .working: self = .working
        case .pending: self = .pending
        case .waiting: self = .waiting
        case .unlanded: self = .unlanded
        case .clean: self = .clean
        }
    }
}

extension TabColorName {
    /// The color a tab is filled with; nil for none and the colors that follow a session.
    init?(_ color: TerminalTabColor) {
        switch color {
        case .blue: self = .blue
        case .purple: self = .purple
        case .pink: self = .pink
        case .red: self = .red
        case .orange: self = .orange
        case .yellow: self = .yellow
        case .green: self = .green
        case .teal: self = .teal
        case .graphite: self = .graphite
        case .none, .auto, .attention: return nil
        }
    }
}

import Foundation

/// What the Mac's tab sidebar shows, as a tree in the sidebar's own order. The device
/// draws it as is and never re-sorts it.
///
/// Names follow the Mac's `TabSidebarModel`: a row is a session (a tab), a group of
/// sessions, a folder (holding sessions and groups) or a folder group (holding folders).
public struct SidebarSnapshot: Codable, Equatable, Sendable {
    /// Every window's rows together, a folder open in two windows listed once.
    public var rows: [SidebarRow]

    /// Each window's own rows, by name. Empty from a Mac that doesn't send them.
    public var windows: [SidebarWindow]

    /// Folders with no session in them, which the sidebar still lists, are rows too.
    public init(rows: [SidebarRow], windows: [SidebarWindow] = []) {
        self.rows = rows
        self.windows = windows
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rows = try container.decode([SidebarRow].self, forKey: .rows)
        windows = try container.decodeIfPresent([SidebarWindow].self, forKey: .windows) ?? []
    }

    public func window(id: String) -> SidebarWindow? {
        windows.first { $0.id == id }
    }

    /// Every folder, in sidebar order: the choices for New Session.
    public var folders: [SidebarFolder] {
        rows.flatMap(\.folders)
    }

    /// Every session, in sidebar order.
    public var sessions: [SidebarSession] {
        rows.flatMap(\.sessions)
    }

    public func session(id: String) -> SidebarSession? {
        sessions.first { $0.id == id }
    }
}

/// One of the Mac's windows, each with its own sidebar.
public struct SidebarWindow: Codable, Equatable, Sendable, Identifiable {
    /// Lasts across the Mac's restarts, so a device can keep its choice.
    public var id: String

    /// What the window was named, such as "Work"; none for an unnamed one.
    public var name: String?

    /// What the Mac lists the window as: its name, or else the session it shows.
    public var title: String

    /// The Mac's front window.
    public var isFront: Bool
    public var rows: [SidebarRow]

    public init(id: String, name: String? = nil, title: String, isFront: Bool = false, rows: [SidebarRow]) {
        self.id = id
        self.name = name
        self.title = title
        self.isFront = isFront
        self.rows = rows
    }

    /// Every folder, in sidebar order.
    public var folders: [SidebarFolder] { rows.flatMap(\.folders) }

    /// Every session, in sidebar order.
    public var sessions: [SidebarSession] { rows.flatMap(\.sessions) }
}

public enum SidebarRow: Equatable, Sendable, Identifiable {
    case session(SidebarSession)
    case group(SidebarGroup)
    case folder(SidebarFolder)
    case folderGroup(SidebarFolderGroup)

    public var id: String {
        switch self {
        case .session(let session): return "session-\(session.id)"
        case .group(let group): return "group-\(group.id)"
        case .folder(let folder): return "folder-\(folder.id)"
        case .folderGroup(let group): return "folders-\(group.id)"
        }
    }

    /// The folders the row is or holds, those of the groups in it too.
    public var folders: [SidebarFolder] {
        switch self {
        case .folder(let folder): return [folder]
        case .folderGroup(let group): return group.folders
        case .group(let group): return group.rows.flatMap(\.folders)
        case .session: return []
        }
    }

    /// Every session in the row, shown or collapsed away.
    public var sessions: [SidebarSession] {
        switch self {
        case .session(let session): return [session]
        case .group(let group): return group.rows.flatMap(\.sessions)
        case .folder(let folder): return folder.rows.flatMap(\.sessions)
        case .folderGroup(let group): return group.rows.flatMap(\.sessions)
        }
    }
}

/// One tab: a terminal session, usually running Claude Code or Codex.
public struct SidebarSession: Codable, Equatable, Sendable, Identifiable {
    /// Stable for the life of the tab on the Mac.
    public var id: String
    public var title: String
    public var agent: AgentKind?

    /// What its agent is doing, the colored dot.
    public var light: SessionLight?

    /// The light's words, as the Mac's hover card shows them.
    public var lightLabel: String?

    /// When the current request started, while working.
    public var workingSince: Date?

    /// When it stopped working or started waiting, once stopped.
    public var stoppedSince: Date?

    /// The files waiting to be committed while pending, the commits waiting to land
    /// while unlanded.
    public var badge: Int?

    /// It finished a request that hasn't been looked at.
    public var finishedUnseen: Bool
    public var model: String?
    public var branch: String?
    public var isWorktree: Bool
    public var directory: String?
    public var abbreviatedDirectory: String?
    public var lastActive: Date?

    /// The terminal rang its bell since it was last looked at.
    public var bell: Bool

    /// The tab selected in the Mac's front window.
    public var isSelected: Bool

    /// The tab's color, by name (see `TabColorName`).
    public var color: TabColorName?

    public init(
        id: String,
        title: String,
        agent: AgentKind? = nil,
        light: SessionLight? = nil,
        lightLabel: String? = nil,
        workingSince: Date? = nil,
        stoppedSince: Date? = nil,
        badge: Int? = nil,
        finishedUnseen: Bool = false,
        model: String? = nil,
        branch: String? = nil,
        isWorktree: Bool = false,
        directory: String? = nil,
        abbreviatedDirectory: String? = nil,
        lastActive: Date? = nil,
        bell: Bool = false,
        isSelected: Bool = false,
        color: TabColorName? = nil
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.light = light
        self.lightLabel = lightLabel
        self.workingSince = workingSince
        self.stoppedSince = stoppedSince
        self.badge = badge
        self.finishedUnseen = finishedUnseen
        self.model = model
        self.branch = branch
        self.isWorktree = isWorktree
        self.directory = directory
        self.abbreviatedDirectory = abbreviatedDirectory
        self.lastActive = lastActive
        self.bell = bell
        self.isSelected = isSelected
        self.color = color
    }
}

extension SidebarSession {
    /// The few characters the Mac's sidebar shows beside the light at `now`: how long
    /// it has been working, how many files or commits are left, or how long ago it
    /// finished. The device works it out itself so the Mac needn't send a change every
    /// second.
    public func statusText(at now: Date) -> String? {
        switch light {
        case .working: return workingSince.map { SidebarTime.elapsed(since: $0, at: now) }
        case .pending, .unlanded: return badge.map(String.init)
        case .clean: return stoppedSince.map { SidebarTime.ago($0, at: now) }
        case .waiting, nil: return nil
        }
    }
}

/// The Mac's `ClaudeCodeActivity` time formatting.
public enum SidebarTime {
    /// How long a request has been working, to the second while it is short: "12s",
    /// "4m", "1h 5m".
    public static func elapsed(since start: Date, at now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// How long ago something happened, in its largest unit: "now", "4m", "3h", "2d".
    public static func ago(_ date: Date, at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date))) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 60 * 24 { return "\(minutes / 60)h" }
        return "\(minutes / (60 * 24))d"
    }
}

/// A group of sessions. A group can hold groups, so its rows are sessions and groups.
public struct SidebarGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var collapsed: Bool
    public var color: TabColorName?

    /// Its sessions and the groups in it, in sidebar order.
    public var rows: [SidebarRow]

    public init(id: String, name: String, collapsed: Bool = false, color: TabColorName? = nil, rows: [SidebarRow]) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.color = color
        self.rows = rows
    }

    /// A group of sessions alone.
    public init(id: String, name: String, collapsed: Bool = false, color: TabColorName? = nil, sessions: [SidebarSession]) {
        self.init(id: id, name: name, collapsed: collapsed, color: color, rows: sessions.map(SidebarRow.session))
    }

    /// Every session in the group, those of the groups in it too.
    public var sessions: [SidebarSession] { rows.flatMap(\.sessions) }

    /// The light of the member that needs attention most.
    public var light: SessionLight? { SessionLight.mostUrgent(sessions.compactMap(\.light)) }
}

extension SidebarGroup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, collapsed, color, rows, sessions
    }

    /// The rows go as they are, and every session flat too, for a device from before
    /// groups nested, which reads only the sessions.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encodeIfPresent(color, forKey: .color)
        try container.encode(rows, forKey: .rows)
        try container.encode(sessions, forKey: .sessions)
    }

    /// From a Mac from before groups nested, the sessions are the rows.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        collapsed = try container.decode(Bool.self, forKey: .collapsed)
        color = try container.decodeIfPresent(TabColorName.self, forKey: .color)
        if let rows = try container.decodeIfPresent([SidebarRow].self, forKey: .rows) {
            self.rows = rows
        } else {
            rows = try container.decode([SidebarSession].self, forKey: .sessions).map(SidebarRow.session)
        }
    }
}

/// A folder opened in the sidebar. New Session opens a session in it.
public struct SidebarFolder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var path: String
    public var abbreviatedPath: String

    /// The folder holds a git checkout. Only those can take a new session.
    public var hasGit: Bool
    public var collapsed: Bool

    /// The folder group it is in, if any.
    public var groupID: String?

    /// Its sessions and groups; folders don't nest.
    public var rows: [SidebarRow]

    public init(
        id: String,
        name: String,
        path: String,
        abbreviatedPath: String,
        hasGit: Bool,
        collapsed: Bool = false,
        groupID: String? = nil,
        rows: [SidebarRow] = []
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.abbreviatedPath = abbreviatedPath
        self.hasGit = hasGit
        self.collapsed = collapsed
        self.groupID = groupID
        self.rows = rows
    }

    public var light: SessionLight? { SessionLight.mostUrgent(rows.flatMap(\.sessions).compactMap(\.light)) }
}

/// A group of folders, as a Mac sent one before its groups could hold folders; a Mac
/// since sends such a group as a `SidebarGroup` with folders among its rows. Its rows
/// are folders and folder groups.
public struct SidebarFolderGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var collapsed: Bool

    /// Its folders and the folder groups in it, in sidebar order.
    public var rows: [SidebarRow]

    public init(id: String, name: String, collapsed: Bool = false, rows: [SidebarRow]) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
        self.rows = rows
    }

    /// A folder group of folders alone.
    public init(id: String, name: String, collapsed: Bool = false, folders: [SidebarFolder]) {
        self.init(id: id, name: name, collapsed: collapsed, rows: folders.map(SidebarRow.folder))
    }

    /// Every folder in the group, those of the folder groups in it too.
    public var folders: [SidebarFolder] { rows.flatMap(\.folders) }

    /// The light of the session that needs attention most.
    public var light: SessionLight? { SessionLight.mostUrgent(rows.flatMap(\.sessions).compactMap(\.light)) }
}

extension SidebarFolderGroup: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, collapsed, rows, folders
    }

    /// The rows go as they are, and every folder flat too, for a device from before
    /// folder groups nested, which reads only the folders.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(collapsed, forKey: .collapsed)
        try container.encode(rows, forKey: .rows)
        try container.encode(folders, forKey: .folders)
    }

    /// From a Mac from before folder groups nested, the folders are the rows.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        collapsed = try container.decode(Bool.self, forKey: .collapsed)
        if let rows = try container.decodeIfPresent([SidebarRow].self, forKey: .rows) {
            self.rows = rows
        } else {
            rows = try container.decode([SidebarFolder].self, forKey: .folders).map(SidebarRow.folder)
        }
    }
}

public enum AgentKind: String, Codable, Sendable {
    case claude
    case codex
}

/// The Mac's `ClaudeCodeLight`: what a session's agent is doing.
public enum SessionLight: String, Codable, Sendable, CaseIterable {
    case working
    case pending
    case waiting
    case unlanded
    case clean

    /// The Mac's `ClaudeCodeLight.label`.
    public var label: String {
        switch self {
        case .working: return "Working"
        case .pending: return "Changes not committed"
        case .unlanded: return "Commits not landed"
        case .waiting: return "Waiting for you"
        case .clean: return "Done"
        }
    }

    /// The Mac's `ClaudeCodeLight.tabColor`.
    public var color: TabColorName {
        switch self {
        case .working: return .blue
        case .pending: return .yellow
        case .unlanded: return .teal
        case .waiting: return .red
        case .clean: return .green
        }
    }

    var urgency: Int {
        switch self {
        case .waiting: return 4
        case .working: return 3
        case .pending: return 2
        case .unlanded: return 1
        case .clean: return 0
        }
    }

    /// The light that needs attention most, as the Mac shows on a collapsed group.
    public static func mostUrgent(_ lights: [SessionLight]) -> SessionLight? {
        lights.max { $0.urgency < $1.urgency }
    }
}

/// The Mac's `TerminalTabColor` names for the colors it fills a tab with, each the
/// system color of that name (graphite is gray).
public enum TabColorName: String, Codable, Sendable, CaseIterable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case graphite
}

// MARK: - Coding

extension SidebarRow: Codable {
    private enum Keys: String, CodingKey {
        case session
        case group
        case folder
        case folderGroup
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .session(let value): try container.encode(value, forKey: .session)
        case .group(let value): try container.encode(value, forKey: .group)
        case .folder(let value): try container.encode(value, forKey: .folder)
        case .folderGroup(let value): try container.encode(value, forKey: .folderGroup)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        if let value = try container.decodeIfPresent(SidebarSession.self, forKey: .session) {
            self = .session(value)
        } else if let value = try container.decodeIfPresent(SidebarGroup.self, forKey: .group) {
            self = .group(value)
        } else if let value = try container.decodeIfPresent(SidebarFolder.self, forKey: .folder) {
            self = .folder(value)
        } else if let value = try container.decodeIfPresent(SidebarFolderGroup.self, forKey: .folderGroup) {
            self = .folderGroup(value)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown sidebar row"))
        }
    }
}

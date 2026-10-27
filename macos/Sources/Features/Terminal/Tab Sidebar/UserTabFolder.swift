import AppKit
import Combine

/// A directory opened in the tab sidebar. Sessions and groups of sessions live in it,
/// and every session opened in it starts in its directory. Each `TerminalWindow` refers
/// to its folder by `id`; a group is in the folder its members are in. A folder can be
/// in a group, which it refers to by `groupID`: a session in it is in that group too.
struct UserTabFolder: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String

    /// The absolute path of the directory.
    let path: String
    var isCollapsed: Bool

    /// The group the folder is in, if any.
    var groupID: UUID?

    init(id: UUID = UUID(), name: String? = nil, path: String, isCollapsed: Bool = false, groupID: UUID? = nil) {
        self.id = id
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.isCollapsed = isCollapsed
        self.groupID = groupID
    }

    /// The path as the shell shows it, with the home directory as `~`.
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
}

/// The folders open in the sidebar of one native tab group, in the order they were
/// opened, whether or not they have sessions. Every tab's window in the tab group points
/// at the same one; a window that joins the tab group gives its folders to it (see
/// `TabSidebarModel.unifyFolderSpace`). A folder with no sessions has nothing else to
/// keep it, which is why this exists. Being the one thing a window's tabs share, it
/// holds the window's name and id too.
final class TabSidebarFolderSpace {
    /// What tells the window from the others across restarts: the work items made on its
    /// board are its own, and its board's filter is kept by it.
    let id: UUID

    var folderIDs: [UUID] = []

    /// What the window is called, such as "Work", to tell it from the others.
    var name: String?

    init(id: UUID = UUID(), folderIDs: [UUID] = [], name: String? = nil) {
        self.id = id
        self.folderIDs = folderIDs
        self.name = name
    }

    func add(_ id: UUID) {
        guard !folderIDs.contains(id) else { return }
        folderIDs.append(id)
    }

    func remove(_ id: UUID) {
        folderIDs.removeAll { $0 == id }
    }
}

/// The shared registry of all folders, like `UserTabGroupStore` for groups.
final class UserTabFolderStore: ObservableObject {
    static let shared = UserTabFolderStore()

    @Published private(set) var folders: [UUID: UserTabFolder] = [:]

    private init() {}

    subscript(id: UUID?) -> UserTabFolder? {
        guard let id else { return nil }
        return folders[id]
    }

    /// Creates and registers a folder for a directory, named after it.
    func create(path: String) -> UserTabFolder {
        let folder = UserTabFolder(path: URL(fileURLWithPath: path).standardizedFileURL.path)
        folders[folder.id] = folder
        return folder
    }

    /// Registers a folder decoded from saved state. If a folder with the same id is
    /// already known (because another restored tab registered it first), the existing
    /// value wins so all tabs agree.
    func register(_ folder: UserTabFolder) {
        guard folders[folder.id] == nil else { return }
        folders[folder.id] = folder
    }

    func update(_ id: UUID, _ body: (inout UserTabFolder) -> Void) {
        guard var folder = folders[id] else { return }
        body(&folder)
        guard folder != folders[id] else { return }
        folders[id] = folder
        Self.invalidateRestorableState(forFolder: id)
    }

    func remove(_ id: UUID) {
        folders[id] = nil
    }

    /// The folders in the group, those in the groups inside it too.
    func folders(inGroup groupID: UUID) -> [UserTabFolder] {
        folders.values.filter { UserTabGroupStore.shared.isGroup($0.groupID, within: groupID) }
    }

    /// Folder metadata is saved with each window's restorable state, so whenever it
    /// changes the windows showing the folder need to re-save.
    static func invalidateRestorableState(forFolder id: UUID) {
        for window in NSApp.windows {
            guard let window = window as? TerminalWindow, window.folderSpace.folderIDs.contains(id) else { continue }
            window.invalidateRestorableState()
        }
    }
}

/// A group of folders, as the sidebar had them before a group could hold folders. Saved
/// state from then still carries them; each comes back as a group of the same id.
struct UserTabFolderGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var isCollapsed: Bool

    /// The folder group this folder group was in, if any.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, isCollapsed: Bool = false, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.isCollapsed = isCollapsed
        self.parentID = parentID
    }

    /// The group it is now.
    var group: UserTabGroup {
        UserTabGroup(id: id, name: name, isCollapsed: isCollapsed, parentID: parentID)
    }
}

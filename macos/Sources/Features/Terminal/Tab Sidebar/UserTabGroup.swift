import AppKit
import Combine

/// A user-created, named group in the tab sidebar, of tabs, of groups and of folders.
///
/// This is unrelated to `NSWindowTabGroup`, which is AppKit's native grouping of
/// windows into tabs. A `UserTabGroup` is a label that a subset of the tabs within
/// a native tab group share. Each `TerminalWindow` refers to its group by `id`, and
/// each `UserTabFolder` to the group it is in by `groupID`. A group can be in another
/// group, which it refers to by `parentID`: a tab in it is in the group's parents too.
/// A group that holds folders stays outside every folder.
struct UserTabGroup: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var color: TerminalTabColor
    var isCollapsed: Bool

    /// The group this group is in, if any.
    var parentID: UUID?

    init(id: UUID = UUID(), name: String, color: TerminalTabColor = .none, isCollapsed: Bool = false, parentID: UUID? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.isCollapsed = isCollapsed
        self.parentID = parentID
    }
}

/// The shared registry of all user tab groups. Group metadata (name, color, collapsed state)
/// lives here so that every window in a native tab group sees the same values.
final class UserTabGroupStore: ObservableObject {
    static let shared = UserTabGroupStore()

    @Published private(set) var groups: [UUID: UserTabGroup] = [:]

    private init() {}

    subscript(id: UUID?) -> UserTabGroup? {
        guard let id else { return nil }
        return groups[id]
    }

    /// Creates and registers a new group, in `parentID`'s group when given.
    func create(name: String, color: TerminalTabColor = .none, parentID: UUID? = nil) -> UserTabGroup {
        let group = UserTabGroup(name: name, color: color, parentID: parentID)
        groups[group.id] = group
        return group
    }

    /// Registers a group decoded from saved state. If a group with the same id is
    /// already known (because another restored tab registered it first), the existing
    /// value wins so all tabs agree.
    func register(_ group: UserTabGroup) {
        guard groups[group.id] == nil else { return }
        groups[group.id] = group
    }

    func update(_ id: UUID, _ body: (inout UserTabGroup) -> Void) {
        guard var group = groups[id] else { return }
        body(&group)
        guard group != groups[id] else { return }
        groups[id] = group
        Self.invalidateRestorableState(forGroup: id)
    }

    func remove(_ id: UUID) {
        groups[id] = nil
    }

    /// Returns a default name for a new group that isn't already in use.
    func nextDefaultName() -> String {
        let existing = Set(groups.values.map(\.name))
        var index = 1
        while existing.contains("Group \(index)") { index += 1 }
        return "Group \(index)"
    }

    /// The group `id` and the groups it is in, outermost first. Empty for a group the
    /// store doesn't know, and cut short at one it doesn't know or has seen already.
    func path(of id: UUID?) -> [UUID] {
        Self.path(of: id, in: groups)
    }

    /// `path(of:)` on `groups`, for a caller holding what the store is about to hold.
    static func path(of id: UUID?, in groups: [UUID: UserTabGroup]) -> [UUID] {
        var path: [UUID] = []
        var next = id
        while let id = next, let group = groups[id], !path.contains(id) {
            path.insert(id, at: 0)
            next = group.parentID
        }
        return path
    }

    /// The groups `id`'s group is in, outermost first.
    func ancestors(of id: UUID?) -> [UserTabGroup] {
        path(of: id).dropLast().compactMap { groups[$0] }
    }

    /// Whether `id` is `ancestorID`'s group or in it.
    func isGroup(_ id: UUID?, within ancestorID: UUID) -> Bool {
        path(of: id).contains(ancestorID)
    }

    /// The groups directly in `id`'s group.
    func children(of id: UUID) -> [UserTabGroup] {
        groups.values.filter { $0.parentID == id }
    }

    /// The names of the group and the groups it is in, outermost first, joined as a
    /// path: `Clients › Acme`.
    func pathName(of id: UUID) -> String {
        path(of: id).compactMap { groups[$0]?.name }.joined(separator: " › ")
    }

    /// Group metadata is saved with each window's restorable state, so whenever it
    /// changes the member windows need to re-save: the tabs in the group, and the tabs
    /// whose sidebar shows a folder in it. A tab in a group is in its parents too, so a
    /// change to a parent is saved by every tab under it.
    private static func invalidateRestorableState(forGroup id: UUID) {
        let folders = UserTabFolderStore.shared
        for window in NSApp.windows {
            guard let window = window as? TerminalWindow else { continue }
            guard shared.isGroup(window.userTabGroupID, within: id)
                || window.folderSpace.folderIDs.contains(where: { shared.isGroup(folders[$0]?.groupID, within: id) }) else { continue }
            window.invalidateRestorableState()
        }
    }
}

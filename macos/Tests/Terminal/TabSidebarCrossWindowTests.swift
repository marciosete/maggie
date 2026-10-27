import AppKit
import Testing
@testable import Ghostty

/// Groups, folders and folder groups dragged from one window's sidebar to another's.
@Suite(.serialized)
@MainActor
struct TabSidebarCrossWindowTests {
    private func tab(_ title: String, group: UUID? = nil, folder: UUID? = nil) -> TerminalWindow {
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.userTabGroupID = group
        window.userTabFolderID = folder
        return window
    }

    /// A window of `tabs`, one tab group, sharing one folder space.
    private func window(_ tabs: [TerminalWindow], folders: [UUID] = []) throws -> TerminalWindow {
        let first = try #require(tabs.first)
        first.folderSpace = TabSidebarFolderSpace(folderIDs: folders)
        first.orderFront(nil)
        for tab in tabs.dropFirst() {
            tab.folderSpace = first.folderSpace
            (first.tabGroup?.windows.last ?? first).addTabbedWindow(tab, ordered: .above)
        }
        return first
    }

    private func titles(_ window: TerminalWindow) -> [String] {
        window.tabGroup?.windows.map(\.title) ?? [window.title]
    }

    private func close(_ windows: [TerminalWindow]) {
        windows.forEach { $0.close() }
    }

    @Test func aGroupMovesWithAllItsSessions() throws {
        let group = UUID()
        let h1 = tab("h1")
        let o1 = tab("o1", group: group)
        let o2 = tab("o2", group: group)
        let o3 = tab("o3")
        defer { close([h1, o1, o2, o3]) }
        let host = try window([h1])
        let other = try window([o3, o1, o2])

        host.tabSidebarModel.moveGroup(group, to: .end, after: false)

        #expect(titles(host) == ["h1", "o1", "o2"])
        #expect(titles(other) == ["o3"])
        #expect(o1.userTabGroupID == group && o2.userTabGroupID == group)
        #expect(o1.folderSpace === host.folderSpace)
    }

    @Test func aFolderMovesWithItsGroupsAndLeavesTheOtherSidebar() throws {
        let store = UserTabFolderStore.shared
        let folder = store.create(path: "/tmp/cross-window-folder")
        let group = UUID()
        let h1 = tab("h1")
        let o1 = tab("o1", group: group, folder: folder.id)
        let o2 = tab("o2", folder: folder.id)
        let o3 = tab("o3")
        defer {
            close([h1, o1, o2, o3])
            store.remove(folder.id)
        }
        let host = try window([h1])
        // The window is told by a tab that stays.
        _ = try window([o1, o2, o3], folders: [folder.id])
        let other = o3

        host.tabSidebarModel.moveFolder(folder.id, to: .tab(h1), after: false)

        #expect(titles(host) == ["o1", "o2", "h1"])
        #expect(titles(other) == ["o3"])
        #expect(o1.userTabGroupID == group)
        #expect(o1.userTabFolderID == folder.id && o2.userTabFolderID == folder.id)
        #expect(host.folderSpace.folderIDs.contains(folder.id))
        #expect(!other.folderSpace.folderIDs.contains(folder.id))
    }

    @Test func aFolderGroupMovesWithItsEmptyFolders() throws {
        let store = UserTabFolderStore.shared
        let groups = UserTabGroupStore.shared
        let group = groups.create(name: "Work")
        let full = store.create(path: "/tmp/cross-window-full")
        let empty = store.create(path: "/tmp/cross-window-empty")
        store.update(full.id) { $0.groupID = group.id }
        store.update(empty.id) { $0.groupID = group.id }
        let h1 = tab("h1")
        let o1 = tab("o1", folder: full.id)
        let o2 = tab("o2")
        defer {
            close([h1, o1, o2])
            store.remove(full.id)
            store.remove(empty.id)
            groups.remove(group.id)
        }
        let host = try window([h1])
        _ = try window([o1, o2], folders: [full.id, empty.id])
        let other = o2

        host.tabSidebarModel.moveGroup(group.id, to: .end, after: false)

        #expect(titles(host) == ["h1", "o1"])
        #expect(titles(other) == ["o2"])
        #expect(host.folderSpace.folderIDs == [full.id, empty.id])
        #expect(other.folderSpace.folderIDs.isEmpty)
        #expect(store[empty.id]?.groupID == group.id)
        #expect(store[full.id]?.groupID == group.id)
        #expect(o1.userTabFolderID == full.id)
    }

    @Test func anEmptyFolderMovesOutOfItsGroup() throws {
        let store = UserTabFolderStore.shared
        let groups = UserTabGroupStore.shared
        let group = groups.create(name: "Personal")
        let kept = store.create(path: "/tmp/cross-window-kept")
        let empty = store.create(path: "/tmp/cross-window-moved")
        store.update(kept.id) { $0.groupID = group.id }
        store.update(empty.id) { $0.groupID = group.id }
        let h1 = tab("h1")
        let o1 = tab("o1", folder: kept.id)
        defer {
            close([h1, o1])
            store.remove(kept.id)
            store.remove(empty.id)
            groups.remove(group.id)
        }
        let host = try window([h1])
        let other = try window([o1], folders: [kept.id, empty.id])

        host.tabSidebarModel.moveFolder(empty.id, to: .end, after: false)

        #expect(host.folderSpace.folderIDs == [empty.id])
        #expect(other.folderSpace.folderIDs == [kept.id])
        #expect(store[empty.id]?.groupID == nil)
        #expect(groups[group.id] != nil)
    }

    /// A group holds sessions and folders alike: a session group dropped into it goes
    /// in beside its folders, and a folder dropped into it beside its session groups.
    @Test func aGroupHoldsSessionGroupsAndFoldersTogether() throws {
        let store = UserTabFolderStore.shared
        let groups = UserTabGroupStore.shared
        let other = groups.create(name: "Other")
        let finance = groups.create(name: "Finance")
        let site = store.create(path: "/tmp/cross-window-site")
        let plugin = store.create(path: "/tmp/cross-window-plugin")
        store.update(site.id) { $0.groupID = other.id }
        let f1 = tab("f1", group: finance.id)
        let f2 = tab("f2", group: finance.id)
        let s1 = tab("s1", folder: site.id)
        let loose = tab("loose")
        defer {
            close([f1, f2, s1, loose])
            store.remove(site.id)
            store.remove(plugin.id)
            [other, finance].forEach { groups.remove($0.id) }
        }
        let host = try window([f1, f2, s1, loose], folders: [site.id, plugin.id])
        let model = host.tabSidebarModel

        model.drop(group: finance.id, ontoGroup: other.id)
        #expect(groups[finance.id]?.parentID == other.id)
        #expect(f1.userTabFolderID == nil)
        #expect(titles(host) == ["f1", "f2", "s1", "loose"])

        model.drop(folder: plugin.id, ontoGroup: other.id)
        #expect(store[plugin.id]?.groupID == other.id)

        // The group holds folders now, so it can't go in a folder.
        model.add(group: other.id, toFolder: site.id)
        #expect(groups[other.id]?.parentID == nil)
        #expect(store[site.id]?.groupID == other.id)
        model.isActive = true
        model.refreshNow()
        guard case .group(let section)? = model.rows.first else {
            Issue.record("the group is the first row")
            return
        }
        #expect(section.group.id == other.id)
        #expect(section.rows.map(\.id).count == 3)
        #expect(section.folders.map(\.folder.id) == [site.id, plugin.id])
        #expect(section.tabs.map(\.title) == ["f1", "f2", "s1"])
    }
}

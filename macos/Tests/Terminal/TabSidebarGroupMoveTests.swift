import AppKit
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TabSidebarGroupMoveTests {
    private let a = UUID()
    private let b = UUID()

    /// Tabs `a1 a2 | loose | b1 b2 b3`, named by their title.
    private func windows() -> [NSWindow] {
        [("a1", a), ("a2", a), ("loose", nil), ("b1", b), ("b2", b), ("b3", b)].map { title, group in
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.title = title
            window.userTabGroupID = group
            return window
        }
    }

    private func titles(_ order: [NSWindow]?) -> [String]? {
        order?.map(\.title)
    }

    private func window(_ title: String, in windows: [NSWindow]) throws -> TerminalWindow {
        try #require(windows.first { $0.title == title } as? TerminalWindow)
    }

    @Test func aGroupMovesPastAnotherGroupWhole() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, moving: .group(b), to: .group(a), after: false)?.order)
            == ["b1", "b2", "b3", "a1", "a2", "loose"])
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .group(b), after: true)?.order)
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDroppedOnATabGoesNextToItOrItsGroup() throws {
        let windows = windows()
        let loose = try window("loose", in: windows)
        #expect(titles(TabSidebarModel.order(windows, moving: .group(b), to: .tab(loose), after: false)?.order)
            == ["a1", "a2", "b1", "b2", "b3", "loose"])

        // Dropped below a tab in the middle of another group, it goes in that group there,
        // since a group holds groups; beside the group's header it goes after all of it.
        let b2 = try window("b2", in: windows)
        let inside = TabSidebarModel.order(windows, moving: .group(a), to: .tab(b2), after: true)
        #expect(titles(inside?.order) == ["loose", "b1", "b2", "a1", "a2", "b3"])
        #expect(inside?.path == [.group(b)])
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .group(b), after: true)?.order)
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupMovesToTheEnd() {
        let windows = windows()
        #expect(titles(TabSidebarModel.order(windows, moving: .group(a), to: .end, after: false)?.order)
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }

    @Test func aGroupDoesNotMoveOntoItself() throws {
        let windows = windows()
        let a2 = try window("a2", in: windows)
        #expect(TabSidebarModel.order(windows, moving: .group(a), to: .group(a), after: false) == nil)
        #expect(TabSidebarModel.order(windows, moving: .group(a), to: .tab(a2), after: false) == nil)
        #expect(TabSidebarModel.order(windows, moving: .group(UUID()), to: .end, after: false) == nil)
    }

    /// Groups in groups, as the stores know them: a tab's path is its group and the groups
    /// that is in, so an outer group moves with the groups inside it, and a group moves
    /// into another.
    @Test func aGroupMovesWithTheGroupsInsideIt() throws {
        let store = UserTabGroupStore.shared
        let outer = store.create(name: "Clients")
        let inner = store.create(name: "Acme", parentID: outer.id)
        let other = store.create(name: "Other")
        defer { [outer, inner, other].forEach { store.remove($0.id) } }

        let windows = [("o1", outer.id), ("i1", inner.id), ("i2", inner.id), ("loose", nil), ("x1", other.id)].map { title, group in
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            window.title = title
            window.userTabGroupID = group
            return window
        }

        // The outer group moves whole, inner group and all.
        #expect(titles(TabSidebarModel.order(windows, moving: .group(outer.id), to: .end, after: false)?.order)
            == ["loose", "x1", "o1", "i1", "i2"])

        // The inner group moves out of it, past the whole outer group, and takes no group.
        let moved = TabSidebarModel.order(windows, moving: .group(inner.id), to: .group(outer.id), after: true)
        #expect(titles(moved?.order) == ["o1", "i1", "i2", "loose", "x1"])
        #expect(moved?.path == [])

        // Another group moves into the outer group, at its start, and takes it.
        let into = TabSidebarModel.order(windows, moving: .group(other.id), to: .inside(.group(outer.id)), after: false)
        #expect(titles(into?.order) == ["x1", "o1", "i1", "i2", "loose"])
        #expect(into?.path == [.group(outer.id)])

        // Not into the group inside it.
        #expect(TabSidebarModel.order(windows, moving: .group(outer.id), to: .inside(.group(inner.id)), after: false) == nil)
    }

    @Test func aFolderMovesWithItsGroupsPastAnotherFolder() throws {
        let windows = windows()
        let f1 = UUID()
        let f2 = UUID()
        for title in ["a1", "a2"] { try window(title, in: windows).userTabFolderID = f1 }
        for title in ["loose", "b1", "b2", "b3"] { try window(title, in: windows).userTabFolderID = f2 }
        let b2 = try window("b2", in: windows)
        #expect(titles(TabSidebarModel.order(windows, moving: .folder(f1), to: .tab(b2), after: true)?.order)
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
        #expect(titles(TabSidebarModel.order(windows, moving: .folder(f2), to: .folder(f1), after: false)?.order)
            == ["loose", "b1", "b2", "b3", "a1", "a2"])
    }
}

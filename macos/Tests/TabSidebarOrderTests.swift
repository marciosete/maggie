//
//  TabSidebarOrderTests.swift
//  GhosttyTests
//
//  Tests for the order the tab sidebar keeps folder groups, folders, groups and
//  sessions in, with groups in groups and folder groups in folder groups.
//

import Foundation
import Testing
@testable import Ghostty

struct TabSidebarOrderTests {
    private struct Item: TabSidebarOrderItem, CustomStringConvertible {
        let name: String
        let path: [TabSidebarOrder.Block]

        var description: String { name }
    }

    private typealias Block = TabSidebarOrder.Block

    private let g1 = UUID()
    private let g2 = UUID()
    private let f1 = UUID()
    private let f2 = UUID()
    private let fg1 = UUID()
    private let fg2 = UUID()

    /// A tab in `folderGroups`, each in the one before, then `folder`, then `groups`,
    /// each in the one before.
    private func deep(_ name: String, groups: [UUID] = [], folder: UUID? = nil, folderGroups: [UUID] = []) -> Item {
        Item(name: name, path: folderGroups.map(Block.folderGroup) + (folder.map { [Block.folder($0)] } ?? []) + groups.map(Block.group))
    }

    private func item(_ name: String, group: UUID? = nil, folder: UUID? = nil, folderGroup: UUID? = nil) -> Item {
        deep(name, groups: group.map { [$0] } ?? [], folder: folder, folderGroups: folderGroup.map { [$0] } ?? [])
    }

    private func names(_ items: [Item]?) -> [String] {
        items?.map(\.name) ?? []
    }

    // MARK: Nesting

    @Test func nestedKeepsPlainTabsInPlace() {
        let items = [item("a"), item("b"), item("c")]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "b", "c"])
    }

    @Test func nestedPullsAGroupTogetherWhereItsFirstMemberIs() {
        let items = [item("a", group: g1), item("b"), item("c", group: g1)]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b"])
    }

    @Test func nestedPullsAFolderTogetherWhereItsFirstMemberIs() {
        let items = [item("a", folder: f1), item("b"), item("c", folder: f1), item("d")]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    @Test func nestedKeepsGroupsTogetherInsideAFolder() {
        let items = [
            item("a", group: g1, folder: f1),
            item("b", folder: f1),
            item("c", group: g1, folder: f1),
            item("d"),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    @Test func nestedKeepsFoldersTogetherInsideAFolderGroup() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg1),
            item("c"),
            item("d", folder: f1, folderGroup: fg1),
            item("e", folder: f2, folderGroup: fg1),
        ]
        // f1 pulls d in, and the folder group pulls e in behind the rest of its folder.
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "d", "b", "e", "c"])
    }

    @Test func nestedLeavesAGroupOutsideAFolderAlone() {
        let items = [item("a", group: g1), item("b", folder: f1), item("c", group: g1), item("d", folder: f1)]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "b", "d"])
    }

    @Test func nestedKeepsAGroupTogetherInsideItsGroup() {
        // g2 is in g1. A tab of g1 between g2's tabs moves behind them, and a tab of g2
        // outside g1's run comes in behind the rest of g2.
        let items = [
            deep("a", groups: [g1, g2]),
            deep("b", groups: [g1]),
            deep("c", groups: [g1, g2]),
            item("d"),
            deep("e", groups: [g1, g2]),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "e", "b", "d"])
    }

    @Test func nestedKeepsAFolderGroupTogetherInsideItsFolderGroup() {
        // fg2 is in fg1, with f2; f1 is in fg1 directly.
        let items = [
            deep("a", folder: f2, folderGroups: [fg1, fg2]),
            deep("b", folder: f1, folderGroups: [fg1]),
            item("c"),
            deep("d", folder: f2, folderGroups: [fg1, fg2]),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "d", "b", "c"])
    }

    // MARK: Moving a group

    @Test func groupDroppedByATabInAGroupGoesInThere() {
        // A group holds groups, so dropped below a tab of another group it goes in that
        // group, just there; beside the group's header it goes past the whole group.
        let items = [item("a", group: g1), item("b", group: g2), item("c", group: g2), item("d")]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c", "d"])
        let beside = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.group(g2)), after: true)
        #expect(names(beside) == ["b", "c", "a", "d"])
    }

    @Test func groupMovesBeforeATab() {
        let items = [item("a"), item("b", group: g1), item("c", group: g1), item("d")]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .item(items[0]), after: false)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func groupMovesToTheEnd() {
        let items = [item("a", group: g1), item("b", group: g1), item("c")]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .end, after: false)
        #expect(names(order) == ["c", "a", "b"])
    }

    @Test func groupCannotMoveNextToItself() {
        let items = [item("a", group: g1), item("b", group: g1), item("c")]
        #expect(TabSidebarOrder.order(items, moving: .group(g1), to: .item(items[1]), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(g1), to: .block(.group(g1)), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(g1), to: .into(.group(g1)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(g2), to: .end, after: true) == nil)
    }

    @Test func groupMovesNextToAnotherGroup() {
        let items = [item("a", group: g1), item("b"), item("c", group: g2), item("d", group: g2)]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.group(g2)), after: true)
        #expect(names(order) == ["b", "c", "d", "a"])
    }

    @Test func groupMovedNextToATabInAFolderGoesJustThere() {
        let items = [item("a", group: g1), item("b", folder: f1), item("c", folder: f1)]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c"])
    }

    @Test func groupDroppedBesideAFolderGoesOutsideIt() {
        let items = [item("a", group: g1), item("b"), item("c", group: g2, folder: f1), item("d", group: g2, folder: f1), item("e")]
        let before = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.folder(f1)), after: false)
        #expect(names(before) == ["b", "a", "c", "d", "e"])
        let after = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.folder(f1)), after: true)
        #expect(names(after) == ["b", "c", "d", "a", "e"])
        // And takes no folder.
        let others = items.filter { !$0.path.contains(.group(g1)) }
        #expect(TabSidebarOrder.path(of: .group, droppedAt: .block(.folder(f1)), among: others) == [])
    }

    @Test func groupDroppedBesideAFolderInAFolderGroupGoesOutsideTheGroupToo() {
        let items = [
            item("a", group: g1),
            item("b", folder: f1, folderGroup: fg1),
            item("c", folder: f2, folderGroup: fg1),
        ]
        // Folder groups hold only folders, so after f1 means after the whole folder group.
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.folder(f1)), after: true)
        #expect(names(order) == ["b", "c", "a"])
    }

    @Test func groupMovedIntoAGroupGoesToItsStartAndTakesIt() {
        let items = [item("a", group: g1), item("b"), item("c", group: g2, folder: f1), item("d", group: g2, folder: f1)]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .into(.group(g2)), after: false)
        #expect(names(order) == ["b", "a", "c", "d"])
        let others = items.filter { !$0.path.contains(.group(g1)) }
        let path = TabSidebarOrder.path(of: .group, droppedAt: .into(.group(g2)), among: others)
        #expect(path == [.folder(f1), .group(g2)])
        #expect(path?.groupID == g2)
        #expect(path?.folderID == f1)
    }

    @Test func groupMovedBesideATabInAGroupJoinsThatGroup() {
        // A group can hold a group, so beside a tab in g2 means inside g2.
        let items = [item("a", group: g1), item("b", group: g2), item("c", group: g2)]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c"])
        let others = items.filter { !$0.path.contains(.group(g1)) }
        #expect(TabSidebarOrder.path(of: .group, droppedAt: .item(items[1]), among: others) == [.group(g2)])
    }

    @Test func groupMovedBesideAGroupInsideAGroupStaysInTheOuterGroup() {
        // g2 is in g1; a third group dropped after g2 lands in g1, beside g2.
        let g3 = UUID()
        let items = [deep("a", groups: [g3]), deep("b", groups: [g1, g2]), deep("c", groups: [g1]), deep("d")]
        let order = TabSidebarOrder.order(items, moving: .group(g3), to: .block(.group(g2)), after: true)
        #expect(names(order) == ["b", "a", "c", "d"])
        let others = items.filter { !$0.path.contains(.group(g3)) }
        #expect(TabSidebarOrder.path(of: .group, droppedAt: .block(.group(g2)), among: others) == [.group(g1)])
    }

    @Test func groupCannotMoveIntoAGroupInsideIt() {
        let items = [deep("a", groups: [g1, g2]), deep("b", groups: [g1]), deep("c")]
        #expect(TabSidebarOrder.order(items, moving: .group(g1), to: .into(.group(g2)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(g1), to: .block(.group(g2)), after: true) == nil)
    }

    @Test func aGroupInsideAGroupMovesWholeWithItsTabs() {
        // Moving the outer group takes the inner group's tabs along, in their order.
        let items = [deep("a", groups: [g1]), deep("b", groups: [g1, g2]), deep("c"), deep("d", groups: [g1, g2])]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .end, after: false)
        #expect(names(order) == ["c", "a", "b", "d"])
    }

    // MARK: Landing

    @Test func aTabBesideAGroupStaysInTheGroupsFolder() {
        let items = [item("a", group: g1, folder: f1), item("b", group: g1, folder: f1), item("c", folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: nil, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [.folder(f1)])
    }

    @Test func aTabBesideATabJoinsItsGroupAndFolder() {
        let items = [item("a", group: g1, folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 2, of: nil, among: items)
        #expect(names(landing.anchors) == ["a"])
        #expect(landing.path == [.folder(f1), .group(g1)])
    }

    @Test func aTabBesideAFolderInAFolderGroupLeavesBoth() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b", folder: f2, folderGroup: fg1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: nil, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [])
    }

    @Test func aFolderBesideALooseTabInAFolderMovesPastTheFolder() {
        // The tab is in no group, but it is in a folder, and a folder can't go in one.
        let items = [item("a", folder: f1), item("b", group: g1, folder: f1), item("c")]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .folder, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [])
    }

    @Test func aFolderBesideAFolderInAFolderGroupJoinsTheGroup() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b", folder: f2, folderGroup: fg1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .folder, among: items)
        #expect(names(landing.anchors) == ["a"])
        #expect(landing.path == [.folderGroup(fg1)])
    }

    @Test func aTabBesideATabInAGroupInAGroupJoinsTheInnerGroup() {
        let items = [deep("a", groups: [g1, g2], folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 3, of: nil, among: items)
        #expect(landing.path == [.folder(f1), .group(g1), .group(g2)])
        #expect(landing.path.groupID == g2)
    }

    @Test func groupDroppedOnAnEmptyFolderGoesToTheEnd() {
        let items = [item("a", group: g1), item("b")]
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.folder(f1)), after: false)
        #expect(names(order) == ["b", "a"])
    }

    // MARK: Moving a folder

    @Test func folderMovesPastAWholeTargetFolder() {
        let items = [
            item("a", folder: f1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
            item("d", group: g1, folder: f2),
            item("e"),
        ]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "d", "a", "e"])
    }

    @Test func folderMovesPastAWholeGroupOutsideAFolder() {
        let items = [item("a", folder: f1), item("b", group: g1), item("c", group: g1), item("d")]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func folderMovesNextToAGroupInsideAnotherFolder() {
        let items = [
            item("a", folder: f1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
        ]
        // Dropping before the group means before its whole folder.
        let before = TabSidebarOrder.order(items, moving: .folder(f1), to: .block(.group(g1)), after: false)
        #expect(names(before) == ["a", "b", "c"])
        let after = TabSidebarOrder.order(items, moving: .folder(f1), to: .block(.group(g1)), after: true)
        #expect(names(after) == ["b", "c", "a"])
    }

    @Test func folderMovesNextToAnotherFolder() {
        let items = [item("a", folder: f1), item("b"), item("c", folder: f2), item("d", folder: f2)]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .block(.folder(f2)), after: true)
        #expect(names(order) == ["b", "c", "d", "a"])
    }

    @Test func folderMovedNextToAnEmptyFolderGoesToTheEnd() {
        let items = [item("a", folder: f1), item("b")]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .block(.folder(f2)), after: false)
        #expect(names(order) == ["b", "a"])
    }

    @Test func folderMovedNextToAFolderInAGroupStaysInsideThatGroup() {
        // The folder joins the group (the caller sets its key), so it moves past the
        // target folder alone, not past the whole folder group.
        let items = [
            item("a", folder: f1),
            item("b", folder: f2, folderGroup: fg1),
            item("c", folder: UUID(), folderGroup: fg1),
        ]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c"])
    }

    @Test func folderCannotMoveNextToItself() {
        let items = [item("a", folder: f1), item("b", folder: f1), item("c")]
        #expect(TabSidebarOrder.order(items, moving: .folder(f1), to: .item(items[0]), after: true) == nil)
        #expect(TabSidebarOrder.order(items, moving: .folder(f1), to: .block(.folder(f1)), after: true) == nil)
    }

    @Test func folderMovedIntoAFolderGroupInsideAnotherTakesBoth() {
        let items = [deep("a", folder: f1), deep("b", folder: f2, folderGroups: [fg1, fg2]), deep("c")]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .into(.folderGroup(fg2)), after: false)
        #expect(names(order) == ["a", "b", "c"])
        let others = items.filter { !$0.path.contains(.folder(f1)) }
        let path = TabSidebarOrder.path(of: .folder, droppedAt: .into(.folderGroup(fg2)), among: others)
        #expect(path == [.folderGroup(fg1), .folderGroup(fg2)])
        #expect(path?.folderGroupID == fg2)
    }

    // MARK: Moving a folder group

    @Test func folderGroupDroppedByATabInAFolderGroupGoesInThere() {
        // A folder group holds folder groups, so dropped below a tab of a folder in another
        // folder group it goes in that group, after the folder; beside the group's header
        // it goes past the whole group.
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg2),
            item("c", folder: UUID(), folderGroup: fg2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c", "d"])
        let others = items.filter { !$0.path.contains(.folderGroup(fg1)) }
        #expect(TabSidebarOrder.path(of: .folderGroup, droppedAt: .item(items[1]), among: others) == [.folderGroup(fg2)])
        let beside = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .block(.folderGroup(fg2)), after: true)
        #expect(names(beside) == ["b", "c", "a", "d"])
    }

    @Test func folderGroupMovesPastAWholeLooseFolder() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .block(.group(g1)), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func folderGroupMovesToTheEnd() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b")]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .end, after: false)
        #expect(names(order) == ["b", "a"])
    }

    @Test func folderGroupMovedBesideAFolderInAFolderGroupJoinsThatGroup() {
        // A folder group can hold a folder group, so beside f2 in fg2 means inside fg2.
        let items = [item("a", folder: f1, folderGroup: fg1), item("b", folder: f2, folderGroup: fg2), item("c")]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .block(.folder(f2)), after: true)
        #expect(names(order) == ["b", "a", "c"])
        let others = items.filter { !$0.path.contains(.folderGroup(fg1)) }
        #expect(TabSidebarOrder.path(of: .folderGroup, droppedAt: .block(.folder(f2)), among: others) == [.folderGroup(fg2)])
    }

    @Test func folderGroupMovedIntoAFolderGroupGoesToItsStart() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b"), item("c", folder: f2, folderGroup: fg2)]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .into(.folderGroup(fg2)), after: false)
        #expect(names(order) == ["b", "a", "c"])
        let others = items.filter { !$0.path.contains(.folderGroup(fg1)) }
        #expect(TabSidebarOrder.path(of: .folderGroup, droppedAt: .into(.folderGroup(fg2)), among: others) == [.folderGroup(fg2)])
    }

    @Test func folderGroupCannotMoveIntoAFolderGroupInsideIt() {
        let items = [deep("a", folder: f1, folderGroups: [fg1, fg2]), deep("b", folder: f2, folderGroups: [fg1]), deep("c")]
        #expect(TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .into(.folderGroup(fg2)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .folderGroup(fg1), to: .block(.folder(f1)), after: true) == nil)
    }

    @Test func aFolderGroupInsideAFolderGroupMovesOutWhole() {
        // fg2 is in fg1. Moved to the end, it takes its folders' tabs and leaves fg1.
        let items = [
            deep("a", folder: f1, folderGroups: [fg1]),
            deep("b", folder: f2, folderGroups: [fg1, fg2]),
            deep("c", folder: f2, folderGroups: [fg1, fg2]),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .folderGroup(fg2), to: .end, after: false)
        #expect(names(order) == ["a", "d", "b", "c"])
        let others = items.filter { !$0.path.contains(.folderGroup(fg2)) }
        #expect(TabSidebarOrder.path(of: .folderGroup, droppedAt: .end, among: others) == nil)
    }
}

//
//  TabSidebarOrderTests.swift
//  GhosttyTests
//
//  Tests for the order the tab sidebar keeps groups, folders and sessions in, with
//  groups in groups and folders in groups.
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
    private typealias Dropped = TabSidebarOrder.Dropped

    private let g1 = UUID()
    private let g2 = UUID()
    private let f1 = UUID()
    private let f2 = UUID()
    private let fg1 = UUID()
    private let fg2 = UUID()

    /// A tab in `outerGroups`, each in the one before, then `folder`, then `groups`,
    /// each in the one before.
    private func deep(_ name: String, groups: [UUID] = [], folder: UUID? = nil, outerGroups: [UUID] = []) -> Item {
        Item(name: name, path: outerGroups.map(Block.group) + (folder.map { [Block.folder($0)] } ?? []) + groups.map(Block.group))
    }

    private func item(_ name: String, group: UUID? = nil, folder: UUID? = nil, folderGroup: UUID? = nil) -> Item {
        deep(name, groups: group.map { [$0] } ?? [], folder: folder, outerGroups: folderGroup.map { [$0] } ?? [])
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

    @Test func nestedKeepsFoldersTogetherInsideAGroup() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg1),
            item("c"),
            item("d", folder: f1, folderGroup: fg1),
            item("e", folder: f2, folderGroup: fg1),
        ]
        // f1 pulls d in, and the group pulls e in behind the rest of its folder.
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "d", "b", "e", "c"])
    }

    @Test func nestedKeepsSessionsAndFoldersOfOneGroupTogether() {
        // A group holds a session group, a folder and a loose session alike.
        let items = [
            deep("a", groups: [fg1, g1]),
            item("b"),
            deep("c", folder: f1, outerGroups: [fg1]),
            deep("d", groups: [fg1]),
            deep("e", groups: [fg1, g1]),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "e", "c", "d", "b"])
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
            deep("d"),
            deep("e", groups: [g1, g2]),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "c", "e", "b", "d"])
    }

    @Test func nestedKeepsAGroupOfFoldersTogetherInsideItsGroup() {
        // fg2 is in fg1, with f2; f1 is in fg1 directly.
        let items = [
            deep("a", folder: f2, outerGroups: [fg1, fg2]),
            deep("b", folder: f1, outerGroups: [fg1]),
            deep("c"),
            deep("d", folder: f2, outerGroups: [fg1, fg2]),
        ]
        #expect(names(TabSidebarOrder.nested(items)) == ["a", "d", "b", "c"])
    }

    // MARK: What is dropped

    @Test func aGroupWithAFolderInItHoldsFolders() {
        let items = [deep("a", groups: [g1]), deep("b", folder: f1, outerGroups: [g1]), deep("c", groups: [g2])]
        #expect(Dropped(.group(g1), members: items.filter { $0.path.contains(.group(g1)) }) == .groupOfFolders)
        #expect(Dropped(.group(g2), members: items.filter { $0.path.contains(.group(g2)) }) == .group)
        #expect(Dropped(.folder(f1), members: [items[1]]) == .folder)
    }

    @Test func whatAContainerHolds() {
        let top: ArraySlice<Block> = []
        #expect(TabSidebarOrder.canHold(containers: top, .folder))
        #expect(TabSidebarOrder.canHold(containers: [.group(g1)], .folder))
        #expect(TabSidebarOrder.canHold(containers: [.group(g1)], .groupOfFolders))
        #expect(!TabSidebarOrder.canHold(containers: [.folder(f1)], .folder))
        #expect(!TabSidebarOrder.canHold(containers: [.folder(f1), .group(g1)], .folder))
        #expect(!TabSidebarOrder.canHold(containers: [.folder(f1), .group(g1)], .groupOfFolders))
        #expect(TabSidebarOrder.canHold(containers: [.folder(f1), .group(g1)], .group))
        #expect(TabSidebarOrder.canHold(containers: [.folder(f1)], .tab))
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

    @Test func groupDroppedBesideAFolderInAGroupJoinsThatGroup() {
        let items = [
            item("a", group: g1),
            item("b", folder: f1, folderGroup: fg1),
            item("c", folder: f2, folderGroup: fg1),
        ]
        // A group holds groups, so after f1 means in fg1, after f1.
        let order = TabSidebarOrder.order(items, moving: .group(g1), to: .block(.folder(f1)), after: true)
        #expect(names(order) == ["b", "a", "c"])
        let others = items.filter { !$0.path.contains(.group(g1)) }
        #expect(TabSidebarOrder.path(of: .group, droppedAt: .block(.folder(f1)), among: others) == [.group(fg1)])
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

    @Test func aGroupWithFoldersInItStaysOutsideFolders() {
        // fg1 holds f1; dropped by a tab in a group in folder f2, it goes past the whole
        // folder, and it can't go into the folder or the group in it.
        let items = [
            deep("a", folder: f1, outerGroups: [fg1]),
            deep("b", groups: [fg1]),
            deep("c", groups: [g1], folder: f2),
            deep("d", folder: f2),
            deep("e"),
        ]
        let order = TabSidebarOrder.order(items, moving: .group(fg1), to: .item(items[2]), after: true)
        #expect(names(order) == ["c", "d", "a", "b", "e"])
        let others = items.filter { !$0.path.contains(.group(fg1)) }
        #expect(TabSidebarOrder.path(of: .groupOfFolders, droppedAt: .item(items[2]), among: others) == [])
        #expect(TabSidebarOrder.order(items, moving: .group(fg1), to: .into(.folder(f2)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(fg1), to: .into(.group(g1)), after: false) == nil)

        // A group without folders goes in.
        #expect(names(TabSidebarOrder.order(items, moving: .group(g1), to: .into(.group(fg1)), after: false)) == ["c", "a", "b", "d", "e"])
    }

    // MARK: Landing

    @Test func aTabBesideAGroupStaysInTheGroupsFolder() {
        let items = [item("a", group: g1, folder: f1), item("b", group: g1, folder: f1), item("c", folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .tab, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [.folder(f1)])
    }

    @Test func aTabBesideATabJoinsItsGroupAndFolder() {
        let items = [item("a", group: g1, folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 2, of: .tab, among: items)
        #expect(names(landing.anchors) == ["a"])
        #expect(landing.path == [.folder(f1), .group(g1)])
    }

    @Test func aTabBesideAFolderInAGroupStaysInTheGroup() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b", folder: f2, folderGroup: fg1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .tab, among: items)
        #expect(names(landing.anchors) == ["a"])
        #expect(landing.path == [.group(fg1)])
        #expect(landing.path.groupID == fg1)
        #expect(landing.path.folderID == nil)
    }

    @Test func aFolderBesideALooseTabInAFolderMovesPastTheFolder() {
        // The tab is in no group, but it is in a folder, and a folder can't go in one.
        let items = [item("a", folder: f1), item("b", group: g1, folder: f1), item("c")]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .folder, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [])
    }

    @Test func aFolderBesideAFolderInAGroupJoinsTheGroup() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b", folder: f2, folderGroup: fg1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 1, of: .folder, among: items)
        #expect(names(landing.anchors) == ["a"])
        #expect(landing.path == [.group(fg1)])
        #expect(landing.path.outerGroupID == fg1)
    }

    @Test func aFolderBesideATabInAGroupInAFolderMovesPastTheFolder() {
        // The group g1 is in folder f1, which is in group fg1: the folder lands in fg1.
        let items = [deep("a", groups: [g1], folder: f1, outerGroups: [fg1]), deep("b", folder: f1, outerGroups: [fg1])]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 3, of: .folder, among: items)
        #expect(names(landing.anchors) == ["a", "b"])
        #expect(landing.path == [.group(fg1)])
    }

    @Test func aTabBesideATabInAGroupInAGroupJoinsTheInnerGroup() {
        let items = [deep("a", groups: [g1, g2], folder: f1)]
        let landing = TabSidebarOrder.landing(beside: items[0], from: 3, of: .tab, among: items)
        #expect(landing.path == [.folder(f1), .group(g1), .group(g2)])
        #expect(landing.path.groupID == g2)
    }

    @Test func thePathTellsAFoldersGroupFromATabsGroup() {
        // In [fg1, f1, g1], a tab or group is in g1 and a folder is in fg1; in [fg1, f1] a
        // tab is in the folder alone.
        let path: [Block] = [.group(fg1), .folder(f1), .group(g1)]
        #expect(path.groupID == g1)
        #expect(path.outerGroupID == fg1)
        #expect(path.folderID == f1)
        #expect(path.groupIDs == [fg1, g1])
        let inFolder: [Block] = [.group(fg1), .folder(f1)]
        #expect(inFolder.groupID == nil)
        #expect(inFolder.outerGroupID == fg1)
        let noFolder: [Block] = [.group(fg1), .group(g1)]
        #expect(noFolder.groupID == g1)
        #expect(noFolder.outerGroupID == g1)
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

    @Test func folderMovedByATabInAGroupGoesInTheGroup() {
        // A group holds folders, so beside a tab in g1 means in g1, beside the tab.
        let items = [item("a", folder: f1), item("b", group: g1), item("c", group: g1), item("d")]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c", "d"])
        let others = items.filter { !$0.path.contains(.folder(f1)) }
        #expect(TabSidebarOrder.path(of: .folder, droppedAt: .item(items[1]), among: others) == [.group(g1)])
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
        // target folder alone, not past the whole group.
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

    @Test func folderCannotMoveIntoAFolderOrAGroupInOne() {
        let items = [item("a", folder: f1), item("b", group: g1, folder: f2), item("c")]
        #expect(TabSidebarOrder.order(items, moving: .folder(f1), to: .into(.folder(f2)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .folder(f1), to: .into(.group(g1)), after: false) == nil)
    }

    @Test func folderMovedIntoAGroupInsideAnotherTakesBoth() {
        let items = [item("a", folder: f1), deep("b", folder: f2, outerGroups: [fg1, fg2]), item("c")]
        let order = TabSidebarOrder.order(items, moving: .folder(f1), to: .into(.group(fg2)), after: false)
        #expect(names(order) == ["a", "b", "c"])
        let others = items.filter { !$0.path.contains(.folder(f1)) }
        let path = TabSidebarOrder.path(of: .folder, droppedAt: .into(.group(fg2)), among: others)
        #expect(path == [.group(fg1), .group(fg2)])
        #expect(path?.outerGroupID == fg2)
    }

    // MARK: Moving a group of folders

    @Test func groupOfFoldersDroppedByATabInAFolderInAGroupGoesInThere() {
        // A group holds groups, so dropped below a tab of a folder in another group it
        // goes in that group, after the folder; beside the group's header it goes past
        // the whole group.
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2, folderGroup: fg2),
            item("c", folder: UUID(), folderGroup: fg2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .group(fg1), to: .item(items[1]), after: true)
        #expect(names(order) == ["b", "a", "c", "d"])
        let others = items.filter { !$0.path.contains(.group(fg1)) }
        #expect(TabSidebarOrder.path(of: .groupOfFolders, droppedAt: .item(items[1]), among: others) == [.group(fg2)])
        let beside = TabSidebarOrder.order(items, moving: .group(fg1), to: .block(.group(fg2)), after: true)
        #expect(names(beside) == ["b", "c", "a", "d"])
    }

    @Test func groupOfFoldersMovesPastAWholeLooseFolder() {
        let items = [
            item("a", folder: f1, folderGroup: fg1),
            item("b", folder: f2),
            item("c", group: g1, folder: f2),
            item("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .group(fg1), to: .block(.group(g1)), after: true)
        #expect(names(order) == ["b", "c", "a", "d"])
    }

    @Test func groupOfFoldersMovesToTheEnd() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b")]
        let order = TabSidebarOrder.order(items, moving: .group(fg1), to: .end, after: false)
        #expect(names(order) == ["b", "a"])
    }

    @Test func groupOfFoldersMovedIntoAGroupGoesToItsStart() {
        let items = [item("a", folder: f1, folderGroup: fg1), item("b"), item("c", folder: f2, folderGroup: fg2)]
        let order = TabSidebarOrder.order(items, moving: .group(fg1), to: .into(.group(fg2)), after: false)
        #expect(names(order) == ["b", "a", "c"])
        let others = items.filter { !$0.path.contains(.group(fg1)) }
        #expect(TabSidebarOrder.path(of: .groupOfFolders, droppedAt: .into(.group(fg2)), among: others) == [.group(fg2)])
    }

    @Test func groupOfFoldersCannotMoveIntoAGroupInsideIt() {
        let items = [deep("a", folder: f1, outerGroups: [fg1, fg2]), deep("b", folder: f2, outerGroups: [fg1]), deep("c")]
        #expect(TabSidebarOrder.order(items, moving: .group(fg1), to: .into(.group(fg2)), after: false) == nil)
        #expect(TabSidebarOrder.order(items, moving: .group(fg1), to: .block(.folder(f1)), after: true) == nil)
    }

    @Test func aGroupOfFoldersInsideAGroupMovesOutWhole() {
        // fg2 is in fg1. Moved to the end, it takes its folders' tabs and leaves fg1.
        let items = [
            deep("a", folder: f1, outerGroups: [fg1]),
            deep("b", folder: f2, outerGroups: [fg1, fg2]),
            deep("c", folder: f2, outerGroups: [fg1, fg2]),
            deep("d"),
        ]
        let order = TabSidebarOrder.order(items, moving: .group(fg2), to: .end, after: false)
        #expect(names(order) == ["a", "d", "b", "c"])
        let others = items.filter { !$0.path.contains(.group(fg2)) }
        #expect(TabSidebarOrder.path(of: .groupOfFolders, droppedAt: .end, among: others) == nil)
    }
}

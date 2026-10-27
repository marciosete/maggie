import Foundation

/// Something the sidebar orders: a tab, with what it is nested in.
protocol TabSidebarOrderItem: Equatable {
    /// What the tab is in, outermost first: its folder groups, each in the one before,
    /// then its folder, then its groups, each in the one before. Empty for a tab in
    /// nothing. Items in the same block have the same path up to it.
    var path: [TabSidebarOrder.Block] { get }
}

/// The order the sidebar keeps the native tabs in, on items that stand for the tabs so
/// it can be checked without windows. At every depth, the members of a block (a folder
/// group, a folder, a group) are next to each other, where its first member is, and the
/// blocks inside it are too. A block is in at most one outer block: the caller keeps the
/// paths consistent, giving a group the folder of its first member.
enum TabSidebarOrder {
    /// The kinds of block, by what they hold: a folder group holds folders and folder
    /// groups; a folder holds tabs and groups; a group holds tabs and groups.
    enum Kind: Hashable {
        case folderGroup
        case folder
        case group
    }

    /// A folder group, a folder or a group.
    struct Block: Hashable {
        let kind: Kind
        let id: UUID

        static func group(_ id: UUID) -> Block { Block(kind: .group, id: id) }
        static func folder(_ id: UUID) -> Block { Block(kind: .folder, id: id) }
        static func folderGroup(_ id: UUID) -> Block { Block(kind: .folderGroup, id: id) }
    }

    /// Where a block is dropped.
    enum Destination<Item> {
        /// Next to a tab, or next to whatever it is in that can't hold the dropped block.
        case item(Item)

        /// Next to another block, or whatever it is in that can't hold the dropped block.
        /// Next to a block with no tabs, such as an empty folder, is the end.
        case block(Block)

        /// At the start of a block, inside it. Into a block with no tabs is the end.
        case into(Block)

        /// After every tab.
        case end
    }

    /// `items` with the members of every block next to each other, each block where its
    /// first member is.
    static func nested<Item: TabSidebarOrderItem>(_ items: [Item]) -> [Item] {
        nested(items, from: 0)
    }

    private static func nested<Item: TabSidebarOrderItem>(_ items: [Item], from depth: Int) -> [Item] {
        var result: [Item] = []
        var seen = Set<Block>()
        for item in items {
            // An item in nothing from this depth on is on its own.
            guard item.path.count > depth else {
                result.append(item)
                continue
            }
            let block = item.path[depth]
            guard seen.insert(block).inserted else { continue }

            // Items in the same block at this depth. One in it at another depth is in
            // a different outer block, so it is elsewhere.
            let members = items.filter { $0.path.count > depth && $0.path[depth] == block }
            result.append(contentsOf: nested(members, from: depth + 1))
        }
        return result
    }

    /// What a block of `container` holds directly: a group holds tabs and groups; a
    /// folder holds tabs and groups; a folder group holds folders and folder groups.
    /// `kind` is nil for a tab.
    static func canHold(container: Kind, kind: Kind?) -> Bool {
        switch container {
        case .group, .folder: return kind == nil || kind == .group
        case .folderGroup: return kind == .folder || kind == .folderGroup
        }
    }

    /// Where something of `kind` (nil for a tab) lands when dropped beside `target`,
    /// from the block at `startDepth` of its path out (`target` itself when `startDepth`
    /// is the path's count): the items it moves past, and the path it takes. Beside a tab
    /// in a group, a tab joins the group; beside a group, a tab goes in whatever the group
    /// is in, next to all of the group. Beside a folder that is in a folder group, a tab or
    /// a group can't stay in the folder group, so it goes next to the whole folder group,
    /// in nothing. The anchor widens until its container can hold what is dropped.
    static func landing<Item: TabSidebarOrderItem>(
        beside target: Item,
        from startDepth: Int,
        of kind: Kind?,
        among others: [Item]
    ) -> (anchors: [Item], path: [Block]) {
        let depth = target.path.count
        var anchorDepth = min(startDepth, depth)
        while anchorDepth > 0, !canHold(container: target.path[anchorDepth - 1].kind, kind: kind) {
            anchorDepth -= 1
        }

        let anchors: [Item]
        if anchorDepth >= depth {
            anchors = [target]
        } else {
            let block = target.path[anchorDepth]
            anchors = others.filter { $0.path.count > anchorDepth && $0.path[anchorDepth] == block }
        }
        return (anchors, Array(target.path.prefix(anchorDepth)))
    }

    /// The path something of `kind` takes when dropped at `destination`: nil when there
    /// is nothing there to take it from (the end, or a block with no tabs).
    static func path<Item: TabSidebarOrderItem>(
        of kind: Kind?,
        droppedAt destination: Destination<Item>,
        among others: [Item]
    ) -> [Block]? {
        switch destination {
        case .item(let target):
            return landing(beside: target, from: target.path.count, of: kind, among: others).path
        case .block(let target):
            guard let first = others.first(where: { $0.path.contains(target) }),
                  let depth = first.path.firstIndex(of: target) else { return nil }
            return landing(beside: first, from: depth, of: kind, among: others).path
        case .into(let target):
            guard let first = others.first(where: { $0.path.contains(target) }),
                  let depth = first.path.firstIndex(of: target) else { return nil }
            return Array(first.path.prefix(through: depth))
        case .end:
            return nil
        }
    }

    /// `items` with the members of `block` moved to `destination`, keeping their order,
    /// or nil when the move makes no sense, such as next to one of its own members or
    /// into a block inside it. The block moves past what `landing` says it does beside
    /// the target; the caller gives its members the path `landing` says they take.
    static func order<Item: TabSidebarOrderItem>(
        _ items: [Item],
        moving block: Block,
        to destination: Destination<Item>,
        after: Bool
    ) -> [Item]? {
        let members = items.filter { $0.path.contains(block) }
        guard !members.isEmpty else { return nil }
        let others = items.filter { !$0.path.contains(block) }

        // Whether `target` is inside the moving block: in some member's path, after it.
        func isInside(_ target: Block) -> Bool {
            members.contains { member in
                guard let blockDepth = member.path.firstIndex(of: block),
                      let targetDepth = member.path.firstIndex(of: target) else { return false }
                return targetDepth > blockDepth
            }
        }

        let anchors: [Item]
        switch destination {
        case .item(let target):
            guard !target.path.contains(block) else { return nil }
            anchors = landing(beside: target, from: target.path.count, of: block.kind, among: others).anchors

        case .block(let target):
            guard target != block, !isInside(target) else { return nil }
            if let first = others.first(where: { $0.path.contains(target) }),
               let depth = first.path.firstIndex(of: target) {
                anchors = landing(beside: first, from: depth, of: block.kind, among: others).anchors
            } else {
                anchors = []
            }

        case .into(let target):
            guard target != block, !isInside(target) else { return nil }
            anchors = others.filter { $0.path.contains(target) }

        case .end:
            anchors = []
        }

        let index: Int
        if anchors.isEmpty {
            index = others.count
        } else if after {
            guard let last = anchors.last, let position = others.firstIndex(of: last) else { return nil }
            index = position + 1
        } else {
            guard let first = anchors.first, let position = others.firstIndex(of: first) else { return nil }
            index = position
        }

        var order = others
        order.insert(contentsOf: members, at: index)
        return order
    }
}

extension Array where Element == TabSidebarOrder.Block {
    /// The folder in the path, if any.
    var folderID: UUID? { first { $0.kind == .folder }?.id }

    /// The innermost group in the path, if any: what a tab or a group dropped here is in.
    var groupID: UUID? { last { $0.kind == .group }?.id }

    /// The innermost folder group in the path, if any: what a folder or a folder group
    /// dropped here is in.
    var folderGroupID: UUID? { last { $0.kind == .folderGroup }?.id }
}

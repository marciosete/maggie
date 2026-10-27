import Foundation

/// Something the sidebar orders: a tab, with what it is nested in.
protocol TabSidebarOrderItem: Equatable {
    /// What the tab is in, outermost first: the groups its folder is in, each in the one
    /// before, then its folder, then its groups, each in the one before. Empty for a tab
    /// in nothing. Items in the same block have the same path up to it.
    var path: [TabSidebarOrder.Block] { get }
}

/// The order the sidebar keeps the native tabs in, on items that stand for the tabs so
/// it can be checked without windows. At every depth, the members of a block (a group,
/// a folder) are next to each other, where its first member is, and the blocks inside
/// it are too. A block is in at most one outer block: the caller keeps the paths
/// consistent, giving a group the folder of its first member.
enum TabSidebarOrder {
    /// The kinds of block, by what they hold: a group holds tabs, groups and folders,
    /// though not a folder once it is in a folder itself; a folder holds tabs and groups.
    enum Kind: Hashable {
        case group
        case folder
    }

    /// A group or a folder.
    struct Block: Hashable {
        let kind: Kind
        let id: UUID

        static func group(_ id: UUID) -> Block { Block(kind: .group, id: id) }
        static func folder(_ id: UUID) -> Block { Block(kind: .folder, id: id) }
    }

    /// What is dropped: a tab, a group, a folder, or a group with folders in it, which,
    /// like a folder, can't go in a folder.
    struct Dropped: Equatable {
        /// Nil for a tab.
        let kind: Kind?

        /// Whether it holds folders, or is one, so it stays outside every folder.
        let staysOutsideFolders: Bool

        static let tab = Dropped(kind: nil, staysOutsideFolders: false)
        static let group = Dropped(kind: .group, staysOutsideFolders: false)
        static let folder = Dropped(kind: .folder, staysOutsideFolders: true)
        static let groupOfFolders = Dropped(kind: .group, staysOutsideFolders: true)

        /// The block as it is dropped, by its members: a group with a folder in it, in
        /// any member's path after it, holds folders.
        init<Item: TabSidebarOrderItem>(_ block: Block, members: [Item]) {
            switch block.kind {
            case .folder:
                self = .folder
            case .group:
                let holdsFolders = members.contains { member in
                    guard let depth = member.path.firstIndex(of: block) else { return false }
                    return member.path[(depth + 1)...].contains { $0.kind == .folder }
                }
                self = holdsFolders ? .groupOfFolders : .group
            }
        }

        private init(kind: Kind?, staysOutsideFolders: Bool) {
            self.kind = kind
            self.staysOutsideFolders = staysOutsideFolders
        }
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

    /// Whether the innermost of `containers` holds `dropped` directly: the top (no
    /// containers) holds everything; a folder holds a tab or a group without folders; a
    /// group holds a tab or a group, and a folder or a group of folders while it is in
    /// no folder itself.
    static func canHold(containers: ArraySlice<Block>, _ dropped: Dropped) -> Bool {
        guard let container = containers.last else { return true }
        guard dropped.staysOutsideFolders else { return true }
        return container.kind == .group && !containers.contains { $0.kind == .folder }
    }

    /// Where `dropped` lands when dropped beside `target`, from the block at `startDepth`
    /// of its path out (`target` itself when `startDepth` is the path's count): the items
    /// it moves past, and the path it takes. Beside a tab in a group, a tab joins the
    /// group; beside a group, a tab goes in whatever the group is in, next to all of the
    /// group. Beside a tab in a folder, a folder can't stay in the folder, so it goes next
    /// to the whole folder, in whatever that is. The anchor widens until its container
    /// can hold what is dropped.
    static func landing<Item: TabSidebarOrderItem>(
        beside target: Item,
        from startDepth: Int,
        of dropped: Dropped,
        among others: [Item]
    ) -> (anchors: [Item], path: [Block]) {
        let depth = target.path.count
        var anchorDepth = min(startDepth, depth)
        while anchorDepth > 0, !canHold(containers: target.path.prefix(anchorDepth), dropped) {
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

    /// The path `dropped` takes when dropped at `destination`: nil when there is nothing
    /// there to take it from (the end, or a block with no tabs).
    static func path<Item: TabSidebarOrderItem>(
        of dropped: Dropped,
        droppedAt destination: Destination<Item>,
        among others: [Item]
    ) -> [Block]? {
        switch destination {
        case .item(let target):
            return landing(beside: target, from: target.path.count, of: dropped, among: others).path
        case .block(let target):
            guard let first = others.first(where: { $0.path.contains(target) }),
                  let depth = first.path.firstIndex(of: target) else { return nil }
            return landing(beside: first, from: depth, of: dropped, among: others).path
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
        let dropped = Dropped(block, members: members)

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
            anchors = landing(beside: target, from: target.path.count, of: dropped, among: others).anchors

        case .block(let target):
            guard target != block, !isInside(target) else { return nil }
            if let first = others.first(where: { $0.path.contains(target) }),
               let depth = first.path.firstIndex(of: target) {
                anchors = landing(beside: first, from: depth, of: dropped, among: others).anchors
            } else {
                anchors = []
            }

        case .into(let target):
            guard target != block, !isInside(target) else { return nil }
            // What can't go in a folder doesn't go into one, or into a group in one.
            if let first = others.first(where: { $0.path.contains(target) }),
               let depth = first.path.firstIndex(of: target),
               !canHold(containers: first.path.prefix(through: depth), dropped) {
                return nil
            }
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

    /// The innermost group inside the folder, or the innermost group when there is no
    /// folder: what a tab or a group dropped here is in. Nil in a folder directly.
    var groupID: UUID? {
        let start = firstIndex { $0.kind == .folder }.map { $0 + 1 } ?? 0
        return self[start...].last { $0.kind == .group }?.id
    }

    /// The innermost group before the folder, or the innermost group when there is no
    /// folder: what a folder dropped here is in.
    var outerGroupID: UUID? {
        let end = firstIndex { $0.kind == .folder } ?? count
        return self[..<end].last { $0.kind == .group }?.id
    }

    /// Every group in the path, outermost first.
    var groupIDs: [UUID] { filter { $0.kind == .group }.map(\.id) }
}

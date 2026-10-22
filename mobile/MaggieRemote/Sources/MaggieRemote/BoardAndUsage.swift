import Foundation

/// The Mac's session board: its columns, and in each the work items and the sessions,
/// in the board's order.
public struct BoardSnapshot: Codable, Equatable, Sendable {
    public var columns: [BoardColumn]

    /// The work items, then the sessions linked to none, in each column's order.
    public var cards: [BoardCard]

    /// What the Mac's board shows; none from a Mac that doesn't say.
    public var mode: BoardMode?

    /// Every session, linked or not, in each column's order as the sessions view shows
    /// them. Empty from a Mac that doesn't send them.
    public var sessions: [BoardCard]

    public init(columns: [BoardColumn], cards: [BoardCard], mode: BoardMode? = nil, sessions: [BoardCard] = []) {
        self.columns = columns
        self.cards = cards
        self.mode = mode
        self.sessions = sessions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decode([BoardColumn].self, forKey: .columns)
        cards = try container.decode([BoardCard].self, forKey: .cards)
        mode = try container.decodeIfPresent(BoardMode.self, forKey: .mode)
        sessions = try container.decodeIfPresent([BoardCard].self, forKey: .sessions) ?? []
    }

    /// The cards of one column, in order.
    public func cards(in column: String) -> [BoardCard] {
        cards.filter { $0.column == column }
    }

    /// The work items in `column`, in order. None in the sessions view.
    public func items(in column: String, mode: BoardMode) -> [BoardCard] {
        guard mode != .sessions else { return [] }
        return cards.filter { $0.kind == .workItem && $0.column == column }
    }

    /// The sessions shown as cards of their own in `column`: all of them in the sessions
    /// view, none in the work items view, and those linked to no item when together.
    public func sessions(in column: String, mode: BoardMode) -> [BoardCard] {
        switch mode {
        case .workItems: return []
        case .together: return cards.filter { $0.kind == .session && $0.column == column }
        case .sessions:
            // A Mac that doesn't send every session sends the unlinked ones only.
            let all = sessions.isEmpty ? cards.filter { $0.kind == .session } : sessions
            return all.filter { $0.column == column }
        }
    }

    /// Moves a card to the end of another column, as the Mac will once it has the move,
    /// so the device can show it at once.
    public mutating func move(_ move: MoveCard) {
        func moved(_ cards: inout [BoardCard]) {
            guard let index = cards.firstIndex(where: { $0.kind == move.kind && $0.id == move.id }) else { return }
            var card = cards.remove(at: index)
            card.column = move.column
            cards.append(card)
        }
        moved(&cards)
        if move.kind == .session { moved(&sessions) }
    }

    /// The sessions linked to `item`, in the order the item lists them.
    public func sessions(of item: BoardCard) -> [BoardCard] {
        let byID = Dictionary(sessions.map { ($0.id, $0) }) { first, _ in first }
        return item.sessionIDs.compactMap { byID[$0] }
    }
}

/// The Mac board's views: the work items alone, the sessions alone, or the work items
/// with their sessions inside and the sessions linked to none beside them.
public enum BoardMode: String, Codable, Sendable, CaseIterable {
    case workItems
    case sessions
    case together

    /// The Mac's name for it.
    public var label: String {
        switch self {
        case .workItems: return "Work Items"
        case .sessions: return "Sessions"
        case .together: return "Together"
        }
    }
}

public struct BoardColumn: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var color: TabColorName?

    /// An SF Symbol name.
    public var icon: String

    public init(id: String, label: String, color: TabColorName?, icon: String) {
        self.id = id
        self.label = label
        self.color = color
        self.icon = icon
    }
}

public struct BoardCard: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A work item, kept by hand; sessions may be linked to it.
        case workItem

        /// A session: in `cards`, one linked to no work item; in `sessions`, any.
        case session
    }

    public var kind: Kind
    public var id: String
    public var title: String
    public var column: String
    public var color: TabColorName?

    /// The label the board gives the card's color, such as "Bug".
    public var colorLabel: String?

    /// A session's light.
    public var light: SessionLight?

    /// The sessions linked to a work item.
    public var sessionIDs: [String]

    /// The work item a session is linked to.
    public var workItemID: String?

    public init(
        kind: Kind,
        id: String,
        title: String,
        column: String,
        color: TabColorName? = nil,
        colorLabel: String? = nil,
        light: SessionLight? = nil,
        sessionIDs: [String] = [],
        workItemID: String? = nil
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.column = column
        self.color = color
        self.colorLabel = colorLabel
        self.light = light
        self.sessionIDs = sessionIDs
        self.workItemID = workItemID
    }
}

public struct MoveCard: Codable, Equatable, Sendable {
    public var kind: BoardCard.Kind
    public var id: String
    public var column: String

    public init(kind: BoardCard.Kind, id: String, column: String) {
        self.kind = kind
        self.id = id
        self.column = column
    }
}

public struct RenameSession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

/// The last lines a session shows.
public struct SessionPeek: Codable, Equatable, Sendable {
    public var id: String
    public var lines: [String]

    public init(id: String, lines: [String]) {
        self.id = id
        self.lines = lines
    }
}

/// The figures the Mac's usage panel totals, for the range it shows.
public struct RemoteUsageReport: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable, Identifiable {
        public var provider: String
        public var model: String
        public var costUsd: Double?
        public var tokens: Int

        public var id: String { "\(provider):\(model)" }

        public init(provider: String, model: String, costUsd: Double?, tokens: Int) {
            self.provider = provider
            self.model = model
            self.costUsd = costUsd
            self.tokens = tokens
        }
    }

    /// The range the totals cover, such as "Last 7 days".
    public var rangeLabel: String
    public var costUsd: Double
    public var tokens: Int
    public var sessions: Int

    /// The most recent day or bucket of the range.
    public var latestCostUsd: Double
    public var latestTokens: Int

    /// Highest cost first.
    public var models: [Model]

    public init(rangeLabel: String, costUsd: Double, tokens: Int, sessions: Int, latestCostUsd: Double, latestTokens: Int, models: [Model]) {
        self.rangeLabel = rangeLabel
        self.costUsd = costUsd
        self.tokens = tokens
        self.sessions = sessions
        self.latestCostUsd = latestCostUsd
        self.latestTokens = latestTokens
        self.models = models
    }
}

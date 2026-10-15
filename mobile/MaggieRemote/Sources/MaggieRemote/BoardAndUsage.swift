import Foundation

/// The Mac's session board: its columns, and in each the work items and the sessions,
/// in the board's order.
public struct BoardSnapshot: Codable, Equatable, Sendable {
    public var columns: [BoardColumn]
    public var cards: [BoardCard]

    public init(columns: [BoardColumn], cards: [BoardCard]) {
        self.columns = columns
        self.cards = cards
    }

    /// The cards of one column, in order.
    public func cards(in column: String) -> [BoardCard] {
        cards.filter { $0.column == column }
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

        /// A session not linked to a work item.
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

    public init(
        kind: Kind,
        id: String,
        title: String,
        column: String,
        color: TabColorName? = nil,
        colorLabel: String? = nil,
        light: SessionLight? = nil,
        sessionIDs: [String] = []
    ) {
        self.kind = kind
        self.id = id
        self.title = title
        self.column = column
        self.color = color
        self.colorLabel = colorLabel
        self.light = light
        self.sessionIDs = sessionIDs
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

import AppKit
import Combine

/// A column of the session board, such as In progress.
struct SessionBoardColumn: Codable, Equatable, Identifiable {
    /// Kept when the column is renamed, so the sessions in it stay in it.
    let id: String
    var label: String
    var color: TerminalTabColor
    var icon: String

    static let maxLabelLength = 32

    /// The color the column is drawn in. A column without one takes the text's.
    var displayColor: NSColor {
        color.displayColor ?? .secondaryLabelColor
    }
}

/// Where a session sits on the board: its column, and its place in it.
struct SessionBoardPlace: Codable, Equatable {
    var column: String

    /// Sessions are listed by this, lowest first.
    var order: Double
}

/// The board's columns, shared by every window and saved in user defaults. A session's
/// column is set only when the user moves it; nothing moves it on its own.
final class SessionBoardSettings: ObservableObject {
    static let shared = SessionBoardSettings()

    private static let columnsKey = "SessionBoardColumns"

    static let defaultColumns: [SessionBoardColumn] = [
        .init(id: "todo", label: "Todo", color: .none, icon: "circle"),
        .init(id: "in-progress", label: "In progress", color: .yellow, icon: "circle.lefthalf.filled"),
        .init(id: "in-review", label: "In review", color: .green, icon: "checkmark.circle"),
        .init(id: "done", label: "Done", color: .orange, icon: "checkmark.circle.fill"),
    ]

    /// Where a session no one has moved sits, as on Orca: most sessions are worked on.
    static let defaultColumnID = "in-progress"

    /// The symbols a column can be given, in rows of related ones.
    static let icons = [
        "circle", "circle.dashed", "circle.lefthalf.filled", "circle.inset.filled", "smallcircle.filled.circle",
        "checkmark.circle", "checkmark.circle.fill", "checkmark.seal", "checkmark.seal.fill", "hand.thumbsup",
        "clock", "hourglass", "timer", "calendar", "alarm",
        "play.circle", "pause.circle", "stop.circle", "forward.circle", "arrow.clockwise.circle",
        "eye.circle", "magnifyingglass.circle", "text.bubble", "questionmark.circle", "exclamationmark.circle",
        "exclamationmark.triangle", "xmark.circle", "nosign", "ladybug", "flame",
        "flag", "flag.checkered", "bookmark", "tag", "pin",
        "star", "heart", "bolt", "sparkles", "lightbulb",
        "hammer", "wrench.and.screwdriver", "paintbrush", "doc.text", "shippingbox",
        "tray", "archivebox", "folder", "person", "person.2",
        "arrow.triangle.branch", "arrow.triangle.merge", "arrow.up.circle", "paperplane", "flag.2.crossed",
    ]

    /// The colors a column can be given.
    static let colors: [TerminalTabColor] = [.none, .blue, .purple, .pink, .red, .orange, .yellow, .green, .teal, .graphite]

    @Published var columns: [SessionBoardColumn] {
        didSet {
            guard let data = try? JSONEncoder().encode(columns) else { return }
            defaults.set(data, forKey: Self.columnsKey)
        }
    }

    private static let modeKey = "SessionBoardMode"

    /// Whether the board shows work items, sessions, or both together.
    @Published var mode: SessionBoardMode {
        didSet { defaults.set(mode.rawValue, forKey: Self.modeKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        mode = defaults.string(forKey: Self.modeKey).flatMap(SessionBoardMode.init(rawValue:)) ?? .sessions
        let saved = defaults.data(forKey: Self.columnsKey)
            .flatMap { try? JSONDecoder().decode([SessionBoardColumn].self, from: $0) }
        columns = saved.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultColumns
    }

    /// The column a session saved in `id` shows in: that one while it exists, else the
    /// default column, else the first, so a session whose column was removed still shows.
    func column(for id: String?) -> String {
        if let id, columns.contains(where: { $0.id == id }) { return id }
        if columns.contains(where: { $0.id == Self.defaultColumnID }) { return Self.defaultColumnID }
        return columns.first?.id ?? Self.defaultColumnID
    }

    @discardableResult
    func addColumn() -> SessionBoardColumn {
        var number = columns.count + 1
        while columns.contains(where: { $0.id == "status-\(number)" }) { number += 1 }
        let column = SessionBoardColumn(id: "status-\(number)", label: "Status \(number)", color: .blue, icon: "circle")
        columns.append(column)
        return column
    }

    /// Removes a column, keeping the last one, and says which column its sessions move
    /// to: the one before it, or after it for the first.
    func removeColumn(_ id: String) -> String? {
        guard columns.count > 1, let index = columns.firstIndex(where: { $0.id == id }) else { return nil }
        columns.remove(at: index)
        return columns[max(0, index - 1)].id
    }

    func moveColumn(_ id: String, by offset: Int) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard columns.indices.contains(target) else { return }
        columns.swapAt(index, target)
    }

    func update(_ id: String, _ change: (inout SessionBoardColumn) -> Void) {
        guard let index = columns.firstIndex(where: { $0.id == id }) else { return }
        var column = columns[index]
        change(&column)
        column.label = String(column.label.prefix(SessionBoardColumn.maxLabelLength))
        columns[index] = column
    }
}

/// What the board shows: only the sessions in the picked folders and groups, with the
/// picked colors, in the picked columns. An empty choice doesn't filter.
struct SessionBoardFilter: Equatable {
    /// Folder ids; nil stands for sessions in no folder.
    var folders: Set<UUID?> = []

    /// Group ids; nil stands for sessions in no group.
    var groups: Set<UUID?> = []

    /// Board column ids. A column left out still shows, without its cards.
    var columns: Set<String> = []

    /// The colors the sessions show in the sidebar.
    var colors: Set<TerminalTabColor> = []

    var isActive: Bool { !folders.isEmpty || !groups.isEmpty || !columns.isEmpty || !colors.isEmpty }

    var count: Int { folders.count + groups.count + columns.count + colors.count }

    func shows(column: String) -> Bool {
        columns.isEmpty || columns.contains(column)
    }

    func shows(folder: UUID?, group: UUID?, color: TerminalTabColor) -> Bool {
        (folders.isEmpty || folders.contains(folder))
            && (groups.isEmpty || groups.contains(group))
            && (colors.isEmpty || colors.contains(color))
    }

    /// Adds `value` to a choice, or takes it out.
    static func toggle<T>(_ value: T, in set: inout Set<T>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }
}

/// How sessions lay out on the board, apart from the views so it can be tested.
enum SessionBoardLayout {
    struct Item<ID: Hashable> {
        let id: ID
        let place: SessionBoardPlace?
    }

    /// Each column's sessions, in order. `items` come in sidebar order, which is the
    /// order of sessions never moved.
    static func lanes<ID: Hashable>(
        _ items: [Item<ID>],
        settings: SessionBoardSettings
    ) -> [String: [ID]] {
        var lanes: [String: [(id: ID, key: Double, index: Int)]] = [:]
        for (index, item) in items.enumerated() {
            let column = settings.column(for: item.place?.column)
            // Sessions never moved come after the ones that were, in sidebar order.
            let key = item.place?.order ?? (1_000_000 + Double(index))
            lanes[column, default: []].append((item.id, key, index))
        }
        return lanes.mapValues { lane in
            lane.sorted { ($0.key, $0.index) < ($1.key, $1.index) }.map(\.id)
        }
    }

    /// The places of the sessions in `column` once `moved` is dropped in it before
    /// `before`, or at its end. Every session in that column gets its place, so their
    /// order holds from then on.
    static func move<ID: Hashable>(
        _ moved: ID,
        to column: String,
        before: ID?,
        lanes: [String: [ID]]
    ) -> [ID: SessionBoardPlace] {
        var lane = (lanes[column] ?? []).filter { $0 != moved }
        if let before, let index = lane.firstIndex(of: before) {
            lane.insert(moved, at: index)
        } else {
            lane.append(moved)
        }
        var places: [ID: SessionBoardPlace] = [:]
        for (index, id) in lane.enumerated() {
            places[id] = SessionBoardPlace(column: column, order: Double(index))
        }
        return places
    }
}

extension TerminalWindow {
    /// Moves every session in `column` to `target`, as when the column is removed.
    static func moveBoardSessions(from column: String, to target: String) {
        for case let window as TerminalWindow in NSApp.windows where window.boardPlace?.column == column {
            window.boardPlace?.column = target
        }
    }
}

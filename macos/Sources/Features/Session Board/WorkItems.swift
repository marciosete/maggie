import AppKit
import Combine

/// A piece of work on the board, like a card on a kanban board kept by hand: a title, a
/// column, and notes. Sessions are linked to it by hand, from the session's menu or the
/// card's; nothing links them on its own.
struct WorkItem: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String

    /// Its column on the board, one of `SessionBoardSettings.columns`.
    var column: String

    /// Its place in the column, lowest first.
    var order: Double

    /// The color the card is filled with, picked by hand.
    var color: TerminalTabColor = .none

    let createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), title: String, column: String, order: Double, at now: Date = Date()) {
        self.id = id
        self.title = title
        self.column = column
        self.order = order
        createdAt = now
        updatedAt = now
    }

    static let maxTitleLength = 200

    /// The colors a card can be given: every color a session can show, the ones the
    /// session lights use too, but not Auto or Attention, which follow a session.
    static let colorChoices: [TerminalTabColor] = TerminalTabColor.allCases.filter { !$0.followsClaudeCode }

    private enum CodingKeys: String, CodingKey {
        case id, title, column, order, color, createdAt, updatedAt
    }

    // Items saved before cards had colors read as uncolored.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        column = try container.decode(String.self, forKey: .column)
        order = try container.decode(Double.self, forKey: .order)
        color = try container.decodeIfPresent(TerminalTabColor.self, forKey: .color) ?? .none
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

/// The work items, saved by Maggie in its own folder: the items in `items.json`, each
/// one's notes in a Markdown file beside it, so they open in the document pane.
final class WorkItemStore: ObservableObject {
    static let shared = WorkItemStore(directory: WorkItemStore.defaultDirectory)

    /// Apart for each build, so Maggie Dev's items aren't Maggie's.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Work Items", isDirectory: true)
    }

    @Published private(set) var items: [WorkItem] = []

    let directory: URL
    private var file: URL { directory.appendingPathComponent("items.json") }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    subscript(id: UUID?) -> WorkItem? {
        guard let id else { return nil }
        return items.first { $0.id == id }
    }

    // MARK: Changes

    /// Adds an item at the end of `column`.
    @discardableResult
    func add(_ title: String, to column: String, at now: Date = Date()) -> WorkItem? {
        let title = Self.clean(title)
        guard !title.isEmpty else { return nil }
        let last = items.filter { $0.column == column }.map(\.order).max() ?? -1
        let item = WorkItem(title: title, column: column, order: last + 1, at: now)
        items.append(item)
        save()
        return item
    }

    func rename(_ id: UUID, to title: String, at now: Date = Date()) {
        let title = Self.clean(title)
        guard !title.isEmpty else { return }
        update(id, at: now) { $0.title = title }
    }

    func setColor(_ color: TerminalTabColor, of id: UUID, at now: Date = Date()) {
        update(id, at: now) { $0.color = color }
    }

    /// Removes an item and its notes. Its sessions stay, linked to nothing.
    func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: notes(of: id))
        save()
        for case let window as TerminalWindow in NSApp?.windows ?? [] where window.workItemID == id {
            window.workItemID = nil
        }
    }

    /// Moves an item to `column`, before the item `before` or at the column's end, and
    /// numbers that column again so its order holds.
    func move(_ id: UUID, to column: String, before: UUID?, settings: SessionBoardSettings, at now: Date = Date()) {
        let lanes = SessionBoardLayout.lanes(items.map { .init(id: $0.id, place: $0.place) }, settings: settings)
        let places = SessionBoardLayout.move(id, to: column, before: before, lanes: lanes)
        var changed = false
        for index in items.indices {
            guard let place = places[items[index].id], place != items[index].place else { continue }
            items[index].column = place.column
            items[index].order = place.order
            if items[index].id == id { items[index].updatedAt = now }
            changed = true
        }
        if changed { save() }
    }

    /// Moves the items in `column` to `target`, as when the column is removed.
    func moveItems(from column: String, to target: String) {
        guard items.contains(where: { $0.column == column }) else { return }
        for index in items.indices where items[index].column == column {
            items[index].column = target
        }
        save()
    }

    // MARK: Notes

    /// The item's notes, made empty the first time so the pane can open them.
    func notes(of id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).md")
    }

    func preparedNotes(of item: WorkItem) -> URL {
        let url = notes(of: item.id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data("# \(item.title)\n\n".utf8).write(to: url)
        }
        return url
    }

    func hasNotes(_ id: UUID) -> Bool {
        guard let data = try? Data(contentsOf: notes(of: id)), let text = String(data: data, encoding: .utf8) else {
            return false
        }
        // The heading the notes start with isn't a note.
        let body = text.split(separator: "\n").filter { !$0.hasPrefix("# ") }
        return body.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: Saving

    private func update(_ id: UUID, at now: Date, _ change: (inout WorkItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        change(&item)
        guard item != items[index] else { return }
        item.updatedAt = now
        items[index] = item
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        items = (try? JSONDecoder().decode([WorkItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        // Dates stay as numbers, which keep them exactly; ISO 8601 drops the fraction.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(items) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func clean(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(WorkItem.maxTitleLength))
    }
}

extension WorkItem {
    var place: SessionBoardPlace { SessionBoardPlace(column: column, order: order) }
}

/// What the board shows: the work items, the sessions, or the items with their
/// sessions under them.
enum SessionBoardMode: String, CaseIterable {
    case workItems
    case sessions
    case together

    var localizedName: String {
        switch self {
        case .workItems: return "Work Items"
        case .sessions: return "Sessions"
        case .together: return "Together"
        }
    }
}

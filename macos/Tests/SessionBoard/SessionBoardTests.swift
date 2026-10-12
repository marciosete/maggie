import AppKit
import Testing
@testable import Ghostty

struct SessionBoardTests {
    private func settings() -> SessionBoardSettings {
        let defaults = UserDefaults(suiteName: "SessionBoardTests-\(UUID().uuidString)")!
        return SessionBoardSettings(defaults: defaults)
    }

    private func item(_ id: Int, _ column: String? = nil, _ order: Double = 0) -> SessionBoardLayout.Item<Int> {
        .init(id: id, place: column.map { SessionBoardPlace(column: $0, order: order) })
    }

    @Test func theDefaultColumnsAreOrcas() {
        let settings = settings()
        #expect(settings.columns.map(\.label) == ["Todo", "In progress", "In review", "Done"])
        #expect(settings.column(for: nil) == "in-progress")
    }

    @Test func sessionsNeverMovedAreInProgressInSidebarOrder() {
        let lanes = SessionBoardLayout.lanes([item(1), item(2), item(3, "todo")], settings: settings())
        #expect(lanes["in-progress"] == [1, 2])
        #expect(lanes["todo"] == [3])
    }

    @Test func movedSessionsComeFirstByTheirOrder() {
        let lanes = SessionBoardLayout.lanes([item(1), item(2, "in-progress", 1), item(3, "in-progress", 0)], settings: settings())
        #expect(lanes["in-progress"] == [3, 2, 1])
    }

    @Test func aSessionInARemovedColumnFallsBack() {
        let lanes = SessionBoardLayout.lanes([item(1, "gone")], settings: settings())
        #expect(lanes["in-progress"] == [1])
    }

    @Test func movingInsertsBeforeACardAndNumbersTheColumn() {
        let lanes = ["todo": [1, 2, 3], "done": [4]]
        let places = SessionBoardLayout.move(4, to: "todo", before: 2, lanes: lanes)
        #expect(places[1] == SessionBoardPlace(column: "todo", order: 0))
        #expect(places[4] == SessionBoardPlace(column: "todo", order: 1))
        #expect(places[2] == SessionBoardPlace(column: "todo", order: 2))
        #expect(places[3]?.order == 3)
    }

    @Test func movingWithinAColumnReorders() {
        let places = SessionBoardLayout.move(3, to: "todo", before: 1, lanes: ["todo": [1, 2, 3]])
        #expect(places.sorted { $0.value.order < $1.value.order }.map(\.key) == [3, 1, 2])

        let toEnd = SessionBoardLayout.move(1, to: "todo", before: nil, lanes: ["todo": [1, 2, 3]])
        #expect(toEnd.sorted { $0.value.order < $1.value.order }.map(\.key) == [2, 3, 1])
    }

    @Test func columnsCanBeEditedAndKeepOne() {
        let settings = settings()
        let added = settings.addColumn()
        #expect(settings.columns.last == added)
        #expect(added.id == "status-5")

        settings.update(added.id) { $0.label = String(repeating: "x", count: 40) }
        #expect(settings.columns.last?.label.count == SessionBoardColumn.maxLabelLength)

        settings.moveColumn("todo", by: 1)
        #expect(settings.columns.prefix(2).map(\.id) == ["in-progress", "todo"])
        settings.moveColumn("in-progress", by: -1)
        #expect(settings.columns.first?.id == "in-progress")

        // A removed column's sessions go to the one before it, or after it for the first.
        #expect(settings.removeColumn("in-review") == "todo")
        #expect(settings.removeColumn("in-progress") == "todo")
        for column in settings.columns.dropFirst() { _ = settings.removeColumn(column.id) }
        #expect(settings.removeColumn("todo") == nil)
        #expect(settings.columns.count == 1)
    }

    @Test func everyColumnIconIsASymbol() {
        let icons = SessionBoardSettings.icons
        #expect(Set(icons).count == icons.count)
        for icon in icons + SessionBoardSettings.defaultColumns.map(\.icon) {
            #expect(NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil, "\(icon)")
        }
    }

    @Test func anEmptyFilterShowsEverything() {
        let filter = SessionBoardFilter()
        #expect(!filter.isActive)
        #expect(filter.shows(column: "todo"))
        #expect(filter.shows(folder: nil, group: nil, color: .none))
    }

    @Test func filtersNarrowByEachChoice() {
        let ghostty = UUID()
        let work = UUID()
        var filter = SessionBoardFilter()
        SessionBoardFilter.toggle(ghostty, in: &filter.folders)
        SessionBoardFilter.toggle(nil, in: &filter.folders)
        #expect(filter.shows(folder: ghostty, group: nil, color: .none))
        #expect(filter.shows(folder: nil, group: work, color: .blue))
        #expect(!filter.shows(folder: UUID(), group: nil, color: .none))

        SessionBoardFilter.toggle(work, in: &filter.groups)
        #expect(!filter.shows(folder: ghostty, group: nil, color: .none))
        #expect(filter.shows(folder: ghostty, group: work, color: .none))

        SessionBoardFilter.toggle(.purple, in: &filter.colors)
        #expect(!filter.shows(folder: ghostty, group: work, color: .none))
        #expect(filter.shows(folder: ghostty, group: work, color: .purple))

        SessionBoardFilter.toggle("done", in: &filter.columns)
        #expect(filter.shows(column: "done"))
        #expect(!filter.shows(column: "todo"))
        #expect(filter.count == 5)

        SessionBoardFilter.toggle("done", in: &filter.columns)
        #expect(filter.shows(column: "todo"))
    }

    private func key(_ characters: String, _ modifiers: NSEvent.ModifierFlags) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: 0)
    }

    @Test func theEditingKeysAreKnown() throws {
        #expect(SessionBoardEditing.action(for: try #require(key("v", .command))) == #selector(NSText.paste(_:)))
        #expect(SessionBoardEditing.action(for: try #require(key("c", .command))) == #selector(NSText.copy(_:)))
        #expect(SessionBoardEditing.action(for: try #require(key("x", .command))) == #selector(NSText.cut(_:)))
        #expect(SessionBoardEditing.action(for: try #require(key("a", .command))) == #selector(NSText.selectAll(_:)))
        #expect(SessionBoardEditing.action(for: try #require(key("z", [.command, .shift]))) == Selector(("redo:")))
        #expect(SessionBoardEditing.action(for: try #require(key("v", [.command, .option]))) == nil)
        #expect(SessionBoardEditing.action(for: try #require(key("v", []))) == nil)
        #expect(SessionBoardEditing.action(for: try #require(key("k", .command))) == nil)
    }

    /// The paste the board sends reaches a text field being typed in.
    @Test @MainActor func aPasteReachesTheFieldBeingTypedIn() async throws {
        let field = NSTextField(string: "Review ")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = field
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.moveToEndOfDocument(nil)

        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("Neehar's papers", forType: .string)

        let paste = try #require(key("v", .command))
        let action = try #require(SessionBoardEditing.action(for: paste))
        #expect(NSApp.sendAction(action, to: editor, from: nil))
        #expect(field.stringValue == "Review Neehar's papers")
    }

    @Test func columnsAreSaved() {
        let defaults = UserDefaults(suiteName: "SessionBoardTests-\(UUID().uuidString)")!
        let settings = SessionBoardSettings(defaults: defaults)
        settings.update("done") { $0.label = "Shipped" }
        #expect(SessionBoardSettings(defaults: defaults).columns.last?.label == "Shipped")
    }
}

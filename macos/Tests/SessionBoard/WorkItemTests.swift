import AppKit
import Testing
@testable import Ghostty

struct WorkItemTests {
    private func store() -> WorkItemStore {
        WorkItemStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("work-items-\(UUID().uuidString)"))
    }

    private func settings() -> SessionBoardSettings {
        SessionBoardSettings(defaults: UserDefaults(suiteName: "WorkItemTests-\(UUID().uuidString)")!)
    }

    private func titles(_ store: WorkItemStore, in column: String) -> [String] {
        store.items.filter { $0.column == column }.sorted { $0.order < $1.order }.map(\.title)
    }

    @Test func cardsAreAddedAtTheColumnsEndAndSaved() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        store.add("Risk Review", to: "todo")
        store.add("  IP Table \n", to: "todo")
        #expect(store.add("   ", to: "todo") == nil)
        #expect(titles(store, in: "todo") == ["Risk Review", "IP Table"])

        let again = WorkItemStore(directory: store.directory)
        #expect(again.items == store.items)
    }

    /// A board shows the cards made on it, those of no window, made before boards were
    /// a window's, and those of a window no longer open, so none is lost.
    @Test @MainActor func aBoardShowsItsWindowsCards() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let host = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let other = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        defer {
            host.close()
            other.close()
        }
        let model = TabSidebarModel(hostWindow: host)
        store.add("Mine", to: "todo", window: host.folderSpace.id)
        store.add("Theirs", to: "todo", window: other.folderSpace.id)
        store.add("Legacy", to: "todo")
        store.add("Orphan", to: "todo", window: UUID())
        #expect(model.boardItems(store.items).map(\.title) == ["Mine", "Legacy", "Orphan"])

        // Moved to the other window, it goes from this board, and stays there on reload.
        let mine = try #require(store.items.first)
        store.move(mine.id, toWindow: other.folderSpace.id)
        #expect(model.boardItems(store.items).map(\.title) == ["Legacy", "Orphan"])
        #expect(WorkItemStore(directory: store.directory)[mine.id]?.windowID == other.folderSpace.id)
    }

    @Test func cardsTakeAColorAndKeepIt() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try #require(store.add("Capitalisation", to: "todo"))
        #expect(item.color == .none)
        store.setColor(.green, of: item.id)
        #expect(WorkItemStore(directory: store.directory)[item.id]?.color == .green)
    }

    /// Cards saved before they had colors still read.
    @Test func aCardSavedWithoutAColorReads() throws {
        let json = #"[{"id":"\#(UUID().uuidString)","title":"FinOps","column":"done","order":0,"createdAt":0,"updatedAt":0}]"#
        let items = try JSONDecoder().decode([WorkItem].self, from: Data(json.utf8))
        #expect(items.first?.color == TerminalTabColor.none)
    }

    @Test func cardsOfferEveryColorButTheFollowingOnes() {
        #expect(WorkItem.colorChoices.first == TerminalTabColor.none)
        #expect(WorkItem.colorChoices.contains(.blue))
        #expect(WorkItem.colorChoices.contains(.green))
        #expect(WorkItem.colorChoices.contains(.purple))
        #expect(!WorkItem.colorChoices.contains(.auto))
        #expect(!WorkItem.colorChoices.contains(.attention))
    }

    @Test func cardsRenameAndMove() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let settings = settings()
        let first = try #require(store.add("A", to: "todo"))
        let second = try #require(store.add("B", to: "todo"))
        store.add("C", to: "done")

        store.rename(first.id, to: "Alex Goal Setting")
        store.rename(first.id, to: " ")
        #expect(store[first.id]?.title == "Alex Goal Setting")

        store.move(second.id, to: "todo", before: first.id, settings: settings)
        #expect(titles(store, in: "todo") == ["B", "Alex Goal Setting"])

        store.move(first.id, to: "done", before: nil, settings: settings)
        #expect(titles(store, in: "done") == ["C", "Alex Goal Setting"])
        #expect(titles(store, in: "todo") == ["B"])
    }

    @Test func deletingACardTakesItsNotes() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let item = try #require(store.add("FinOps", to: "done"))
        let notes = store.preparedNotes(of: item)
        #expect(try String(contentsOf: notes, encoding: .utf8) == "# FinOps\n\n")
        #expect(!store.hasNotes(item.id))

        try Data("# FinOps\n\nCheck the bill.\n".utf8).write(to: notes)
        #expect(store.hasNotes(item.id))

        store.delete(item.id)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: notes.path))
    }

    @Test func aRemovedColumnsCardsMove() throws {
        let store = store()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        store.add("Later one", to: "later")
        store.moveItems(from: "later", to: "todo")
        #expect(titles(store, in: "todo") == ["Later one"])
    }

    /// The views split the columns: items alone, sessions alone, or items with their
    /// sessions and the rest of the sessions on their own.
    @Test @MainActor func eachViewShowsItsCards() throws {
        let settings = settings()
        let item = WorkItem(title: "Platform Hardening", column: "in-review", order: 0)
        let gone = UUID()
        func tab(_ title: String, linkedTo id: UUID?) -> TabSidebarModel.Tab {
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            return TabSidebarModel.Tab(
                id: ObjectIdentifier(window), window: nil, index: 0, title: title,
                color: .none, assignedColor: .none, claudeCodeState: nil, claudeCodeActivity: ClaudeCodeActivity(),
                canSpeak: false, isSpeaking: false, speechVoiceID: nil,
                keyEquivalent: nil, isSelected: false, isZoomed: false, groupID: nil, folderID: nil, folderGroupID: nil,
                workItemID: id)
        }
        let linked = tab("Controls", linkedTo: item.id)
        let orphan = tab("Old", linkedTo: gone)
        let loose = tab("Shell", linkedTo: nil)
        let tabs = [linked, orphan, loose]
        let lanes = SessionBoardLayout.lanes(tabs.map { .init(id: $0.id, place: $0.boardPlace) }, settings: settings)
        func content(_ mode: SessionBoardMode) -> SessionBoardContent {
            SessionBoardContent(mode: mode, tabs: tabs, items: [item], settings: settings, sessionLanes: lanes)
        }

        #expect(content(.sessions).items(in: "in-review").isEmpty)
        #expect(content(.sessions).sessions(in: "in-progress").map(\.title) == ["Controls", "Old", "Shell"])

        #expect(content(.workItems).items(in: "in-review").map(\.title) == ["Platform Hardening"])
        #expect(content(.workItems).sessions(in: "in-progress").isEmpty)

        // Together, the linked session goes under its item; one linked to a deleted
        // item shows on its own.
        #expect(content(.together).items(in: "in-review").map(\.title) == ["Platform Hardening"])
        #expect(content(.together).sessions(of: item.id).map(\.title) == ["Controls"])
        #expect(content(.together).sessions(in: "in-progress").map(\.title) == ["Old", "Shell"])
    }
}

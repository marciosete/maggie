import Foundation
import Testing
@testable import Ghostty

@Suite
@MainActor
struct RemoteBoardTests {
    private let windows = (0..<4).map { _ in NSObject() }

    private func tab(_ index: Int, title: String, column: String?, order: Double? = nil, workItem: UUID? = nil, light: ClaudeCodeLight? = nil) -> TabSidebarModel.Tab {
        TabSidebarModel.Tab(
            id: ObjectIdentifier(windows[index]),
            index: index,
            title: title,
            color: .none,
            assignedColor: .purple,
            claudeCodeState: light.map { ClaudeCodeTabState(light: $0) },
            claudeCodeActivity: ClaudeCodeActivity(),
            canSpeak: false,
            isSpeaking: false,
            speechVoiceID: nil,
            keyEquivalent: nil,
            isSelected: false,
            isZoomed: false,
            groupID: nil,
            folderID: nil,
            folderGroupID: nil,
            boardPlace: column.map { SessionBoardPlace(column: $0, order: order ?? 0) },
            workItemID: workItem)
    }

    @Test func cardsFollowTheMacsBoard() throws {
        let settings = SessionBoardSettings.shared
        // Sessions never moved show in the default column.
        let first = settings.column(for: nil)
        let second = try #require(settings.columns.first { $0.id != first }?.id)

        var item = WorkItem(title: "Mobile companion", column: second, order: 0)
        item.color = .green
        let tabs = [
            tab(0, title: "linked", column: second, workItem: item.id),
            tab(1, title: "later", column: first, order: 2, light: .waiting),
            tab(2, title: "sooner", column: first, order: 1),
            tab(3, title: "never moved", column: nil),
        ]
        let board = RemoteBoard.snapshot(tabs: tabs, items: [item], settings: settings) { "s\($0.index)" }

        #expect(board.columns.map(\.id) == settings.columns.map(\.id))
        // Sessions placed by hand come in their order, those never moved after them.
        #expect(board.cards(in: first).map(\.title) == ["sooner", "later", "never moved"])
        #expect(board.cards(in: first)[1].light == .waiting)
        // A session linked to a work item is on the item's card, not its own.
        let card = try #require(board.cards(in: second).first)
        #expect(card.kind == .workItem)
        #expect(card.title == "Mobile companion")
        #expect(card.color == .green)
        #expect(card.sessionIDs == ["s0"])
        #expect(!board.cards.contains { $0.title == "linked" })

        // Every session comes on its own too, the linked one saying which item it is on,
        // with the view the Mac shows.
        #expect(board.sessions(in: first, mode: .sessions).map(\.title) == ["sooner", "later", "never moved"])
        #expect(board.sessions(in: second, mode: .sessions).map(\.title) == ["linked"])
        #expect(board.sessions.first { $0.title == "linked" }?.workItemID == item.id.uuidString)
        #expect(board.sessions.first { $0.title == "sooner" }?.workItemID == nil)
        #expect(board.mode?.rawValue == settings.mode.rawValue)
        #expect(board.sessions(of: card).map(\.title) == ["linked"])
    }
}

@Suite
struct RemotePeekTests {
    @Test func theLastTwentyLinesTrimmed() {
        let text = (1...30).map { "line \($0)   " }.joined(separator: "\n") + "\n\n\n"
        let lines = RemotePeek.lines(of: text)
        #expect(lines.count == 20)
        #expect(lines.first == "line 11")
        #expect(lines.last == "line 30")
    }
}

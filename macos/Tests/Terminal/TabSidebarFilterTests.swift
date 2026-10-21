import AppKit
import Combine
import Testing
@testable import Ghostty

@Suite
@MainActor
struct TabSidebarFilterTests {
    private func settings() -> SessionBoardSettings {
        let defaults = UserDefaults(suiteName: "TabSidebarFilterTests-\(UUID().uuidString)")!
        return SessionBoardSettings(defaults: defaults)
    }

    private func titles(_ rows: [TabSidebarModel.Row]) -> [String] {
        rows.flatMap(\.allTabs).map(\.title)
    }

    @Test func narrowsByFolderGroupColorAndStatus() {
        let settings = settings()
        var windows: [TerminalWindow] = []
        func tab(
            _ title: String,
            color: TerminalTabColor = .none,
            group: UUID? = nil,
            folder: UUID? = nil,
            column: String? = nil
        ) -> TabSidebarModel.Tab {
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            windows.append(window)
            return TabSidebarModel.Tab(
                id: ObjectIdentifier(window), window: nil, index: windows.count, title: title,
                color: color, assignedColor: color, claudeCodeState: nil, claudeCodeActivity: ClaudeCodeActivity(),
                canSpeak: false, isSpeaking: false, speechVoiceID: nil,
                keyEquivalent: nil, isSelected: false, isZoomed: false, groupID: group, folderID: folder, folderGroupID: nil,
                boardPlace: column.map { SessionBoardPlace(column: $0, order: 0) })
        }

        let ghostty = UserTabFolder(path: "/Users/me/projects/ghostty", isCollapsed: true)
        let empty = UserTabFolder(path: "/Users/me/projects/empty")
        let kinetic = UserTabGroup(name: "Kinetic", isCollapsed: true)

        let voice = tab("Voice", color: .purple, group: kinetic.id, folder: ghostty.id)
        let retry = tab("Retry", color: .none, group: kinetic.id, folder: ghostty.id, column: "done")
        let email = tab("Email", color: .purple, folder: ghostty.id, column: "todo")
        let plain = tab("plain shell")
        let rows: [TabSidebarModel.Row] = [
            .folder(.init(folder: ghostty, rows: [.group(.init(group: kinetic, tabs: [voice, retry])), .tab(email)])),
            .folder(.init(folder: empty, rows: [])),
            .tab(plain),
        ]

        // Nothing picked, nothing filtered: the rows come back as they are.
        #expect(TabSidebarFilter.filter(rows, by: SessionBoardFilter(), settings: settings) == rows)

        // By folder, the picked folder keeps all its sessions and the rest go; an empty
        // folder shows when picked, and not otherwise.
        var filter = SessionBoardFilter(folders: [ghostty.id])
        #expect(titles(TabSidebarFilter.filter(rows, by: filter, settings: settings)) == ["Voice", "Retry", "Email"])
        #expect(TabSidebarFilter.filter(rows, by: filter, settings: settings).count == 1)
        filter = SessionBoardFilter(folders: [empty.id])
        #expect(TabSidebarFilter.filter(rows, by: filter, settings: settings) == [.folder(.init(folder: empty, rows: []))])
        filter = SessionBoardFilter(folders: [nil])
        #expect(titles(TabSidebarFilter.filter(rows, by: filter, settings: settings)) == ["plain shell"])

        // By group, a group left with no sessions goes with its folder.
        filter = SessionBoardFilter(groups: [kinetic.id], colors: [.purple])
        let purpleKinetic = TabSidebarFilter.filter(rows, by: filter, settings: settings)
        #expect(titles(purpleKinetic) == ["Voice"])
        filter = SessionBoardFilter(groups: [nil])
        #expect(titles(TabSidebarFilter.filter(rows, by: filter, settings: settings)) == ["Email", "plain shell"])

        // By status, sessions never moved are in progress.
        filter = SessionBoardFilter(columns: ["in-progress"])
        #expect(titles(TabSidebarFilter.filter(rows, by: filter, settings: settings)) == ["Voice", "plain shell"])
        filter = SessionBoardFilter(columns: ["todo", "done"])
        #expect(titles(TabSidebarFilter.filter(rows, by: filter, settings: settings)) == ["Retry", "Email"])

        // Nothing unfolds: the folder and the group stay collapsed.
        guard case .folder(let folder)? = purpleKinetic.first, case .group(let group)? = folder.rows.first else {
            Issue.record("the folder and its group are kept")
            return
        }
        #expect(folder.folder.isCollapsed)
        #expect(group.group.isCollapsed)

        filter = SessionBoardFilter(colors: [.red])
        #expect(TabSidebarFilter.filter(rows, by: filter, settings: settings).isEmpty)
    }

    @Test func theFilterIsOneForEveryTabOfAWindow() {
        let store = SessionBoardFilterStore()
        var hosts: [TerminalWindow] = []
        func model(sharing space: TabSidebarFolderSpace? = nil) -> TabSidebarModel {
            let host = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            if let space { host.folderSpace = space }
            hosts.append(host)
            return TabSidebarModel(hostWindow: host, filterStore: store)
        }
        let first = model()
        let second = model(sharing: hosts[0].folderSpace)
        let otherWindow = model()
        var secondChanges = 0
        let watching = second.objectWillChange.sink { _ in secondChanges += 1 }
        defer { watching.cancel() }

        // Picked in one tab's sidebar, the filter holds in the next tab's: that
        // sidebar is told it changed and narrows by the same filter.
        first.boardFilter.colors = [.purple]
        #expect(second.boardFilter == SessionBoardFilter(colors: [.purple]))
        #expect(second.isFiltering)
        #expect(secondChanges == 1)

        // Another window shows other sessions, so it keeps a filter of its own.
        #expect(!otherWindow.isFiltering)
        otherWindow.boardFilter.colors = [.red]
        #expect(first.boardFilter == SessionBoardFilter(colors: [.purple]))

        // Cleared in one tab, it is cleared in the window's others.
        second.boardFilter = SessionBoardFilter()
        #expect(!first.isFiltering)
        #expect(otherWindow.isFiltering)
    }

    @Test func theLightsAreOfferedWhileASessionFollowsClaudeCode() {
        let settings = settings()
        let host = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let model = TabSidebarModel(hostWindow: host)
        func tab(_ title: String, shown: TerminalTabColor, assigned: TerminalTabColor) -> TabSidebarModel.Tab {
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            return TabSidebarModel.Tab(
                id: ObjectIdentifier(window), window: nil, index: 0, title: title,
                color: shown, assignedColor: assigned, claudeCodeState: nil, claudeCodeActivity: ClaudeCodeActivity(),
                canSpeak: false, isSpeaking: false, speechVoiceID: nil,
                keyEquivalent: nil, isSelected: false, isZoomed: false, groupID: nil, folderID: nil, folderGroupID: nil)
        }

        // Sessions all one color, none following Claude Code: nothing to choose between.
        let plain = [tab("a", shown: .none, assigned: .none), tab("b", shown: .none, assigned: .none)]
        #expect(SessionBoardFilterOptions(model: model, tabs: plain, board: settings).colors.isEmpty)

        // One follows Claude Code, idle: every light's color is offered, named as the
        // board names colors, and None for the idle one.
        settings.setLabel("Urgent", of: .red)
        let following = [tab("a", shown: .none, assigned: .auto), tab("b", shown: .purple, assigned: .purple)]
        let colors = SessionBoardFilterOptions(model: model, tabs: following, board: settings).colors
        #expect(colors.map(\.label) == ["None", "Blue", "Purple", "Urgent", "Yellow", "Green", "Teal"])
        #expect(colors.map(\.value) == [.none, .blue, .purple, .red, .yellow, .green, .teal])
        #expect(colors.allSatisfy { $0.image != nil })
    }

    @Test func theColorFilteredByIsTheRowsFill() {
        func tab(_ shown: TerminalTabColor, _ assigned: TerminalTabColor, light: ClaudeCodeLight?) -> TabSidebarModel.Tab {
            let window = TerminalWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
            let state = light.map { ClaudeCodeTabState(light: $0, pendingFiles: 0, editedFiles: 0) }
            return TabSidebarModel.Tab(
                id: ObjectIdentifier(window), window: nil, index: 0, title: "t",
                color: shown, assignedColor: assigned, claudeCodeState: state, claudeCodeActivity: ClaudeCodeActivity(),
                canSpeak: false, isSpeaking: false, speechVoiceID: nil,
                keyEquivalent: nil, isSelected: false, isZoomed: false, groupID: nil, folderID: nil, folderGroupID: nil)
        }

        // A hand-picked color, and a session following its state, fill the row with it.
        #expect(tab(.purple, .purple, light: nil).fillColor == .purple)
        #expect(tab(.blue, .auto, light: .working).fillColor == .blue)

        // Attention fills the row only while the session needs something.
        #expect(tab(.blue, .attention, light: .working).fillColor == .none)
        #expect(tab(.green, .attention, light: .clean).fillColor == .none)
        #expect(tab(.red, .attention, light: .waiting).fillColor == .red)
        #expect(tab(.yellow, .attention, light: .pending).fillColor == .yellow)
    }
}

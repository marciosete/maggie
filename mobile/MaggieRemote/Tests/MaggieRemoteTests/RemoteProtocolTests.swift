import Foundation
import Testing
@testable import MaggieRemote

struct RemoteProtocolTests {
    static let sidebar = SidebarSnapshot(rows: [
        .session(SidebarSession(
            id: "s1",
            title: "loose",
            agent: .claude,
            light: .working,
            lightLabel: "Working",
            workingSince: Date(timeIntervalSince1970: 1_700_000_000)
        )),
        .group(SidebarGroup(id: "g1", name: "Group", collapsed: true, color: .purple, sessions: [
            SidebarSession(id: "s2", title: "in group", agent: .codex, light: .waiting, bell: true),
        ])),
        .folder(SidebarFolder(id: "f1", name: "ghostty", path: "/Users/me/ghostty", abbreviatedPath: "~/ghostty", hasGit: true, rows: [
            .session(SidebarSession(
                id: "s3",
                title: "in folder",
                agent: .claude,
                light: .clean,
                finishedUnseen: true,
                model: "opus",
                branch: "main",
                isWorktree: true,
                directory: "/Users/me/ghostty/.claude/worktrees/x",
                abbreviatedDirectory: "~/ghostty/.claude/worktrees/x",
                lastActive: Date(timeIntervalSince1970: 1_700_000_000),
                isSelected: true,
                color: .green
            )),
        ])),
        .folderGroup(SidebarFolderGroup(id: "fg1", name: "Work", folders: [
            SidebarFolder(id: "f2", name: "notes", path: "/Users/me/notes", abbreviatedPath: "~/notes", hasGit: false, groupID: "fg1"),
        ])),
    ])

    static let clientMessages: [ClientMessage] = [
        .pair(PairRequest(code: "123456", deviceName: "iPad", devicePublicKey: "key")),
        .hello(Hello(deviceToken: "token", deviceName: "iPhone")),
        .subscribeSidebar,
        .openSession(SessionRef(id: "s1")),
        .leaveSession(SessionRef(id: "s1")),
        .closeSession(CloseSession(id: "s1", force: true)),
        .newSession(NewSession(folderID: "f1")),
        .focusSession(SessionRef(id: "s1")),
        .resyncSession(SessionRef(id: "s1")),
        .registerPush(RegisterPush(token: "abcd", environment: .sandbox)),
        .ping(Ping(nonce: .max)),
        .fetchBoard(FetchBoard()),
        .fetchBoard(FetchBoard(windowID: "w1")),
        .moveCard(MoveCard(kind: .workItem, id: "w1", column: "done")),
        .fetchUsage,
        .renameSession(RenameSession(id: "s1", title: "Release notes")),
        .peekSession(SessionRef(id: "s1")),
        .newSession(NewSession()),
        .newSession(NewSession(path: "/Users/me/projects/orca")),
        .newSession(NewSession(folderID: "f1", windowID: "w1")),
        .fitSession(FitSession(id: "s1", columns: 92, rows: 40)),
        .fitSession(FitSession(id: "s1", columns: nil, rows: nil)),
        .listFolders(ListFolders()),
        .listFolders(ListFolders(path: "/Users/me/projects")),
        .startVoice(StartVoice(deviceName: "iPhone")),
        .stopVoice(StopVoice(endsVoice: true)),
        .muteVoice(MuteVoice(muted: true)),
        .subscribeVoice,
    ]

    static let hostMessages: [HostMessage] = [
        .paired(Paired(deviceToken: "token", deviceID: "d1", hostName: "macmini")),
        .welcome(Welcome(hostName: "macmini", capabilities: ["push"])),
        .sidebar(sidebar),
        .sidebar(SidebarSnapshot(rows: sidebar.rows, windows: [
            SidebarWindow(id: "w1", name: "Work", title: "Work", isFront: true, rows: sidebar.rows),
            SidebarWindow(id: "w2", title: "build", rows: []),
        ])),
        .sessionOpened(SessionOpened(id: "s1", stream: 7, columns: 120, rows: 40)),
        .sessionClosed(SessionClosed(id: "s1", reason: .processRunning)),
        .sessionCreated(SessionCreated(id: "s9", folderID: "f1")),
        .error(RemoteError(code: .unauthorized, message: "Unknown device")),
        .pong(Ping(nonce: 42)),
        .board(BoardSnapshot(
            columns: [BoardColumn(id: "todo", label: "To Do", color: .blue, icon: "circle")],
            cards: [
                BoardCard(kind: .workItem, id: "w1", title: "Mobile", column: "todo", color: .purple, colorLabel: "Feature", sessionIDs: ["s1"]),
                BoardCard(kind: .session, id: "s2", title: "Fix", column: "todo", light: .waiting),
            ])),
        .usage(RemoteUsageReport(
            rangeLabel: "Last 7 days",
            costUsd: 12.5,
            tokens: 1_200_000,
            sessions: 9,
            latestCostUsd: 2.25,
            latestTokens: 200_000,
            models: [.init(provider: "claude", model: "opus", costUsd: nil, tokens: 900_000)])),
        .sessionPeek(SessionPeek(id: "s1", lines: ["$ ls", "README.md"])),
        .sessionCreated(SessionCreated(id: "s10", folderID: nil)),
        .fitReleased(SessionRef(id: "s1")),
        .folders(FolderListing(
            path: "/Users/me/projects",
            displayPath: "~/projects",
            parent: "/Users/me",
            isRepository: false,
            entries: [.init(name: "orca", path: "/Users/me/projects/orca", isRepository: true)])),
        .voiceState(VoiceState(
            phase: .live, muted: false, isHandset: true, handsetName: "iPhone", billedSeconds: 61.5,
            userSpeaking: true, assistantSpeaking: false, workingOn: "list_sessions", error: nil)),
        .voiceState(VoiceState(phase: .failed, error: "No OpenAI API key.")),
        .voiceTurn(VoiceTurnMessage(id: "t1", role: .assistant, text: "Session four is done.", at: Date(timeIntervalSince1970: 1_700_000_000))),
    ]

    @Test(arguments: clientMessages)
    func clientMessageRoundTrips(_ message: ClientMessage) throws {
        let data = try RemoteCoding.encode(message)
        #expect(try RemoteCoding.decode(ClientMessage.self, from: data) == message)
    }

    @Test(arguments: hostMessages)
    func hostMessageRoundTrips(_ message: HostMessage) throws {
        let data = try RemoteCoding.encode(message)
        #expect(try RemoteCoding.decode(HostMessage.self, from: data) == message)
    }

    @Test func envelopeCarriesVersionAndKind() throws {
        let data = try RemoteCoding.encode(ClientMessage.openSession(SessionRef(id: "s1")))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == RemoteProtocol.version)
        #expect(json["kind"] as? String == "openSession")
        #expect((json["body"] as? [String: Any])?["id"] as? String == "s1")
    }

    /// A device that knows only folder sessions still reads as one from a newer Mac.
    @Test func aNewSessionWithAFolderReadsAsBefore() throws {
        let old = Data(#"{"version":1,"kind":"newSession","body":{"folderID":"f1"}}"#.utf8)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: old) == .newSession(NewSession(folderID: "f1")))
    }

    /// A board request from a device that knows only one board asks for every window's.
    @Test func aBoardRequestWithoutABodyReads() throws {
        let old = Data(#"{"version":1,"kind":"fetchBoard"}"#.utf8)
        #expect(try JSONDecoder().decode(ClientMessage.self, from: old) == .fetchBoard(FetchBoard()))
    }

    /// A sidebar from a Mac that doesn't send windows still reads, with none.
    @Test func aSidebarWithoutWindowsReads() throws {
        let old = Data(#"{"version":1,"kind":"sidebar","body":{"rows":[]}}"#.utf8)
        #expect(try JSONDecoder().decode(HostMessage.self, from: old) == .sidebar(SidebarSnapshot(rows: [])))
    }

    @Test func unknownKindIsReported() throws {
        let data = Data(#"{"version":2,"kind":"teleport","body":{}}"#.utf8)
        #expect(throws: RemoteProtocolError.unknownKind("teleport")) {
            try RemoteCoding.decode(HostMessage.self, from: data)
        }
    }

    @Test func sidebarFlattensFoldersAndSessions() {
        let sidebar = Self.sidebar
        #expect(sidebar.folders.map(\.id) == ["f1", "f2"])
        #expect(sidebar.sessions.map(\.id) == ["s1", "s2", "s3"])
        #expect(sidebar.session(id: "s3")?.branch == "main")
        #expect(sidebar.folders.map(\.hasGit) == [true, false])
    }

    @Test func statusTextMatchesTheSidebar() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func text(_ light: SessionLight, seconds: TimeInterval, badge: Int? = nil) -> String? {
            SidebarSession(id: "s", title: "s", light: light, workingSince: start, stoppedSince: start, badge: badge)
                .statusText(at: start.addingTimeInterval(seconds))
        }
        #expect(text(.working, seconds: 12) == "12s")
        #expect(text(.working, seconds: 4 * 60 + 5) == "4m")
        #expect(text(.working, seconds: 65 * 60) == "1h 5m")
        #expect(text(.working, seconds: 120 * 60) == "2h")
        #expect(text(.waiting, seconds: 10) == nil)
        #expect(text(.pending, seconds: 10, badge: 3) == "3")
        #expect(text(.unlanded, seconds: 10) == nil)
        #expect(text(.clean, seconds: 30) == "now")
        #expect(text(.clean, seconds: 3 * 3600) == "3h")
        #expect(text(.clean, seconds: 2 * 86400) == "2d")
    }

    @Test func mostUrgentLightMatchesTheMac() {
        #expect(SessionLight.mostUrgent([.clean, .working, .pending]) == .working)
        #expect(SessionLight.mostUrgent([.working, .waiting]) == .waiting)
        #expect(SessionLight.mostUrgent([]) == nil)
        #expect(SidebarGroup(id: "g", name: "g", sessions: [
            SidebarSession(id: "a", title: "a", light: .unlanded),
            SidebarSession(id: "b", title: "b", light: .clean),
        ]).light == .unlanded)
    }
}

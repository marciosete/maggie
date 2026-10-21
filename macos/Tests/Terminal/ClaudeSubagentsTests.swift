import Foundation
import Testing
@testable import Ghostty

@Suite
struct ClaudeSubagentsTests {
    private static let session = "00893aaf-19fa-41d2-8238-13269b9b3ca0"
    private static let transcript = "/Users/me/.claude/projects/-repo/\(session).jsonl"

    private func event(_ name: String, _ fields: [String: Any] = [:]) throws -> ClaudeAgentEvent {
        var object: [String: Any] = [
            "hook_event_name": name,
            "session_id": Self.session,
            "transcript_path": Self.transcript,
        ]
        object.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(ClaudeAgentEvent(json: data))
    }

    private func start(_ id: String, type: String = "Explore") throws -> ClaudeAgentEvent {
        try event("SubagentStart", ["agent_id": id, "agent_type": type])
    }

    private func stop(_ id: String) throws -> ClaudeAgentEvent {
        try event("SubagentStop", ["agent_id": id, "agent_type": "Explore"])
    }

    private func mainStop(_ tasks: [[String: Any]]?) throws -> ClaudeAgentEvent {
        try event("Stop", tasks.map { ["background_tasks": $0] } ?? [:])
    }

    private func roster(_ events: [ClaudeAgentEvent]) -> ClaudeSubagentRoster {
        var roster = ClaudeSubagentRoster(updatedAt: .distantPast)
        for (index, event) in events.enumerated() {
            roster.apply(event, at: Date(timeIntervalSince1970: Double(index)))
        }
        return roster
    }

    // MARK: Ids and paths

    @Test func teammateIdsHaveANameBeforeTheirHex() {
        #expect(ClaudeSubagent.isTeammateID("akit-g3-f02c8ae6ec79a3b2"))
        #expect(ClaudeSubagent.isTeammateID("aresearcher-3d47be652e82ec66"))
        #expect(!ClaudeSubagent.isTeammateID("aa99e07859aea18d8"))
        #expect(!ClaudeSubagent.isTeammateID("agent-aa99e07859aea18d8"))
        #expect(!ClaudeSubagent.isTeammateID("a-ff"))
    }

    @Test func theTranscriptIsInTheSessionsSubagentsFolder() {
        let session = URL(fileURLWithPath: Self.transcript)
        let expected = "/Users/me/.claude/projects/-repo/\(Self.session)/subagents/agent-aa99.jsonl"
        #expect(ClaudeSubagent.transcript(of: "aa99", sessionTranscript: session).path == expected)
        #expect(ClaudeSubagent.transcript(of: "agent-aa99", sessionTranscript: session).path == expected)
    }

    // MARK: Events

    @Test func anEventReadsItsFieldsAndTasks() throws {
        let stop = try event("Stop", [
            "agent_transcript_path": "~/x.jsonl",
            "background_tasks": [
                ["id": "a1", "type": "subagent", "status": "running", "agent_type": "Explore", "description": "Look"],
                ["id": "t1", "type": "shell", "status": "completed"],
            ],
        ])
        #expect(stop.name == "Stop")
        #expect(stop.sessionID == Self.session)
        #expect(stop.agentID == nil)
        #expect(stop.agentTranscript?.path == (NSHomeDirectory() as NSString).appendingPathComponent("x.jsonl"))
        #expect(stop.backgroundTasks == [
            .init(id: "a1", type: "subagent", isRunning: true, agentType: "Explore", description: "Look"),
            .init(id: "t1", type: "shell", isRunning: false, agentType: nil, description: nil),
        ])
        #expect(ClaudeAgentEvent(json: Data("not json".utf8)) == nil)
        #expect(ClaudeAgentEvent(json: Data(#"{"hook_event_name":"Stop"}"#.utf8)) == nil)
    }

    @Test func anEventCarriesWhatTheVoiceSays() throws {
        let notification = try event("Notification", [
            "notification_type": "permission_prompt", "message": "Claude needs your permission to use Bash", "title": "Permission needed",
        ])
        #expect(notification.notificationType == "permission_prompt")
        #expect(notification.message == "Claude needs your permission to use Bash")
        let stop = try event("Stop", ["last_assistant_message": "Done: the tests pass.", "stop_hook_active": false])
        #expect(stop.lastAssistantMessage == "Done: the tests pass.")
        #expect(stop.notificationType == nil)
        let failure = try event("StopFailure", ["error": "rate_limit", "error_details": "429 Too Many Requests"])
        #expect(failure.error == "rate_limit")
        #expect(failure.errorDetails == "429 Too Many Requests")
        let end = try event("SessionEnd", ["reason": "prompt_input_exit"])
        #expect(end.reason == "prompt_input_exit")
        #expect(try event("Stop", ["last_assistant_message": ""]).lastAssistantMessage == nil)
    }

    // MARK: Roster

    @Test func aSubagentWorksUntilItStopsAndStaysListed() throws {
        var roster = roster([try start("a1")])
        #expect(roster.agents.map(\.state) == [.working])
        #expect(roster.agents.first?.agentType == "Explore")

        roster.apply(try stop("a1"), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])

        roster.apply(try mainStop([]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])
    }

    @Test func claudeCodesOwnHelpersAreNotListed() throws {
        let roster = roster([try event("SubagentStart", ["agent_id": "a1"])])
        #expect(roster.isEmpty)
    }

    @Test func aTeammatesStopOnlyEndsItsTurn() throws {
        let id = "aresearcher-3d47be652e82ec66"
        var roster = roster([try start(id, type: "researcher"), try stop(id)])
        #expect(roster.agents.map(\.state) == [.idle])

        roster.apply(try start(id, type: "researcher"), at: Date())
        #expect(roster.agents.map(\.state) == [.working])
        #expect(roster.agents.count == 1)
    }

    @Test func aFailedTurnFailsTheSubagentItNames() throws {
        var roster = roster([try start("a1"), try event("StopFailure", ["agent_id": "a1", "error": "rate_limit"])])
        #expect(roster.agents.map(\.state) == [.failed])

        // Ending the session's turn doesn't make it look done.
        roster.apply(try mainStop([]), at: Date())
        #expect(roster.agents.map(\.state) == [.failed])
    }

    /// Five named agents launched in the background, as tried in Maggie Dev.
    @Test func namedAgentsAreTeammatesThatFinishWhenNothingIsLeft() throws {
        let ids = ["atimer-1-090b6c5363907826", "atimer-2-a1c830bf1eea8b61"]
        var roster = roster([try start(ids[0], type: "timer-1"), try start(ids[1], type: "timer-2")])
        roster.describe { url in
            let name = url.lastPathComponent.contains("timer-1") ? "timer-1" : "timer-2"
            return .init(description: "Timer \(name)", name: name, type: "general-purpose")
        }
        #expect(roster.agents.map(\.shownType) == ["general-purpose", "general-purpose"])

        roster.apply(try stop(ids[0]), at: Date())
        #expect(roster.agents.map(\.state) == [.idle, .working])

        // Its next turn starts with its name as the type again.
        roster.apply(try start(ids[0], type: "timer-1"), at: Date())
        roster.apply(try stop(ids[0]), at: Date())
        #expect(roster.agents.first?.shownType == "general-purpose")

        roster.apply(try mainStop([]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished, .finished])
    }

    @Test func clearingTakesOffOnlyWhatIsOver() throws {
        var roster = roster([
            try start("a1"), try start("a2"), try start("a3"),
            try stop("a1"), try event("StopFailure", ["agent_id": "a2"]),
        ])
        roster.apply(try event(ClaudeSubagents.clearEvent, [:]), at: Date())
        #expect(roster.agents.map(\.id) == ["a3"])
    }

    @Test func teammateIdleParksATeammateByName() throws {
        let id = "aresearcher-3d47be652e82ec66"
        var roster = roster([try start(id, type: "researcher")])
        roster.describe { _ in .init(description: "Research it", name: "researcher") }
        roster.apply(try event("TeammateIdle", ["teammate_name": "researcher"]), at: Date())
        #expect(roster.agents.first?.state == .idle)
        #expect(roster.agents.first?.isConfirmedTeammate == true)
    }

    @Test func aBackgroundSubagentOutlivesTheTurnWhileListed() throws {
        let running: [String: Any] = ["id": "a1", "type": "subagent", "status": "running"]
        var roster = roster([try start("a1"), try mainStop([running])])
        #expect(roster.agents.map(\.state) == [.working])
        #expect(roster.agents.first?.isListedAsTask == true)

        // Its stop was lost: the next list leaves it out.
        roster.apply(try mainStop([["id": "t1", "type": "shell", "status": "running"]]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])
    }

    /// The order Claude Code sent these in for one background Explore agent.
    @Test func aCapturedBackgroundRunEndsWhenItStops() throws {
        let task: [String: Any] = [
            "id": "ad72c5d40fe8b347d", "type": "subagent", "status": "running",
            "description": "Count files here", "agent_type": "Explore",
        ]
        var roster = roster([try start("ad72c5d40fe8b347d"), try mainStop([task])])
        #expect(roster.agents.map(\.state) == [.working])
        #expect(roster.agents.first?.title == "Count files here")

        roster.apply(try event("SubagentStop", [
            "agent_id": "ad72c5d40fe8b347d", "agent_type": "Explore", "background_tasks": [task],
        ]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])

        roster.apply(try mainStop([]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])
    }

    @Test func aRunningSubagentNeverSeenStartingIsAdded() throws {
        let roster = roster([try mainStop([
            ["id": "a9", "type": "subagent", "status": "running", "agent_type": "Plan", "description": "Plan it"],
        ])])
        #expect(roster.agents.map(\.id) == ["a9"])
        #expect(roster.agents.first?.title == "Plan it")
    }

    @Test func teammatesStayWhileTheListHasTeammates() throws {
        let id = "aresearcher-3d47be652e82ec66"
        let teammate: [String: Any] = ["id": "t-unrelated", "type": "teammate", "status": "running"]
        var roster = roster([try start(id, type: "researcher"), try mainStop([teammate])])
        #expect(roster.agents.count == 1)

        roster.apply(try mainStop([["id": "s1", "type": "shell", "status": "running"]]), at: Date())
        #expect(roster.agents.map(\.state) == [.finished])
    }

    @Test func aStopWithoutAListLeavesTheRoster() throws {
        let roster = roster([try start("a1"), try mainStop(nil)])
        #expect(roster.agents.count == 1)
    }

    @Test func describingFillsTheTranscriptAndMeta() throws {
        var roster = roster([try start("a1")])
        var asked: URL?
        roster.describe { url in
            asked = url
            return .init(description: "Explore sidebar")
        }
        let agent = try #require(roster.agents.first)
        #expect(agent.transcript?.lastPathComponent == "agent-a1.jsonl")
        #expect(asked?.lastPathComponent == "agent-a1.meta.json")
        #expect(agent.title == "Explore sidebar")
    }

    @Test func theRosterHasALimitAndFinishedOnesMakeRoom() throws {
        var events = try (0..<ClaudeSubagentRoster.limit).map { try start("a\($0)") }
        events.append(try stop("a3"))
        events.append(try start("anew"))
        events.append(try start("anewer"))
        let roster = roster(events)
        #expect(roster.agents.count == ClaudeSubagentRoster.limit)
        #expect(!roster.agents.contains { $0.id == "a3" })
        #expect(roster.agents.contains { $0.id == "anew" })
        #expect(!roster.agents.contains { $0.id == "anewer" })
    }

    // MARK: Reading the hooks' files

    @Test func theHookScriptAndReaderHandEventsOver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let events = root.appendingPathComponent("events")
        let script = try #require(ClaudePlugin.directory).appendingPathComponent("hooks/agent-event.sh")

        func hook(_ fields: [String: Any]) throws {
            var object: [String: Any] = ["session_id": Self.session, "transcript_path": Self.transcript]
            object.merge(fields) { _, new in new }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            process.environment = ["PATH": "/usr/bin:/bin", ClaudeSubagents.environmentVariable: events.path]
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: object))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        try hook(["hook_event_name": "SubagentStart", "agent_id": "a1", "agent_type": "Explore"])
        // A session without subagents isn't followed, but its events are handed over all
        // the same; the app's own clear event isn't.
        try hook(["hook_event_name": "Stop", "session_id": "ffffffff-19fa-41d2-8238-13269b9b3ca0", "last_assistant_message": "Done."])
        let clear = ["hook_event_name": ClaudeSubagents.clearEvent, "session_id": Self.session]
        try JSONSerialization.data(withJSONObject: clear).write(to: events.appendingPathComponent("9-clear.json"))
        let reader = ClaudeSubagentReader(events: events, rosters: root.appendingPathComponent("subagents.json"))
        let session = try #require(UUID(uuidString: Self.session))
        var handed: [(String, String?, Date)] = []
        let before = Date().addingTimeInterval(-5)
        let rosters = reader.read(at: Date(), handing: { event, writtenAt in
            handed.append((event.name, event.lastAssistantMessage, writtenAt))
        })
        #expect(rosters[session]?.map(\.id) == ["a1"])
        #expect(handed.map(\.0) == ["SubagentStart", "Stop"])
        #expect(handed.map(\.1) == [nil, "Done."])
        #expect(handed.allSatisfy { $0.2 >= before })
        #expect(try FileManager.default.contentsOfDirectory(atPath: events.path).isEmpty)

        // A new reader picks up the saved rosters.
        let again = ClaudeSubagentReader(events: events, rosters: root.appendingPathComponent("subagents.json"))
        try hook(["hook_event_name": "SubagentStop", "agent_id": "a1"])
        #expect(again.read(at: Date())[session]?.map(\.state) == [.finished])

        try hook(["hook_event_name": "SessionEnd", "reason": "exit"])
        #expect(again.read(at: Date())[session] == nil)
    }

    @Test func theHookDoesNothingOutsideMaggie() throws {
        let script = try #require(ClaudePlugin.directory).appendingPathComponent("hooks/agent-event.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test func thePluginHooksRunTheScriptForEachEvent() throws {
        let directory = try #require(ClaudePlugin.directory)
        let data = try Data(contentsOf: directory.appendingPathComponent("hooks/hooks.json"))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == ["SubagentStart", "SubagentStop", "TeammateIdle", "StopFailure", "Stop", "SessionEnd", "Notification"])
        for (name, entries) in hooks {
            let commands = try #require(entries as? [[String: Any]], Comment(rawValue: name))
            #expect(!commands.isEmpty, Comment(rawValue: name))
            #expect(commands.allSatisfy { ($0["hooks"] as? [[String: Any]])?.first?["command"] as? String == "/bin/sh \"${CLAUDE_PLUGIN_ROOT}/hooks/agent-event.sh\"" }, Comment(rawValue: name))
        }
    }

    // MARK: Transcript

    @Test func aTranscriptReadsAsItsPromptToolsAndText() {
        let lines = [
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"Find the sidebar"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Bash","input":{"command":"grep -rn Sidebar\nmore"}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"a.swift:1\nb.swift:2"}]}}"#,
            "not json",
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"It is in a.swift."}]}}"#,
        ].joined(separator: "\n")
        let markdown = ClaudeTranscriptMarkdown.markdown(fromJSONL: lines, title: "Explore sidebar")
        #expect(markdown == """
            # Explore sidebar

            ## Prompt

            > Find the sidebar

            Looking.

            **→ Bash** `grep -rn Sidebar…`

            ```
            a.swift:1
            b.swift:2
            ```

            It is in a.swift.

            """)
    }

    @Test func anEmptyTranscriptSaysSo() {
        #expect(ClaudeTranscriptMarkdown.markdown(fromJSONL: "", title: nil) == "_Nothing in the transcript yet._\n")
    }

    @Test func fencesAndCodeAreNeverClosedByWhatTheyHold() {
        #expect(ClaudeTranscriptMarkdown.fenced("a ``` b") == "````\na ``` b\n````")
        #expect(ClaudeTranscriptMarkdown.inlineCode("a `b`") == "`` a `b` ``")
    }

    @Test func onlyTranscriptsAreReadOnly() {
        #expect(ClaudeTranscriptMarkdown.handles(URL(fileURLWithPath: "/x/agent-a1.jsonl")))
        #expect(!ClaudeTranscriptMarkdown.handles(URL(fileURLWithPath: "/x/report.md")))
    }
}

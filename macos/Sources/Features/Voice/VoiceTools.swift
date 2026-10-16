import AppKit
import Foundation
import GhosttyKit

/// The tools the voice's backend runs Maggie with, and how each is done.
///
/// Every tool takes a session by reference: its number, or words from its title or folder
/// (see `VoiceSessionReference`). Results are JSON the backend reads; errors come back as
/// `{"error": ...}` so the backend can say what went wrong rather than guess.
@MainActor
final class VoiceTools {
    struct Definition {
        let name: String
        let description: String
        let parameters: [String: Any]

        var json: [String: Any] {
            ["type": "function", "name": name, "description": description, "parameters": parameters]
        }
    }

    /// Seconds a new session is given to start its agent before an instruction is typed.
    static let agentStartTimeout: TimeInterval = 60

    /// Entries of a session's history sent at most, and the characters they are cut to.
    static let historyEntryLimit = 60
    static let historyCharacterLimit = 8_000
    static let responseCharacterLimit = 2_500

    let directory: VoiceSessionDirectory
    let memory: VoiceMemoryStore

    /// Called when a session should be watched from now on, with its id.
    var watch: ((String) -> Void)?

    /// Called when the user asks for every session to be watched, or none.
    var watchAll: ((Bool) -> Void)?

    enum Control: String {
        case mute = "mute_microphone"
        case unmute = "unmute_microphone"
        case pause = "pause_voice"
        case hangUp = "hang_up"
    }

    /// Called with a spoken control: mute, unmute, pause, hang up.
    var control: ((Control) -> Void)?

    init(directory: VoiceSessionDirectory, memory: VoiceMemoryStore) {
        self.directory = directory
        self.memory = memory
    }

    // MARK: Definitions

    private static func session(_ description: String = "The session: its number, or words from its title or folder.") -> [String: Any] {
        ["type": "string", "description": description]
    }

    static let definitions: [Definition] = [
        Definition(
            name: "list_sessions",
            description: "Lists every open session with its number, title, folder, branch and status. Call it first when a reference is unclear, and for round-ups.",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "list_folders",
            description: "Lists the folders a new session can open in: the sidebar's folders, with how many sessions each has, and the folders under the home folder.",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "session_status",
            description: "Where a session stands: its status, how long, the last thing its agent said, and what its screen shows when it is waiting.",
            parameters: ["type": "object", "properties": ["session": session()], "required": ["session"]]),
        Definition(
            name: "session_history",
            description: "What happened in a session: the recent conversation between the user and the agent, with the tools it used. For summaries of what was done.",
            parameters: [
                "type": "object",
                "properties": [
                    "session": session(),
                    "entries": ["type": "integer", "description": "How many recent entries, up to 60. Default 30."],
                ],
                "required": ["session"],
            ]),
        Definition(
            name: "session_screen",
            description: "The last lines on a session's terminal screen, for a prompt or a question the agent is showing.",
            parameters: ["type": "object", "properties": ["session": session()], "required": ["session"]]),
        Definition(
            name: "new_session",
            description: "Opens a new session in a folder and, if given, tells it what to do once its agent is up. Returns the new session's number.",
            parameters: [
                "type": "object",
                "properties": [
                    "folder": ["type": "string", "description": "A sidebar folder's name, a path, or a folder under the home folder. Omit for the home folder."],
                    "message": ["type": "string", "description": "The instruction for the agent, written out in full."],
                    "title": ["type": "string", "description": "A short name for the session's tab."],
                ],
                "required": [],
            ]),
        Definition(
            name: "tell_session",
            description: "Types an instruction into a session's agent and submits it, as the user would. A working session queues it.",
            parameters: [
                "type": "object",
                "properties": [
                    "session": session(),
                    "message": ["type": "string", "description": "The instruction, written out in full for the agent."],
                ],
                "required": ["session", "message"],
            ]),
        Definition(
            name: "press_key",
            description: "Presses a key in a session, to answer a prompt: enter, escape, up, down, tab, y, n, a digit, or ctrl-c. Use session_screen first to see the prompt.",
            parameters: [
                "type": "object",
                "properties": [
                    "session": session(),
                    "key": ["type": "string", "description": "enter, escape, up, down, left, right, tab, space, y, n, 1-9, or ctrl-c."],
                    "times": ["type": "integer", "description": "How many times. Default 1."],
                ],
                "required": ["session", "key"],
            ]),
        Definition(
            name: "interrupt_session",
            description: "Stops what a session's agent is doing now (escape), leaving the session open.",
            parameters: ["type": "object", "properties": ["session": session()], "required": ["session"]]),
        Definition(
            name: "focus_session",
            description: "Brings a session to the front on the Mac's screen.",
            parameters: ["type": "object", "properties": ["session": session()], "required": ["session"]]),
        Definition(
            name: "rename_session",
            description: "Gives a session's tab a title.",
            parameters: [
                "type": "object",
                "properties": ["session": session(), "title": ["type": "string"]],
                "required": ["session", "title"],
            ]),
        Definition(
            name: "close_session",
            description: "Closes a session's tab. Refuses while a process runs unless force is true; ask the user before forcing.",
            parameters: [
                "type": "object",
                "properties": ["session": session(), "force": ["type": "boolean"]],
                "required": ["session"],
            ]),
        Definition(
            name: "watch_session",
            description: "Has Maggie report, as a notice, when a session finishes or needs the user. Pass \"all\" to watch every session, \"none\" to stop watching all.",
            parameters: [
                "type": "object",
                "properties": ["session": session("A session reference, or \"all\" or \"none\".")],
                "required": ["session"],
            ]),
        Definition(
            name: "mute_microphone",
            description: "Stops listening to the user until they say \"unmute\" or \"hey Maggie\", or click the microphone. For \"mute\", \"stop listening\", \"hold on\".",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "unmute_microphone",
            description: "Listens to the user again after a mute.",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "pause_voice",
            description: "Pauses the voice session to stop its billing; the Mac keeps listening for \"hey Maggie\" to continue. For \"pause\", \"go to sleep\", \"I'll be back\".",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "hang_up",
            description: "Ends the voice session altogether, after a short goodbye. For \"stop\", \"hang up\", \"that's all\", \"goodbye\".",
            parameters: ["type": "object", "properties": [:], "required": []]),
        Definition(
            name: "remember",
            description: "Keeps or recalls what you know about the user across days: terms they use, preferences, patterns, facts.",
            parameters: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": ["write", "list", "forget"]],
                    "kind": ["type": "string", "enum": VoiceMemoryNote.Kind.allCases.map(\.rawValue), "description": "For write."],
                    "content": ["type": "string", "description": "For write: the note, one sentence."],
                    "id": ["type": "string", "description": "For forget: the note's id from list."],
                ],
                "required": ["action"],
            ]),
    ]

    static var capabilities: [(name: String, description: String)] {
        definitions.map { ($0.name, $0.description) }
    }

    // MARK: Running

    func run(_ name: String, arguments: [String: Any]) async -> [String: Any] {
        switch name {
        case "list_sessions": return listSessions()
        case "list_folders": return listFolders()
        case "session_status": return withSession(arguments) { sessionStatus($0) }
        case "session_history": return withSession(arguments) { sessionHistory($0, entries: arguments["entries"] as? Int) }
        case "session_screen": return withSession(arguments) { sessionScreen($0) }
        case "new_session": return await newSession(arguments)
        case "tell_session": return withSession(arguments) { tell($0, message: arguments["message"] as? String ?? "") }
        case "press_key":
            return withSession(arguments) { press($0, key: arguments["key"] as? String ?? "", times: arguments["times"] as? Int ?? 1) }
        case "interrupt_session": return withSession(arguments) { press($0, key: "escape", times: 1) }
        case "focus_session": return withSession(arguments) { focus($0) }
        case "rename_session": return withSession(arguments) { rename($0, title: arguments["title"] as? String ?? "") }
        case "close_session": return withSession(arguments) { close($0, force: arguments["force"] as? Bool ?? false) }
        case "watch_session": return watchSession(arguments["session"] as? String ?? "")
        case "remember": return remember(arguments)
        case Control.mute.rawValue, Control.unmute.rawValue, Control.pause.rawValue, Control.hangUp.rawValue:
            guard let control = Control(rawValue: name) else { return ["error": "Unknown control."] }
            self.control?(control)
            switch control {
            case .mute: return ["muted": true, "say": "Tell the user you're muted and that \"unmute\" or \"hey Maggie\" brings you back."]
            case .unmute: return ["muted": false]
            case .pause: return ["pausing": true, "say": "Say a brief goodbye; the session pauses once you finish."]
            case .hangUp: return ["ending": true, "say": "Say a brief goodbye; the session ends once you finish."]
            }
        default: return ["error": "Unknown tool \(name)."]
        }
    }

    private func withSession(_ arguments: [String: Any], _ body: (VoiceSessionReference.Candidate) -> [String: Any]) -> [String: Any] {
        let reference = arguments["session"] as? String ?? ""
        directory.refresh()
        guard let candidate = directory.resolve(reference) else {
            let numbers = directory.candidates.map { "\($0.number): \($0.session.title)" }
            return [
                "error": "No single session matches \"\(reference)\".",
                "sessions": numbers,
            ]
        }
        return body(candidate)
    }

    // MARK: Listing

    func listSessions() -> [String: Any] {
        directory.refresh()
        let now = Date()
        let sessions = directory.candidates.map { directory.describe($0, now: now) }
        return ["count": sessions.count, "sessions": sessions]
    }

    /// The sessions as a line each, for the backend's instructions.
    func sessionsSummary() -> String {
        directory.refresh()
        let candidates = directory.candidates
        guard !candidates.isEmpty else { return "No sessions are open." }
        return candidates.map { candidate in
            let folder = candidate.folder.map { " in \($0)" } ?? ""
            return "- \(candidate.number): \(candidate.session.title)\(folder), \(candidate.session.lightLabel ?? "no agent")"
        }.joined(separator: "\n")
    }

    func listFolders() -> [String: Any] {
        directory.refresh()
        let snapshot = directory.snapshot
        let folders = snapshot.folders.map { folder -> [String: Any] in
            [
                "name": folder.name,
                "path": folder.abbreviatedPath,
                "sessions": folder.rows.flatMap(\.sessions).count,
                "git": folder.hasGit,
            ]
        }
        var result: [String: Any] = ["sidebar_folders": folders]
        let home = RemoteService.shared.homeFolder
        if case .success(let listing) = RemoteFolders.list(nil, home: home) {
            result["home"] = listing.displayPath
            result["home_folders"] = listing.entries.map { ["name": $0.name, "path": $0.path, "git": $0.isRepository] }
        }
        let favourites = memory.state.favouriteFolders.prefix(5).map { ($0 as NSString).abbreviatingWithTildeInPath }
        if !favourites.isEmpty { result["often_used"] = Array(favourites) }
        return result
    }

    // MARK: Reading a session

    private func surfaces(of window: TerminalWindow) -> [Ghostty.SurfaceView] {
        let controller = window.terminalController
        let leaves = controller?.surfaceTree.root?.leaves() ?? []
        let focused = controller?.focusedSurface
        return leaves.filter { $0 === focused } + leaves.filter { $0 !== focused }
    }

    private func agentSession(of window: TerminalWindow) -> AgentSession? {
        surfaces(of: window).lazy
            .compactMap { $0.surfaceModel?.foregroundPID }
            .compactMap { AgentSession.running(pid: $0) }
            .first
    }

    func sessionStatus(_ candidate: VoiceSessionReference.Candidate) -> [String: Any] {
        var result = directory.describe(candidate)
        guard let window = directory.window(for: candidate) else {
            result["error"] = "The session's window is gone."
            return result
        }
        if let session = agentSession(of: window), let last = ClaudeCodeResponse.last(inSession: session) {
            result["last_response"] = Self.trimmed(last, to: Self.responseCharacterLimit)
        }
        if candidate.session.light == .waiting || candidate.session.light == nil,
           let view = window.terminalController?.focusedSurface {
            result["screen"] = RemotePeek.lines(of: view.cachedVisibleContents.get()).suffix(12).joined(separator: "\n")
        }
        return result
    }

    func sessionHistory(_ candidate: VoiceSessionReference.Candidate, entries limit: Int?) -> [String: Any] {
        guard let window = directory.window(for: candidate) else { return ["error": "The session's window is gone."] }
        guard let session = agentSession(of: window), let transcript = session.transcript else {
            return ["number": candidate.number, "title": candidate.session.title, "history": "The session has no transcript yet."]
        }
        let count = min(max(limit ?? 30, 1), Self.historyEntryLimit)
        let entries = AgentHandoff.entries(inTranscript: transcript, of: session.agent).suffix(count)
        let lines = entries.map { entry -> String in
            switch entry {
            case .user(let text): return "User: \(text)"
            case .assistant(let text): return "Agent: \(text)"
            case .tool(let name, let input): return "Tool \(name): \(input)"
            case .toolResult(let text): return "Result: \(text)"
            }
        }
        var text = lines.joined(separator: "\n")
        if text.count > Self.historyCharacterLimit {
            text = "…" + text.suffix(Self.historyCharacterLimit)
        }
        return ["number": candidate.number, "title": candidate.session.title, "history": text]
    }

    func sessionScreen(_ candidate: VoiceSessionReference.Candidate) -> [String: Any] {
        guard let view = directory.window(for: candidate)?.terminalController?.focusedSurface else {
            return ["error": "The session's window is gone."]
        }
        return ["number": candidate.number, "screen": RemotePeek.lines(of: view.cachedVisibleContents.get()).joined(separator: "\n")]
    }

    // MARK: Acting on a session

    func newSession(_ arguments: [String: Any]) async -> [String: Any] {
        let request: NewSession
        var path: String?
        if let folder = (arguments["folder"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            directory.refresh()
            if let sidebar = Self.sidebarFolder(named: folder, in: directory.snapshot) {
                request = NewSession(folderID: sidebar.id)
                path = sidebar.path
            } else if let resolved = Self.homeFolder(named: folder) {
                request = NewSession(path: resolved)
                path = resolved
            } else {
                return ["error": "No folder matches \"\(folder)\". Call list_folders."]
            }
        } else {
            request = NewSession()
            path = RemoteService.shared.homeFolder.path
        }

        let created: SessionCreated
        switch RemoteCommands.newSession(request, home: RemoteService.shared.homeFolder, feed: directory.feed) {
        case .success(let session): created = session
        case .failure(let error): return ["error": error.message]
        }
        if let path { memory.recordFolderUse(path) }
        directory.refresh()
        guard let window = directory.feed.ids.window(for: created.id) else { return ["error": "The session opened but can't be found."] }
        if let title = (arguments["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            window.terminalController?.titleOverride = title
        }
        watch?(created.id)

        var result: [String: Any] = ["number": directory.number(for: created.id) ?? 0, "title": window.title]
        if let message = (arguments["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            guard await waitForAgent(in: window) else {
                result["error"] = "The session opened, but its agent didn't start in time, so nothing was typed."
                return result
            }
            type(message, into: window)
            result["told"] = true
        }
        return result
    }

    /// Waits for the agent in `window` to be at its prompt: its registry entry says it is
    /// idle, or a Codex title says so, or it has been running a few seconds.
    private func waitForAgent(in window: TerminalWindow) async -> Bool {
        let deadline = Date().addingTimeInterval(Self.agentStartTimeout)
        var seenAt: Date?
        while Date() < deadline {
            let pids = surfaces(of: window).compactMap { $0.surfaceModel?.foregroundPID }
            if let pid = pids.first(where: { ClaudeCodeSession.id(ofRunning: $0) != nil || CodexSession.running(pid: $0) != nil }) {
                if let activity = ClaudeCodeSession.activity(pid: pid), activity.status != "busy" {
                    // Idle at its prompt; a moment for the screen to settle.
                    try? await Task.sleep(for: .seconds(1))
                    return true
                }
                if seenAt == nil { seenAt = Date() }
                if let seenAt, Date().timeIntervalSince(seenAt) > 6 { return true }
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    private func type(_ message: String, into window: TerminalWindow) {
        guard let surface = window.terminalController?.focusedSurface?.surfaceModel else { return }
        surface.sendText(message)
        // Submitted on its own, after the paste, as the AppleScript harness does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                surface.sendKeyEvent(Ghostty.Input.KeyEvent(
                    synthesizing: .enter, action: .press, mods: [], translationMods: surface.keyTranslationMods([])))
            }
        }
    }

    func tell(_ candidate: VoiceSessionReference.Candidate, message: String) -> [String: Any] {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return ["error": "The message is empty."] }
        guard let window = directory.window(for: candidate) else { return ["error": "The session's window is gone."] }
        type(message, into: window)
        watch?(candidate.session.id)
        var result: [String: Any] = ["number": candidate.number, "told": true]
        if candidate.session.light == .working {
            result["note"] = "The session was working; the instruction is queued until it finishes."
        }
        return result
    }

    func press(_ candidate: VoiceSessionReference.Candidate, key name: String, times: Int) -> [String: Any] {
        guard let surface = directory.window(for: candidate)?.terminalController?.focusedSurface?.surfaceModel else {
            return ["error": "The session's window is gone."]
        }
        guard let (key, mods) = Self.key(named: name) else { return ["error": "Unknown key \"\(name)\"."] }
        for _ in 0..<min(max(times, 1), 20) {
            surface.sendKeyEvent(Ghostty.Input.KeyEvent(
                synthesizing: key, action: .press, mods: mods, translationMods: surface.keyTranslationMods(mods)))
        }
        return ["number": candidate.number, "pressed": name, "times": min(max(times, 1), 20)]
    }

    /// The key and modifiers a spoken key name means.
    static func key(named name: String) -> (Ghostty.Input.Key, Ghostty.Input.Mods)? {
        let lowered = name.lowercased().trimmingCharacters(in: .whitespaces)
        switch lowered {
        case "enter", "return": return (.enter, [])
        case "escape", "esc": return (.escape, [])
        case "up": return (.arrowUp, [])
        case "down": return (.arrowDown, [])
        case "left": return (.arrowLeft, [])
        case "right": return (.arrowRight, [])
        case "tab": return (.tab, [])
        case "space": return (.space, [])
        case "y", "yes": return (.y, [])
        case "n", "no": return (.n, [])
        case "ctrl-c", "ctrl+c", "control-c": return (.c, [.ctrl])
        case "ctrl-d", "ctrl+d", "control-d": return (.d, [.ctrl])
        default:
            if lowered.count == 1, let digit = lowered.first, digit.isNumber,
               let key = Ghostty.Input.Key(rawValue: "digit\(digit)") {
                return (key, [])
            }
            return nil
        }
    }

    func focus(_ candidate: VoiceSessionReference.Candidate) -> [String: Any] {
        guard RemoteCommands.focus(sessionID: candidate.session.id, feed: directory.feed) else {
            return ["error": "The session's window is gone."]
        }
        return ["number": candidate.number, "focused": true]
    }

    func rename(_ candidate: VoiceSessionReference.Candidate, title: String) -> [String: Any] {
        guard let controller = directory.window(for: candidate)?.terminalController else {
            return ["error": "The session's window is gone."]
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        controller.titleOverride = title.isEmpty ? nil : title
        directory.feed.setNeedsUpdate()
        return ["number": candidate.number, "title": title]
    }

    func close(_ candidate: VoiceSessionReference.Candidate, force: Bool) -> [String: Any] {
        switch RemoteCommands.close(sessionID: candidate.session.id, force: force, feed: directory.feed) {
        case .closed: return ["number": candidate.number, "closed": true]
        case .processRunning:
            return ["number": candidate.number, "closed": false, "error": "A process is still running in it. Ask the user, then close with force."]
        default: return ["error": "The session's window is gone."]
        }
    }

    func watchSession(_ reference: String) -> [String: Any] {
        switch reference.lowercased() {
        case "all", "everything", "*":
            watchAll?(true)
            return ["watching": "all"]
        case "none", "nothing", "stop":
            watchAll?(false)
            return ["watching": "none"]
        default:
            return withSession(["session": reference]) { candidate in
                watch?(candidate.session.id)
                return ["number": candidate.number, "watching": true]
            }
        }
    }

    // MARK: Memory

    func remember(_ arguments: [String: Any]) -> [String: Any] {
        switch arguments["action"] as? String {
        case "write":
            guard let content = (arguments["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
                return ["error": "Nothing to remember."]
            }
            let kind = (arguments["kind"] as? String).flatMap(VoiceMemoryNote.Kind.init(rawValue:)) ?? .fact
            let note = memory.remember(kind, content)
            return ["id": note.id, "kind": note.kind.rawValue, "content": note.text]
        case "list":
            return ["notes": memory.promptNotes.map { ["id": $0.id, "kind": $0.kind.rawValue, "content": $0.text] }]
        case "forget":
            guard let id = arguments["id"] as? String, memory.forget(id: id) else { return ["error": "No note has that id."] }
            return ["forgot": id]
        default:
            return ["error": "action must be write, list or forget."]
        }
    }

    // MARK: Folders

    /// The sidebar folder `name` means: by name, then by path or its last part, ignoring case.
    static func sidebarFolder(named name: String, in snapshot: SidebarSnapshot) -> SidebarFolder? {
        let lowered = name.lowercased()
        let folders = snapshot.folders
        if let exact = folders.first(where: { $0.name.lowercased() == lowered }) { return exact }
        if let byPath = folders.first(where: {
            $0.path.lowercased() == lowered || $0.abbreviatedPath.lowercased() == lowered ||
                URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == lowered
        }) { return byPath }
        let contains = folders.filter { $0.name.lowercased().contains(lowered) }
        return contains.count == 1 ? contains[0] : nil
    }

    /// A folder under the home folder: the path as given, or a folder in it by name.
    static func homeFolder(named name: String) -> String? {
        let home = RemoteService.shared.homeFolder
        let expanded = (name as NSString).expandingTildeInPath
        if expanded.hasPrefix("/"), let url = RemoteFolders.resolve(expanded, home: home) { return url.path }
        if case .success(let listing) = RemoteFolders.list(nil, home: home) {
            let lowered = name.lowercased()
            if let entry = listing.entries.first(where: { $0.name.lowercased() == lowered }) { return entry.path }
            let contains = listing.entries.filter { $0.name.lowercased().contains(lowered) }
            if contains.count == 1 { return contains[0].path }
        }
        return nil
    }

    static func trimmed(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "…" : text
    }
}

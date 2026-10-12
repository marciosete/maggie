import Foundation

/// A subagent or teammate a Claude Code session started, as the sidebar lists it under
/// the session's tab.
struct ClaudeSubagent: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// It is working.
        case working

        /// A teammate between turns: alive, waiting for a message.
        case idle

        /// It finished. It stays listed, so what it did can still be read.
        case finished

        /// Its turn ended on an API error.
        case failed

        var isOver: Bool { self == .finished || self == .failed }
    }

    /// Claude Code's `agent_id`.
    let id: String
    var agentType: String?

    /// The name a teammate was given, from the subagent's `.meta.json`.
    var name: String?

    /// What it was asked to do, in a few words, from the subagent's `.meta.json`.
    var description: String?

    /// The type a named agent runs as, such as `general-purpose`, from its `.meta.json`.
    /// Its `agentType` is its name.
    var runsAs: String?
    var state: State
    var startedAt: Date

    /// Its own transcript, in the session's `subagents/` folder.
    var transcript: URL?

    /// A `TeammateIdle` named it, so it is a teammate that outlives its turns.
    var isConfirmedTeammate = false

    /// A `Stop`'s `background_tasks` listed it by its id, so a later list that leaves
    /// it out means it is gone, whatever its id looks like.
    var isListedAsTask = false

    /// What the sidebar calls it: what it was asked to do, else its name or type.
    var title: String {
        description.flatMap { $0.isEmpty ? nil : $0 }
            ?? name.flatMap { $0.isEmpty ? nil : $0 }
            ?? agentType.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Subagent"
    }

    /// The kind of agent it is, when that says more than its title and name.
    var shownType: String? {
        guard let type = runsAs ?? agentType, !type.isEmpty, type != title, type != name else { return nil }
        return type
    }

    /// Teammates and named agents have ids like `a<name>-<hex>`, one-shot subagents
    /// `a<hex>`. A teammate's `SubagentStop` ends a turn, not the teammate.
    static func isTeammateID(_ id: String) -> Bool {
        let bare = id.hasPrefix("agent-") ? String(id.dropFirst("agent-".count)) : id
        guard let separator = bare.lastIndex(of: "-"), bare.hasPrefix("a"),
              bare.distance(from: bare.startIndex, to: separator) > 1 else { return false }
        let tail = bare[bare.index(after: separator)...]
        return !tail.isEmpty && tail.allSatisfy(\.isHexDigit)
    }

    /// Where Claude Code keeps the transcript of subagent `id` of the session whose
    /// transcript is `sessionTranscript`: `<session>/subagents/agent-<id>.jsonl`.
    static func transcript(of id: String, sessionTranscript: URL) -> URL {
        let file = id.hasPrefix("agent-") ? id : "agent-\(id)"
        return sessionTranscript.deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(file + ".jsonl")
    }
}

/// A hook event Claude Code passed to the plugin's `agent-event.sh`, with the fields the
/// roster uses.
struct ClaudeAgentEvent: Equatable {
    struct Task: Equatable {
        let id: String
        let type: String
        let isRunning: Bool
        let agentType: String?
        let description: String?
    }

    let name: String
    let sessionID: String
    let agentID: String?
    let agentType: String?
    let transcript: URL?
    let agentTranscript: URL?
    let teammateName: String?

    /// A `Stop`'s or `SubagentStop`'s `background_tasks`, when Claude Code could list
    /// them.
    let backgroundTasks: [Task]?

    init?(json data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hook_event_name"] as? String,
              let sessionID = object["session_id"] as? String, !sessionID.isEmpty else { return nil }
        func string(_ key: String) -> String? {
            (object[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        func url(_ key: String) -> URL? {
            string(key).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        self.name = name
        self.sessionID = sessionID
        agentID = string("agent_id")
        agentType = string("agent_type")
        transcript = url("transcript_path")
        agentTranscript = url("agent_transcript_path")
        teammateName = string("teammate_name")
        backgroundTasks = (object["background_tasks"] as? [[String: Any]]).map { tasks in
            tasks.compactMap { task in
                guard let id = task["id"] as? String, let type = task["type"] as? String else { return nil }
                let status = (task["status"] as? String)?.lowercased() ?? ""
                return Task(
                    id: id,
                    type: type,
                    isRunning: status == "running" || status == "pending",
                    agentType: task["agent_type"] as? String,
                    description: task["description"] as? String)
            }
        }
    }
}

/// The subagents and teammates of one Claude Code session, kept up to date from its hook
/// events.
///
/// What Claude Code reports is uneven, so this follows the rules Orca learned:
/// - A one-shot subagent's `SubagentStop` (or a `StopFailure` naming it) ends it.
/// - A teammate's ends only a turn; it goes idle and starts working again with its next
///   `SubagentStart`.
/// - A stop can be lost, so the main session's `Stop` lists its background tasks, and
///   the roster is checked against that list: a one-shot it leaves out is over, a
///   running one never seen starting is added, and teammates are over when the list has
///   none.
///
/// Agents that are over stay listed, so their transcripts can still be read, until they
/// are cleared, the session ends or newer ones need their room.
struct ClaudeSubagentRoster: Codable, Equatable {
    /// More than this aren't listed. A finished one makes room before one still alive.
    static let limit = 64

    private(set) var agents: [ClaudeSubagent] = []

    /// When the session last reported anything, so a roster left behind by a session
    /// that ended without saying so is dropped in time.
    var updatedAt: Date

    /// The session's transcript, from its events.
    var transcript: URL?

    init(updatedAt: Date) {
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool { agents.isEmpty }

    mutating func apply(_ event: ClaudeAgentEvent, at now: Date) {
        updatedAt = now
        if let transcript = event.transcript { self.transcript = transcript }

        switch event.name {
        case "SubagentStart":
            // Claude Code's own helpers, such as prompt suggestions and /btw, have no type.
            guard let id = event.agentID, let type = event.agentType else { return }
            start(id, type: type, transcript: event.agentTranscript, at: now)

        case "SubagentStop":
            guard let id = event.agentID else { return }
            endTurn(of: id, transcript: event.agentTranscript)

        case "StopFailure":
            // An API error skips the child's SubagentStop; this names it instead.
            if let id = event.agentID, let index = index(of: id) { agents[index].state = .failed }

        case "TeammateIdle":
            guard let index = event.agentID.flatMap(index(of:))
                ?? event.teammateName.flatMap({ name in agents.firstIndex { $0.name == name || $0.agentType == name } })
            else { return }
            agents[index].state = .idle
            agents[index].isConfirmedTeammate = true

        case ClaudeSubagents.clearEvent:
            agents.removeAll { $0.state.isOver }

        case "Stop":
            // A Stop inside a subagent arrives as SubagentStop, so this is the main
            // session ending its turn.
            guard event.agentID == nil else { return }
            if let tasks = event.backgroundTasks { reconcile(with: tasks, at: now) }

        default:
            break
        }
    }

    /// Fills in what the session's files say about each subagent: its transcript, and
    /// the description and name in its `.meta.json`.
    mutating func describe(_ read: (URL) -> ClaudeSubagentReader.Meta?) {
        for index in agents.indices {
            if agents[index].transcript == nil, let transcript {
                agents[index].transcript = ClaudeSubagent.transcript(of: agents[index].id, sessionTranscript: transcript)
            }
            guard agents[index].description == nil, let file = agents[index].transcript,
                  let meta = read(file.deletingPathExtension().appendingPathExtension("meta.json")) else { continue }
            agents[index].description = meta.description
            agents[index].name = agents[index].name ?? meta.name
            agents[index].runsAs = meta.type
        }
    }

    private func index(of id: String) -> Int? {
        agents.firstIndex { $0.id == id }
    }

    private mutating func start(_ id: String, type: String?, transcript: URL?, at now: Date) {
        if let index = index(of: id) {
            agents[index].state = .working
            agents[index].agentType = type ?? agents[index].agentType
            if let transcript { agents[index].transcript = transcript }
            return
        }
        if agents.count >= Self.limit {
            guard let index = agents.firstIndex(where: { $0.state.isOver })
                ?? agents.firstIndex(where: { $0.state != .working }) else { return }
            agents.remove(at: index)
        }
        agents.append(ClaudeSubagent(id: id, agentType: type, state: .working, startedAt: now, transcript: transcript))
    }

    private mutating func endTurn(of id: String, transcript: URL?) {
        guard let index = index(of: id) else { return }
        if let transcript { agents[index].transcript = transcript }
        if ClaudeSubagent.isTeammateID(id) && !agents[index].isListedAsTask {
            agents[index].state = .idle
        } else {
            agents[index].state = .finished
        }
    }

    private mutating func reconcile(with tasks: [ClaudeAgentEvent.Task], at now: Date) {
        // Nothing in flight: nothing can still be alive.
        guard !tasks.isEmpty else {
            finish { _ in true }
            return
        }

        // Teammate tasks have ids of their own, but that there are any says teammates
        // may still be alive.
        let hasTeammates = tasks.contains { $0.type == "teammate" }
        let subagentTasks = tasks.filter { $0.type == "subagent" }
        let listed = Set(subagentTasks.map(\.id))

        for task in subagentTasks {
            if let index = index(of: task.id) {
                if task.isRunning {
                    agents[index].state = .working
                    agents[index].isListedAsTask = true
                    agents[index].agentType = agents[index].agentType ?? task.agentType
                    agents[index].description = agents[index].description ?? task.description
                } else if !agents[index].state.isOver {
                    agents[index].state = .finished
                }
            } else if task.isRunning, agents.count < Self.limit {
                // Started while Maggie wasn't listening.
                var agent = ClaudeSubagent(id: task.id, agentType: task.agentType, state: .working, startedAt: now)
                agent.description = task.description
                agent.isListedAsTask = true
                agents.append(agent)
            }
        }

        finish { agent in
            guard !listed.contains(agent.id) else { return false }
            // A teammate's id is never listed; it lives on while the list has teammates.
            let keepsTeammate = ClaudeSubagent.isTeammateID(agent.id) && !agent.isListedAsTask && hasTeammates
                && (agent.state == .working || agent.isConfirmedTeammate)
            return !keepsTeammate
        }
    }

    /// Marks the agents `isGone` picks, and not already over, as finished.
    private mutating func finish(_ isGone: (ClaudeSubagent) -> Bool) {
        for index in agents.indices where !agents[index].state.isOver && isGone(agents[index]) {
            agents[index].state = .finished
        }
    }
}

/// The subagents of every Claude Code session in the app, by session.
///
/// The plugin's hooks drop each event as a file in `eventsDirectory` (see
/// `agent-event.sh`). The folder is watched; each new file is read into its session's
/// roster and deleted, and the rosters are saved, so the app picks up where it was after
/// a relaunch, and events from while it wasn't running are read when it starts.
@MainActor
final class ClaudeSubagents: ObservableObject {
    static let shared = ClaudeSubagents()

    /// The variable that tells `agent-event.sh` where to put events.
    nonisolated static let environmentVariable = "MAGGIE_AGENT_EVENTS"

    /// The event the app drops in with the hooks' to clear a session's finished agents,
    /// so the clear is read in order with them and saved.
    nonisolated static let clearEvent = "MaggieClearFinished"

    /// A roster nothing has been heard from for this long is dropped: its session ended
    /// without a `SessionEnd`.
    nonisolated static let maxAge: TimeInterval = 2 * 24 * 60 * 60

    /// With the app's other data, apart for each build, so Maggie and Maggie Dev don't
    /// read each other's events.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Agent Events", isDirectory: true)
    }

    nonisolated static var eventsDirectory: URL { directory.appendingPathComponent("events", isDirectory: true) }
    nonisolated static var rostersFile: URL { directory.appendingPathComponent("subagents.json") }

    /// Each session's subagents, by session id. Sessions with none aren't in it.
    @Published private(set) var rosters: [UUID: [ClaudeSubagent]] = [:]

    private let reader = ClaudeSubagentReader(events: ClaudeSubagents.eventsDirectory, rosters: ClaudeSubagents.rostersFile)
    private var watch: DispatchSourceFileSystemObject?
    private var isReading = false
    private var readAgain = false

    private init() {}

    /// Starts reading events, once.
    func start() {
        guard watch == nil else { return }
        try? FileManager.default.createDirectory(at: Self.eventsDirectory, withIntermediateDirectories: true)
        let fd = open(Self.eventsDirectory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watch = source
        read()
    }

    /// Sessions whose subagents the sidebar folds away, by session id.
    @Published private(set) var collapsed: Set<UUID> = []

    func isCollapsed(_ sessions: [UUID]) -> Bool {
        sessions.contains { collapsed.contains($0) }
    }

    func setCollapsed(_ sessions: [UUID], _ isCollapsed: Bool) {
        if isCollapsed { collapsed.formUnion(sessions) } else { collapsed.subtract(sessions) }
    }

    /// Takes the agents of `sessions` that are over off the list.
    func clearFinished(of sessions: [UUID]) {
        for session in sessions {
            guard let agents = rosters[session] else { continue }
            let left = agents.filter { !$0.state.isOver }
            rosters[session] = left.isEmpty ? nil : left
        }
        let directory = Self.eventsDirectory
        DispatchQueue.global(qos: .utility).async {
            for session in sessions {
                let event = ["hook_event_name": Self.clearEvent, "session_id": session.uuidString.lowercased()]
                guard let data = try? JSONSerialization.data(withJSONObject: event) else { continue }
                let file = directory.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-clear-\(session.uuidString).json")
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// The subagents of `sessions`, oldest first.
    func agents(of sessions: [UUID]) -> [ClaudeSubagent] {
        sessions.flatMap { rosters[$0] ?? [] }.sorted { $0.startedAt < $1.startedAt }
    }

    private func read() {
        guard !isReading else {
            readAgain = true
            return
        }
        isReading = true
        let reader = reader
        DispatchQueue.global(qos: .utility).async {
            let rosters = reader.read(at: Date())
            DispatchQueue.main.async {
                self.isReading = false
                if self.rosters != rosters { self.rosters = rosters }
                if self.readAgain {
                    self.readAgain = false
                    self.read()
                }
            }
        }
    }
}

/// Reads the event files into the rosters and saves them. One read runs at a time.
final class ClaudeSubagentReader: @unchecked Sendable {
    private let events: URL
    private let rostersFile: URL

    /// Loaded from `rostersFile` on the first read.
    private var rosters: [String: ClaudeSubagentRoster]?

    init(events: URL, rosters: URL) {
        self.events = events
        rostersFile = rosters
    }

    func read(at now: Date) -> [UUID: [ClaudeSubagent]] {
        var rosters = self.rosters ?? load()
        let before = rosters

        for (file, event) in pendingEvents() {
            if let event {
                if event.name == "SessionEnd" {
                    rosters[event.sessionID] = nil
                } else if event.name == "SubagentStart" || rosters[event.sessionID] != nil {
                    // A session without subagents needn't be followed for its Stops.
                    var roster = rosters[event.sessionID] ?? ClaudeSubagentRoster(updatedAt: now)
                    roster.apply(event, at: now)
                    rosters[event.sessionID] = roster
                }
            }
            try? FileManager.default.removeItem(at: file)
        }

        for (id, roster) in rosters {
            var roster = roster
            if roster.isEmpty || now.timeIntervalSince(roster.updatedAt) > ClaudeSubagents.maxAge {
                rosters[id] = nil
                continue
            }
            roster.describe(Self.meta(at:))
            rosters[id] = roster
        }

        self.rosters = rosters
        if rosters != before { save(rosters) }

        var shown: [UUID: [ClaudeSubagent]] = [:]
        for (id, roster) in rosters {
            guard let uuid = UUID(uuidString: id) else { continue }
            shown[uuid] = roster.agents
        }
        return shown
    }

    /// The event files, in the order they were written. A file that isn't an event
    /// comes with nil, to be deleted.
    private func pendingEvents() -> [(URL, ClaudeAgentEvent?)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: events, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = files
            .filter { $0.pathExtension == "json" }
            .map { file in
                (file, (try? file.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast)
            }
            .sorted { ($0.1, $0.0.lastPathComponent) < ($1.1, $1.0.lastPathComponent) }
        return dated.map { file, _ in
            (file, (try? Data(contentsOf: file)).flatMap(ClaudeAgentEvent.init(json:)))
        }
    }

    private func load() -> [String: ClaudeSubagentRoster] {
        guard let data = try? Data(contentsOf: rostersFile) else { return [:] }
        return (try? JSONDecoder().decode([String: ClaudeSubagentRoster].self, from: data)) ?? [:]
    }

    private func save(_ rosters: [String: ClaudeSubagentRoster]) {
        guard let data = try? JSONEncoder().encode(rosters) else { return }
        try? data.write(to: rostersFile, options: .atomic)
    }

    /// What a subagent's `.meta.json` says about it.
    struct Meta {
        var description: String?
        var name: String?

        /// The type it runs as, such as `general-purpose` for a named agent.
        var type: String?
    }

    static func meta(at url: URL) -> Meta? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Meta(
            description: object["description"] as? String,
            name: object["name"] as? String,
            type: object["spawnedAgentType"] as? String)
    }
}

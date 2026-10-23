import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog

/// Where the voice's audio comes from and goes to: the Mac's own microphone and speaker,
/// or a paired device acting as a handset. One source at a time; every sink hears.
@MainActor
protocol VoiceAudioEndpoint: AnyObject {
    /// A name for the status popover: "This Mac", "Marcio's iPhone".
    var endpointName: String { get }

    /// Starts sending microphone audio to `onChunk`, in `VoiceAudioFormat` chunks.
    func startCapture(muted: Bool, onChunk: @escaping @Sendable (Data) -> Void) throws

    func setMuted(_ muted: Bool)
    func stopCapture()

    /// Given what the microphone hears while muted, on any thread, so the Mac can listen
    /// for "unmute" in it. GPT-Live is sent silence meanwhile.
    var onMutedAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? { get set }

    /// Plays speech as it arrives.
    func play(_ pcm: Data)

    /// Speech held back for smoothness plays now; the utterance is over.
    func flushPlayback()

    /// Drops speech that hasn't played.
    func stopPlayback()
}

/// The Mac's own microphone and speaker.
@MainActor
final class LocalVoiceEndpoint: VoiceAudioEndpoint {
    let endpointName = "This Mac"
    private let audio = VoiceAudioEngine()

    var echoCancellation = true

    /// The devices to use, by UID; empty for the system's defaults.
    var inputDeviceUID = ""
    var outputDeviceUID = ""

    var isPlaying: Bool { audio.isPlaying }
    var onPlayingChanged: (@MainActor (Bool) -> Void)? {
        get { audio.onPlayingChanged }
        set { audio.onPlayingChanged = newValue }
    }

    /// Chunks captured and bytes played since the engine started.
    var stats: (captured: Int, played: Int) { audio.stats }

    func startCapture(muted: Bool, onChunk: @escaping @Sendable (Data) -> Void) throws {
        audio.isMuted = muted
        try audio.start(
            echoCancellation: echoCancellation,
            inputDevice: VoiceDevices.device(uid: inputDeviceUID),
            outputDevice: VoiceDevices.device(uid: outputDeviceUID),
            onChunk: onChunk)
    }

    var onMutedAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { audio.onMutedAudio }
        set { audio.onMutedAudio = newValue }
    }

    func setMuted(_ muted: Bool) { audio.isMuted = muted }
    func stopCapture() { audio.stop() }

    /// The Mac's engine is running, and so may be holding Apple's voice processing.
    var isCapturing: Bool { audio.isCapturing }
    var isVoiceProcessing: Bool { audio.isVoiceProcessing }
    func play(_ pcm: Data) { audio.play(pcm) }
    func flushPlayback() { audio.flush() }
    func stopPlayback() { audio.stopPlayback() }
}

/// Settings for the voice, in UserDefaults.
@MainActor
final class VoiceSettings: ObservableObject {
    static let shared = VoiceSettings()

    private static let voiceKey = "VoiceOpenAIVoice"
    private static let backendModelKey = "VoiceBackendModel"
    private static let idleMinutesKey = "VoiceIdleMinutes"
    private static let announceAllKey = "VoiceAnnounceAllSessions"
    private static let echoCancellationKey = "VoiceEchoCancellation"
    private static let userNameKey = "VoiceUserName"
    private static let inputDeviceKey = "VoiceInputDeviceUID"
    private static let outputDeviceKey = "VoiceOutputDeviceUID"

    static let voices = ["marin", "quartz", "ripple", "vesper", "willow", "stone", "gleam", "meridian", "bossa", "tempo", "beacon", "delta", "cinder"]
    static let backendModels = ["gpt-5.6-terra", "gpt-5.6-sol", "gpt-5.6-luna", "gpt-5.5"]

    /// GPT-Live's voice. `quartz` and `ripple` are Australian.
    @Published var voice: String { didSet { UserDefaults.ghostty.set(voice, forKey: Self.voiceKey) } }

    /// The Responses model the voice delegates to.
    @Published var backendModel: String { didSet { UserDefaults.ghostty.set(backendModel, forKey: Self.backendModelKey) } }

    /// Minutes without the user speaking before the session is paused, to stop the
    /// per-second billing. Zero never pauses.
    @Published var idleMinutes: Int { didSet { UserDefaults.ghostty.set(idleMinutes, forKey: Self.idleMinutesKey) } }

    /// Announce every session's changes, not only the ones the voice touched.
    @Published var announcesAllSessions: Bool { didSet { UserDefaults.ghostty.set(announcesAllSessions, forKey: Self.announceAllKey) } }

    @Published var echoCancellation: Bool { didSet { UserDefaults.ghostty.set(echoCancellation, forKey: Self.echoCancellationKey) } }

    /// What the voice calls the user, if they want it to.
    @Published var userName: String { didSet { UserDefaults.ghostty.set(userName, forKey: Self.userNameKey) } }

    /// The microphone and speaker, by device UID; empty means the system's default.
    @Published var inputDeviceUID: String { didSet { UserDefaults.ghostty.set(inputDeviceUID, forKey: Self.inputDeviceKey) } }
    @Published var outputDeviceUID: String { didSet { UserDefaults.ghostty.set(outputDeviceUID, forKey: Self.outputDeviceKey) } }

    private init() {
        let defaults = UserDefaults.ghostty
        voice = defaults.string(forKey: Self.voiceKey).flatMap { $0.isEmpty ? nil : $0 } ?? "marin"
        backendModel = defaults.string(forKey: Self.backendModelKey).flatMap { $0.isEmpty ? nil : $0 } ?? "gpt-5.6-terra"
        idleMinutes = defaults.object(forKey: Self.idleMinutesKey) as? Int ?? 15
        announcesAllSessions = defaults.bool(forKey: Self.announceAllKey)
        echoCancellation = defaults.object(forKey: Self.echoCancellationKey) as? Bool ?? true
        userName = defaults.string(forKey: Self.userNameKey) ?? ""
        inputDeviceUID = defaults.string(forKey: Self.inputDeviceKey) ?? ""
        outputDeviceUID = defaults.string(forKey: Self.outputDeviceKey) ?? ""
    }
}

/// The voice: a GPT-Live session the user talks to, whose backend runs Maggie through
/// `VoiceTools`. It stays up for as long as the user wants, pausing itself when they go
/// quiet and waking when they come back or a watched session has news, and rolling to a
/// fresh GPT-Live session before the two-hour limit on one.
@MainActor
final class VoiceAgent: ObservableObject {
    static let shared = VoiceAgent()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: VoiceAgent.self)
    )

    enum Phase: Equatable {
        case off
        case connecting

        /// Talking, or ready to.
        case live

        /// The GPT-Live session was closed to save money while the user was quiet. Speech,
        /// a click, or a session's news starts it again.
        case paused

        case failed(String)

        var isOn: Bool { self != .off && !isFailed }
        var isFailed: Bool { if case .failed = self { return true } else { return false } }
    }

    /// The user's words are checked for "mute" once no more have come for this long.
    static let commandSettle: TimeInterval = 0.35

    /// A pause in arriving speech this long ends the reply being silenced by a mute.
    static let replyGap: TimeInterval = 1.5

    /// A pause this long ends the user's spoken turn in the transcript.
    static let userPause: TimeInterval = 2.0
    static let assistantPause: TimeInterval = 0.9

    /// A session is rolled over this long before GPT-Live says it expires.
    static let rolloverMargin: TimeInterval = 4 * 60

    /// A tool batch taking longer than this gets a spoken "still on it", then one every
    /// `holdInterval`.
    static let holdThreshold: TimeInterval = 6
    static let holdInterval: TimeInterval = 20

    /// GPT-Live is given this long to confirm a close.
    static let closeTimeout: TimeInterval = 8

    /// Transcript turns carried into a new GPT-Live session.
    static let seedTurns = 40

    static let perMinuteUSD = 0.05

    @Published private(set) var phase: Phase = .off {
        didSet { if phase != oldValue { updateWakeListening() } }
    }
    @Published private(set) var isMuted = false
    @Published private(set) var turns: [VoiceTurn] = []
    @Published private(set) var userSpeaking = false
    @Published private(set) var assistantSpeaking = false
    @Published private(set) var workingOn: String?

    /// Seconds billed across every GPT-Live session since the voice was turned on.
    @Published private(set) var billedSeconds: Double = 0
    @Published private(set) var contextRatio: Double = 0
    @Published private(set) var endpointName = "This Mac"

    /// macOS's answers for the microphone and speech recognition, as last read; asked
    /// for when the voice starts, and read again when the app comes to the front, since
    /// the user may have been to System Settings.
    @Published private(set) var microphoneAccess = VoicePermission.microphone.state
    @Published private(set) var speechAccess = VoicePermission.speechRecognition.state

    /// Why the Mac can't listen for "hey Maggie" and "unmute", while that is so: speech
    /// recognition refused, or the microphone not opening. Shown in the popover.
    @Published private(set) var wakeProblem: String?

    var estimatedCostUSD: Double { billedSeconds / 60 * Self.perMinuteUSD }

    let settings = VoiceSettings.shared
    let memory = VoiceMemoryStore(file: VoiceMemoryStore.defaultDirectory.appendingPathComponent("memory.json"))
    let log = VoiceTranscriptLog(directory: VoiceMemoryStore.defaultDirectory.appendingPathComponent("transcripts", isDirectory: true))
    let directory = VoiceSessionDirectory()
    private(set) lazy var tools = VoiceTools(directory: directory, memory: memory)

    private let localEndpoint = LocalVoiceEndpoint()
    private var endpoint: VoiceAudioEndpoint

    private var socket: OpenAILiveSocket?
    private var ledger = VoiceLedger()
    private var sessionSeconds: Double = 0
    private var started = false
    private var closing = false
    private var expiresAt: Date?
    private var lastUserSpeech = Date()
    private var reconnects = 0
    private var watched: Set<String> = []
    private var watchRules = VoiceWatchRules()
    private var timers: [String: Timer] = [:]
    private var maintenance: Timer?

    /// Function calls gathered from a backend response, run once the response ends.
    private var pendingCalls: [String: [(callID: String, name: String, arguments: String)]] = [:]
    private var answeredCalls: Set<String> = []
    private var runningTools = 0

    /// Notices that arrived while the backend was busy, sent when it is free.
    private var queuedNotices: [String] = []

    /// The backend has a response in flight; a notice sent now would collide with it.
    private var backendBusy = false

    /// Speech chunks received from GPT-Live, for the log.
    private var outputChunks = 0

    /// Of those, dropped because the user muted mid-reply.
    private var silencedChunks = 0

    private var settingsObservers: Set<AnyCancellable> = []

    /// Hears "unmute" and "hey Maggie" on the Mac while muted or paused.
    private let wake = VoiceWakeListener()

    /// The last reason the wake listener gave for not working, said once, not every time.
    private var wakeFailure: String?

    /// The hook events Claude Code sends the app, while the voice is on, and since when:
    /// a backlog written while it was off is old news.
    private var hookEvents: AnyCancellable?
    private var hookSince = Date()

    /// A hook event written this long before the voice started still counts as news.
    static let hookGrace: TimeInterval = 2

    /// The reply under way when the user muted is dropped as it arrives, until it ends.
    private var silencingReply = false

    /// What the voice said last, so its own words, echoing back, can't wake it.
    private var lastAssistantText = ""

    /// What to do once the voice finishes saying its goodbye.
    private var afterSpeaking: (() -> Void)?

    private init() {
        endpoint = localEndpoint
        localEndpoint.onMutedAudio = { [wake] buffer in wake.append(buffer) }
        localEndpoint.onPlayingChanged = { [weak self] playing in
            self?.assistantSpeaking = playing
            // What the voice just said, echoing back, can't count as the user's "unmute".
            if !playing { self?.wake.reset() }
            if !playing, self?.afterSpeaking != nil {
                self?.schedule("after-speaking", after: 0.4) { [weak self] in self?.speakingEnded() }
            }
        }
        directory.onChange = { [weak self] old, new in
            self?.sessionsChanged(from: old, to: new)
        }
        Publishers.Merge3(settings.$inputDeviceUID, settings.$outputDeviceUID, settings.$echoCancellation.map { _ in "" })
            .dropFirst(3)
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.audioSettingsChanged() }
            }
            .store(in: &settingsObservers)
        tools.watch = { [weak self] id in self?.watch(id) }
        tools.watchAll = { [weak self] all in self?.watchAll(all) }
        tools.control = { [weak self] control in self?.control(control) }
        wake.onWake = { [weak self] phrase in self?.woken(by: phrase) }
        wake.onFailure = { [weak self] message in self?.wakeFailed(message) }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshPermissions() }
            }
            .store(in: &settingsObservers)
    }

    // MARK: Permissions

    /// Reads macOS's answers again: after the user has been to System Settings, say. A
    /// wake problem that was the speech permission is over once it is allowed, and the
    /// Mac listens again if it should be.
    func refreshPermissions() {
        microphoneAccess = VoicePermission.microphone.state
        speechAccess = VoicePermission.speechRecognition.state
        if speechAccess == .allowed, wakeProblem != nil {
            wakeProblem = nil
            wakeFailure = nil
            updateWakeListening()
        }
    }

    /// Asks macOS for `permission` now, from Settings › Voice.
    func request(_ permission: VoicePermission) async {
        _ = await permission.request()
        refreshPermissions()
    }

    /// Clears macOS's answer for `permission` and asks afresh: for one declined, or one
    /// given to an earlier signature of the app that this build doesn't match.
    func resetAndRequest(_ permission: VoicePermission) async throws {
        _ = try await permission.resetAndRequest()
        refreshPermissions()
    }

    /// The Mac can't listen for a wake phrase: shown while it matters, said once.
    private func wakeFailed(_ message: String) {
        wakeProblem = message
        guard wakeFailure != message else { return }
        wakeFailure = message
        record(.notice, message)
    }

    /// A spoken control, from the backend's tool.
    private func control(_ control: VoiceTools.Control) {
        switch control {
        case .mute: setMuted(true)
        case .unmute: setMuted(false)
        case .pause:
            onceQuiet { [weak self] in
                guard let self, self.phase == .live else { return }
                self.record(.notice, "Paused by request. Say \"hey Maggie\" or click to continue.")
                self.closeSession(then: .paused)
            }
        case .hangUp:
            onceQuiet { [weak self] in self?.stop() }
        }
    }

    /// Runs `action` once the voice has finished speaking, or after a few seconds anyway.
    private func onceQuiet(_ action: @escaping () -> Void) {
        afterSpeaking = action
        schedule("after-speaking", after: 8) { [weak self] in self?.speakingEnded() }
        if !assistantSpeaking { schedule("after-speaking", after: 2.5) { [weak self] in self?.speakingEnded() } }
    }

    private func speakingEnded() {
        cancel("after-speaking")
        guard let action = afterSpeaking else { return }
        afterSpeaking = nil
        action()
    }

    func setMuted(_ muted: Bool) {
        guard isMuted != muted else { return }
        isMuted = muted
        endpoint.setMuted(muted)
        // Muted means quiet too: the reply under way stops, so it can't drown out "unmute".
        // Notices that come later while muted are still spoken.
        silencingReply = muted
        if muted {
            endpoint.stopPlayback()
            schedule("reply-silenced", after: Self.replyGap) { [weak self] in self?.silencingReply = false }
        } else {
            cancel("reply-silenced")
        }
        if muted { socket?.send(["type": "session.input_audio.mute"]) } else { socket?.send(["type": "session.input_audio.unmute"]) }
        updateWakeListening()
    }

    /// The user said "mute" or "unmute", to GPT-Live or to the Mac. Unmuted by voice, the
    /// voice says it's listening, since nothing else tells the user it worked.
    private func spoken(_ command: VoiceCommand, heard: String) {
        switch command {
        case .mute:
            guard phase == .live, !isMuted else { return }
            record(.notice, "Heard \"\(heard)\"; muted.")
            setMuted(true)
        case .unmute:
            guard phase == .live, isMuted else { return }
            record(.notice, "Heard \"\(heard)\"; unmuted.")
            setMuted(false)
            append(instruction: "The user just unmuted the microphone by voice. Say only that you're listening, in a few words. Then listen.")
        }
    }

    private func woken(by phrase: String) {
        // The voice's own speech, echoing back, isn't the user. Voice processing removes
        // most of it, so the user is heard over the voice unless it said the phrase itself.
        guard !Self.isEcho(phrase, assistantSaid: lastAssistantText + " " + ledger.pendingAssistant) else { return }
        switch phase {
        case .paused:
            record(.notice, "Heard \"\(phrase)\".")
            resume()
        case .live where isMuted:
            spoken(.unmute, heard: phrase)
        default:
            break
        }
    }

    /// Whether `phrase`, heard while muted, is the voice's own words echoing back.
    nonisolated static func isEcho(_ phrase: String, assistantSaid: String) -> Bool {
        VoiceWakeListener.matches(assistantSaid) == phrase
    }

    /// Where the Mac listens for a wake phrase, if it does: only while the voice can't
    /// hear. Muted, it listens to the voice's own microphone, which keeps running (a second
    /// engine on that microphone hears silence under voice processing). Paused, it opens
    /// the Mac's microphone itself; a paused handset has no microphone here.
    nonisolated static func wakeSource(phase: Phase, muted: Bool, local: Bool) -> VoiceWakeListener.Source? {
        switch phase {
        case .live where muted: return .fed
        case .paused where local: return .microphone
        default: return nil
        }
    }

    private var wakeSource: VoiceWakeListener.Source? {
        Self.wakeSource(phase: phase, muted: isMuted, local: endpoint === localEndpoint)
    }

    private func updateWakeListening() {
        guard let source = wakeSource else {
            wake.stop()
            return
        }
        Task {
            let access = await VoicePermission.speechRecognition.request()
            speechAccess = access
            guard access == .allowed else {
                if let problem = VoicePermission.wakeProblem(for: access) { wakeFailed(problem) }
                return
            }
            guard wakeSource == source else { return }
            wake.start(from: source)
            if wake.isRunning {
                wakeProblem = nil
            } else if source == .microphone {
                wakeFailed("The Mac's microphone couldn't be opened to listen for \"hey Maggie\"; click to continue instead.")
            }
        }
    }

    // MARK: Turning on and off

    func toggle() {
        switch phase {
        case .off, .failed: start()
        case .paused: resume()
        case .connecting, .live: stop()
        }
    }

    func start() {
        guard phase == .off || phase.isFailed else { return }
        guard let apiKey = OpenAI.apiKey() else {
            phase = .failed("No OpenAI API key. Add one in Settings › Voice.")
            return
        }
        phase = .connecting
        billedSeconds = 0
        reconnects = 0
        applyAudioSettings()
        directory.start()
        listenToSessionEvents()
        Task {
            let microphone = await VoicePermission.microphone.request()
            microphoneAccess = microphone
            guard microphone == .allowed else {
                phase = .failed("Maggie needs the microphone. Allow it in System Settings › Privacy & Security › Microphone, or ask again in Settings › Voice.")
                teardown()
                return
            }
            guard phase == .connecting else { return }
            // Speech recognition is asked for now, while the user is here to answer, not
            // the first time the voice is muted or paused, which may be while they are
            // away. Declined, the voice still works; the wake phrases don't, and the
            // popover and Settings › Voice say so and show the way back.
            speechAccess = await VoicePermission.speechRecognition.request()
            if let problem = VoicePermission.wakeProblem(for: speechAccess) { wakeFailed(problem) }
            guard phase == .connecting else { return }
            connect(apiKey: apiKey, greeting: .fresh)
        }
    }

    /// Ends the voice: closes the GPT-Live session gracefully and stops listening.
    func stop() {
        guard phase != .off else { return }
        closeSession(then: .off)
    }

    /// The app is quitting this instant: no goodbye, no socket close to wait on. The Mac's
    /// audio is let go of now, so the microphone's gain is put back and nothing of Apple's
    /// voice processing is left to the process's death.
    func quit() {
        endpoint.stopCapture()
        localEndpoint.stopCapture()
        wake.stop()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    /// Wakes a paused voice.
    func resume() {
        guard phase == .paused, let apiKey = OpenAI.apiKey() else { return }
        phase = .connecting
        connect(apiKey: apiKey, greeting: .resumed)
    }

    private func applyAudioSettings() {
        localEndpoint.echoCancellation = settings.echoCancellation
        localEndpoint.inputDeviceUID = settings.inputDeviceUID
        localEndpoint.outputDeviceUID = settings.outputDeviceUID
    }

    /// The audio settings changed: the Mac's engine is started again on the new devices,
    /// in the same GPT-Live session.
    func audioSettingsChanged() {
        applyAudioSettings()
        guard phase == .live, endpoint === localEndpoint else { return }
        localEndpoint.stopCapture()
        startCapture()
    }

    /// Swaps the handset: a paired device's microphone and speaker, or the Mac's own.
    func use(_ endpoint: VoiceAudioEndpoint?) {
        let next = endpoint ?? localEndpoint
        guard next !== self.endpoint else { return }
        let wasCapturing = phase == .live
        if wasCapturing { self.endpoint.stopCapture() }
        self.endpoint.stopPlayback()
        self.endpoint = next
        next.onMutedAudio = { [wake] buffer in wake.append(buffer) }
        endpointName = next.endpointName
        if wasCapturing { startCapture() }
        updateWakeListening()
    }

    // MARK: The GPT-Live session

    private enum Greeting {
        case fresh
        case resumed
        case none
    }

    private func connect(apiKey: String, greeting: Greeting) {
        let socket = OpenAILiveSocket(apiKey: apiKey)
        self.socket = socket
        ledger = VoiceLedger()
        sessionSeconds = 0
        started = false
        closing = false
        expiresAt = nil
        pendingCalls = [:]
        backendBusy = false
        socket.onEvent = { [weak self, weak socket] event, json in
            guard let self, let socket, socket === self.socket else { return }
            self.handle(event, json: json, greeting: greeting)
        }
        socket.onClose = { [weak self, weak socket] error in
            guard let self, let socket, socket === self.socket else { return }
            self.socketClosed(error)
        }
        socket.connect()
        socket.send(["type": "session.start", "session": sessionConfiguration()])
    }

    private func sessionConfiguration() -> [String: Any] {
        let history = log.recent(limit: Self.seedTurns).map { turn -> [String: Any] in
            let role = turn.role == .user ? "user" : "assistant"
            let type = turn.role == .user ? "input_text" : "output_text"
            return ["type": "message", "role": role, "content": [["type": type, "text": turn.text]]]
        }
        return [
            "model": "gpt-live-1",
            "instructions": VoicePrompt.liveInstructions(
                capabilities: VoiceTools.capabilities,
                userName: settings.userName.isEmpty ? nil : settings.userName),
            "input": history,
            "audio": [
                "format": ["type": "audio/pcm", "rate": VoiceAudioFormat.sampleRate],
                "output": ["voice": settings.voice],
            ],
            "delegation": [
                "type": "responses",
                "responses": [
                    "model": settings.backendModel,
                    "instructions": VoicePrompt.backendInstructions(memory: memory.prompt(), sessionsNow: tools.sessionsSummary()),
                    "tools": VoiceTools.definitions.map(\.json),
                    "tool_choice": "auto",
                    "parallel_tool_calls": false,
                ],
            ],
        ]
    }

    private func handle(_ event: OpenAILiveEvent, json: [String: Any], greeting: Greeting) {
        switch event {
        case .started(_, let expiresAt):
            started = true
            self.expiresAt = expiresAt
            reconnects = 0
            phase = .live
            lastUserSpeech = Date()
            startCapture()
            // A fresh session after a rollover or a reconnect is muted too.
            if isMuted { socket?.send(["type": "session.input_audio.mute"]) }
            startMaintenance()
            switch greeting {
            case .fresh:
                append(instruction: VoicePrompt.greeting(sessionCount: directory.snapshot.sessions.count, resumed: false))
            case .resumed:
                append(instruction: VoicePrompt.greeting(sessionCount: 0, resumed: true))
            case .none:
                break
            }
            flushNotices()

        case .inputTranscript(let delta):
            ledger.input(delta)
            userSpeaking = true
            lastUserSpeech = Date()
            schedule("user", after: Self.userPause) { [weak self] in self?.flush(.user) }
            // "Mute" is acted on here, once the words settle, rather than waiting on
            // GPT-Live to delegate it, which it often doesn't.
            schedule("command", after: Self.commandSettle) { [weak self] in self?.heardUser() }

        case .outputTranscript(let delta):
            ledger.output(delta)
            schedule("assistant", after: Self.assistantPause) { [weak self] in self?.flush(.assistant) }
            schedule("flush-audio", after: 0.5) { [weak self] in self?.endpoint.flushPlayback() }

        case .outputAudio(let pcm):
            outputChunks += 1
            if silencingReply {
                silencedChunks += 1
                schedule("reply-silenced", after: Self.replyGap) { [weak self] in self?.silencingReply = false }
                return
            }
            endpoint.play(pcm)
            schedule("flush-audio", after: 0.5) { [weak self] in self?.endpoint.flushPlayback() }

        case .functionCall(let delegationID, let callID, let name, let arguments):
            guard !answeredCalls.contains(callID) else { return }
            pendingCalls[delegationID, default: []].append((callID, name, arguments))

        case .delegationCreated(_, let target):
            if target == "responses" { backendBusy = true }

        case .backendCompleted(let delegationID, _):
            backendBusy = false
            if let calls = pendingCalls.removeValue(forKey: delegationID), !calls.isEmpty {
                Task { await run(calls, delegationID: delegationID) }
            } else {
                flushNotices()
            }

        case .backendMessage(_, let text):
            if !text.isEmpty { Self.logger.debug("backend: \(text, privacy: .public)") }

        case .usage(let seconds, let ratio):
            ledger.usage(seconds: seconds)
            sessionSeconds = ledger.billedSeconds
            contextRatio = ratio ?? contextRatio
            publishUsage()

        case .closed(let reason, let seconds):
            if let seconds { ledger.usage(seconds: seconds) }
            sessionSeconds = ledger.billedSeconds
            publishUsage()
            sessionEnded(reason: reason)

        case .error(let code, let message, _):
            Self.logger.warning("GPT-Live error \(code ?? "-", privacy: .public): \(message, privacy: .public)")
            if !started {
                phase = .failed(message)
                socket?.close()
                socket = nil
                teardown()
            } else if code == "function_call_outputs_required" || code == "tool_outputs_required" {
                // A notice went out while the backend waited on a tool; it is sent again after.
                return
            } else {
                record(.notice, "GPT-Live: \(message)")
            }

        case .updated, .appended, .inputMuted, .other:
            break
        }
    }

    private func socketClosed(_ error: Error?) {
        socket = nil
        if closing {
            // `session.closed` already ended the session, or the close timed out.
            return
        }
        Self.logger.warning("socket dropped: \(String(describing: error), privacy: .public)")
        sessionEnded(reason: "connection_lost")
    }

    /// The GPT-Live session is over, by request or not. Decides what comes next.
    private func sessionEnded(reason: String) {
        cancel("close")
        billedSeconds += sessionSeconds
        sessionSeconds = 0
        let wasClosing = closing
        closing = false
        socket?.close()
        socket = nil
        endpoint.stopCapture()
        endpoint.stopPlayback()
        flush(.user)
        flush(.assistant)

        if wasClosing {
            if let next = afterClose {
                afterClose = nil
                switch next {
                case .off:
                    teardown()
                    phase = .off
                case .paused:
                    phase = .paused
                case .reconnect:
                    if let apiKey = OpenAI.apiKey() {
                        phase = .connecting
                        connect(apiKey: apiKey, greeting: .none)
                    }
                }
            }
            return
        }

        switch reason {
        case "expired", "connection_lost", "remote_hangup":
            guard reconnects < 3, let apiKey = OpenAI.apiKey() else {
                phase = .failed("The voice session ended (\(reason)) and couldn't be started again.")
                teardown()
                return
            }
            reconnects += 1
            phase = .connecting
            let delay = Double(reconnects) * 1.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated {
                    guard self.phase == .connecting else { return }
                    self.connect(apiKey: apiKey, greeting: .none)
                }
            }
        case "content":
            phase = .failed("GPT-Live ended the session for content reasons.")
            teardown()
        default:
            phase = .off
            teardown()
        }
    }

    private enum AfterClose {
        case off
        case paused
        case reconnect
    }

    private var afterClose: AfterClose?

    /// Closes gracefully: `session.close`, then `session.closed` with the final seconds.
    private func closeSession(then next: AfterClose) {
        afterClose = next
        guard let socket, started, !closing else {
            socket?.close()
            self.socket = nil
            closing = true
            sessionEnded(reason: "close_requested")
            return
        }
        closing = true
        socket.send(["type": "session.close"])
        schedule("close", after: Self.closeTimeout) { [weak self] in
            self?.sessionEnded(reason: "close_requested")
        }
    }

    private func teardown() {
        maintenance?.invalidate()
        maintenance = nil
        for timer in timers.values { timer.invalidate() }
        timers = [:]
        directory.stop()
        pendingCalls = [:]
        queuedNotices = []
        workingOn = nil
        userSpeaking = false
        afterSpeaking = nil
        hookEvents = nil
        wake.stop()
    }

    private func startCapture() {
        // Capture is started once per GPT-Live session, so its socket is the one to feed.
        guard let socket else { return }
        do {
            try endpoint.startCapture(muted: isMuted) { [weak socket] chunk in
                // Off the main thread, straight to the socket.
                socket?.sendAudio(chunk)
            }
        } catch {
            let code = (error as NSError).code
            record(.notice, "The microphone couldn't start (audio error \(code)). Try another microphone or speaker in Settings › Voice, or turn echo cancellation off.")
        }
    }

    // MARK: Keeping it going

    private func startMaintenance() {
        maintenance?.invalidate()
        maintenance = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.maintain() }
        }
    }

    private func maintain() {
        guard phase == .live, !closing else { return }
        if endpoint === localEndpoint {
            let stats = localEndpoint.stats
            Self.logger.info("audio: \(stats.captured) chunks captured, \(stats.played) bytes played, \(self.outputChunks) received, \(self.silencedChunks) silenced by a mute")
        }
        let idle = runningTools == 0 && pendingCalls.isEmpty && !assistantSpeaking && !userSpeaking
        if let expiresAt, Date() > expiresAt.addingTimeInterval(-Self.rolloverMargin), idle {
            record(.notice, "Rolling to a fresh GPT-Live session before this one expires.")
            closeSession(then: .reconnect)
            return
        }
        let limit = settings.idleMinutes
        if limit > 0, idle, Date().timeIntervalSince(lastUserSpeech) > Double(limit) * 60 {
            record(.notice, "Paused after \(limit) minutes of quiet. Speak up or click to continue.")
            closeSession(then: .paused)
        }
    }

    private func schedule(_ key: String, after seconds: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        timers[key]?.invalidate()
        timers[key] = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    private func cancel(_ key: String) {
        timers[key]?.invalidate()
        timers[key] = nil
    }

    // MARK: Transcript

    /// What the user has said so far this turn, checked for a command.
    private func heardUser() {
        cancel("command")
        let text = ledger.pendingUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let command = VoiceCommand.parse(text) else { return }
        flush(.user)
        spoken(command, heard: text)
    }

    private func flush(_ role: VoiceTurn.Role) {
        switch role {
        case .user:
            cancel("user")
            cancel("command")
            userSpeaking = false
            let text = ledger.flushUser()
            if !text.isEmpty { record(.user, text) }
        case .assistant:
            cancel("assistant")
            let text = ledger.flushAssistant()
            if !text.isEmpty {
                lastAssistantText = text
                record(.assistant, text)
            }
        default:
            break
        }
    }

    private func record(_ role: VoiceTurn.Role, _ text: String) {
        let turn = VoiceTurn(role: role, text: text)
        turns.append(turn)
        if turns.count > 400 { turns.removeFirst(turns.count - 400) }
        log.append(turn)
    }

    private func publishUsage() {
        objectWillChange.send()
    }

    /// Seconds billed so far, this session included.
    var liveSeconds: Double { billedSeconds + sessionSeconds }

    // MARK: Tools

    private func run(_ calls: [(callID: String, name: String, arguments: String)], delegationID: String) async {
        guard let socket else { return }
        runningTools += 1
        let startedAt = Date()
        holdCount = 0
        schedule("hold", after: Self.holdThreshold) { [weak self] in
            self?.hold(delegationID: delegationID)
        }
        for call in calls {
            answeredCalls.insert(call.callID)
            workingOn = call.name
            let arguments = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]) ?? [:]
            let result = await tools.run(call.name, arguments: arguments)
            record(.tool, Self.describe(call.name, arguments: arguments, result: result))
            let output = (try? JSONSerialization.data(withJSONObject: result)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            socket.send([
                "type": "response.item.create",
                "item": ["type": "function_call_output", "call_id": call.callID, "output": output],
            ])
        }
        cancel("hold")
        workingOn = nil
        runningTools -= 1
        Self.logger.info("tools \(calls.map(\.name).joined(separator: ","), privacy: .public) took \(Date().timeIntervalSince(startedAt))s")
        guard socket === self.socket, !closing else { return }
        // What the backend remembers changed; it is told now, not at the next session.
        if calls.contains(where: { $0.name == "remember" }) {
            socket.send([
                "type": "session.update",
                "session": ["delegation": ["type": "responses", "responses": [
                    "instructions": VoicePrompt.backendInstructions(memory: memory.prompt(), sessionsNow: tools.sessionsSummary()),
                ]]],
            ])
        }
        backendBusy = true
        socket.send(["type": "response.create"])
    }

    private var holdCount = 0

    /// Says the backend is still busy, the way the harness's hold filler does on a call.
    private func hold(delegationID: String) {
        guard let socket, runningTools > 0 else { return }
        holdCount += 1
        let line = holdCount == 1 ? "Still on it; this is taking a moment." : "Still working on it."
        socket.send([
            "type": "session.commentary.append",
            "delegation_id": delegationID,
            "content": line,
        ])
        schedule("hold", after: Self.holdInterval) { [weak self] in
            self?.hold(delegationID: delegationID)
        }
    }

    private static func describe(_ name: String, arguments: [String: Any], result: [String: Any]) -> String {
        var parts = [name]
        if let session = arguments["session"] as? String { parts.append("session \(session)") }
        if let folder = arguments["folder"] as? String { parts.append("in \(folder)") }
        if let error = result["error"] as? String { parts.append("failed: \(error)") }
        if let number = result["number"] as? Int { parts.append("→ #\(number)") }
        return parts.joined(separator: " ")
    }

    // MARK: Watching sessions

    func watch(_ sessionID: String) {
        watched.insert(sessionID)
    }

    func watchAll(_ all: Bool) {
        settings.announcesAllSessions = all
        if !all { watched = [] }
    }

    /// A session's light changed: the sidebar's view of it, a second or so behind.
    private func sessionsChanged(from old: SidebarSnapshot, to new: SidebarSnapshot) {
        guard phase.isOn else { return }
        let notices = watchRules.notices(from: old, to: new, watched: watched, all: settings.announcesAllSessions, at: Date())
        for notice in notices {
            guard let candidate = directory.candidates.first(where: { $0.session.id == notice.sessionID }) else { continue }
            notify(VoiceWatchRules.line(
                number: candidate.number, title: candidate.session.title, kind: notice.kind,
                status: candidate.session.lightLabel, lastWords: lastWords(of: candidate)))
        }
    }

    /// Listens to the hook events Claude Code sends the app (`ClaudeSubagents`), from
    /// now on: a session that needs the user, finishes a turn, fails or ends is told the
    /// moment it happens, with what the event carries.
    private func listenToSessionEvents() {
        hookSince = Date()
        ClaudeSubagents.shared.start()
        hookEvents = ClaudeSubagents.shared.events.sink { [weak self] delivery in
            MainActor.assumeIsolated { self?.sessionEvent(delivery.event, writtenAt: delivery.writtenAt) }
        }
    }

    private func sessionEvent(_ event: ClaudeAgentEvent, writtenAt: Date) {
        guard phase.isOn, writtenAt >= hookSince.addingTimeInterval(-Self.hookGrace),
              let meaning = VoiceHookNotice.meaning(of: event),
              let candidate = directory.candidate(forClaudeSession: event.sessionID),
              VoiceWatchRules.announces(candidate.session.id, watched: watched, all: settings.announcesAllSessions),
              watchRules.notice(of: meaning.kind, session: candidate.session.id, at: Date()) != nil else { return }
        let lastWords = meaning.lastWords.map { VoiceTools.trimmed(VoiceSpeech.speakable($0), to: 600) }
            ?? (meaning.kind == .finished ? self.lastWords(of: candidate) : nil)
        notify(VoiceWatchRules.line(
            number: candidate.number, title: candidate.session.title, kind: meaning.kind,
            status: candidate.session.lightLabel, detail: meaning.detail, lastWords: lastWords))
    }

    /// The agent's last response in `candidate`'s session, made sayable.
    private func lastWords(of candidate: VoiceSessionReference.Candidate) -> String? {
        guard let window = directory.window(for: candidate),
              let pid = window.terminalController?.focusedSurface?.surfaceModel?.foregroundPID,
              let session = AgentSession.running(pid: pid),
              let last = ClaudeCodeResponse.last(inSession: session) else { return nil }
        return VoiceTools.trimmed(VoiceSpeech.speakable(last), to: 600)
    }

    /// Tells the backend something from Maggie, waking the voice if it is paused.
    func notify(_ text: String) {
        record(.notice, text)
        queuedNotices.append(VoicePrompt.notice(text))
        switch phase {
        case .live: flushNotices()
        case .paused: resume()
        default: break
        }
    }

    private func flushNotices() {
        guard let socket, phase == .live, !closing, !backendBusy, runningTools == 0, pendingCalls.isEmpty,
              !queuedNotices.isEmpty else { return }
        let text = queuedNotices.joined(separator: "\n")
        queuedNotices = []
        socket.send([
            "type": "response.item.create",
            "item": ["type": "message", "role": "user", "content": [["type": "input_text", "text": text]]],
        ])
        backendBusy = true
        socket.send(["type": "response.create"])
    }

    private func append(instruction: String) {
        socket?.send(["type": "session.instructions.append", "delegation_id": NSNull(), "content": instruction])
    }
}

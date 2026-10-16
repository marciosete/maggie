import AVFoundation
import Combine
import Foundation
import OSLog

/// A short sample of each GPT-Live voice, so one can be chosen by ear. OpenAI's speech
/// endpoint knows only two of GPT-Live's voices, so a sample comes from a brief GPT-Live
/// session in that voice, told to say one line; it is kept on disk and plays from there
/// after. One sample plays at a time, on the speaker chosen in Settings.
@MainActor
final class VoicePreview: ObservableObject {
    static let shared = VoicePreview()

    enum Phase: Equatable {
        case idle
        case fetching(String)
        case playing(String)
        case failed(voice: String, message: String)

        var voice: String? {
            switch self {
            case .idle: return nil
            case .fetching(let voice), .playing(let voice): return voice
            case .failed(let voice, _): return voice
            }
        }
    }

    @Published private(set) var phase: Phase = .idle

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier!, category: "VoicePreview")

    private let directory: URL
    private let player = VoicePreviewPlayer()
    private var fetch: VoicePreviewFetch?

    init(directory: URL? = nil) {
        self.directory = directory ?? VoiceMemoryStore.defaultDirectory.appendingPathComponent("previews", isDirectory: true)
    }

    /// What a voice says of itself.
    nonisolated static func sample(for voice: String) -> String {
        "Hi, I'm \(voice.capitalized), this is how I sound."
    }

    /// What the sample's session is told: say the line, and nothing else.
    nonisolated static func instructions(for voice: String) -> String {
        "You are a voice sample. Say exactly the line you are given, word for word, warmly and at a natural pace, and nothing else. Do not greet, do not add anything, do not wait for the user."
    }

    /// Where a voice's sample is kept.
    func file(for voice: String) -> URL {
        directory.appendingPathComponent("\(voice).pcm")
    }

    /// Plays `voice`'s sample, fetching it the first time. Playing the same voice again
    /// stops it; another voice takes over.
    func play(_ voice: String) {
        switch phase {
        case .fetching(let current) where current == voice, .playing(let current) where current == voice:
            stop()
            return
        default:
            stop()
        }
        let file = file(for: voice)
        if let pcm = try? Data(contentsOf: file), !pcm.isEmpty {
            start(pcm, voice: voice)
            return
        }
        guard let apiKey = OpenAI.apiKey() else {
            phase = .failed(voice: voice, message: "Save an OpenAI API key to hear the voices.")
            return
        }
        phase = .fetching(voice)
        let fetch = VoicePreviewFetch(apiKey: apiKey, voice: voice, line: Self.sample(for: voice), instructions: Self.instructions(for: voice))
        self.fetch = fetch
        fetch.start { [weak self] result in
            guard let self, self.fetch === fetch else { return }
            self.fetch = nil
            switch result {
            case .success(let pcm):
                self.keep(pcm, at: file)
                self.start(pcm, voice: voice)
            case .failure(let error):
                Self.logger.warning("sample for \(voice, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                self.phase = .failed(voice: voice, message: error.localizedDescription)
            }
        }
    }

    func stop() {
        fetch?.cancel()
        fetch = nil
        player.stop()
        phase = .idle
    }

    /// Drops the kept samples, so the next play fetches them afresh.
    func forgetSamples() {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }

    private func start(_ pcm: Data, voice: String) {
        do {
            try player.play(pcm, outputDevice: VoiceDevices.device(uid: VoiceSettings.shared.outputDeviceUID)) { [weak self] in
                guard let self, self.phase == .playing(voice) else { return }
                self.phase = .idle
            }
            phase = .playing(voice)
        } catch {
            phase = .failed(voice: voice, message: "The speaker couldn't play: \(error.localizedDescription)")
        }
    }

    private func keep(_ pcm: Data, at file: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pcm.write(to: file, options: .atomic)
        } catch {
            Self.logger.warning("couldn't keep the sample: \(String(describing: error), privacy: .public)")
        }
    }
}

// MARK: - Fetching a sample

/// One GPT-Live session, in one voice, that says one line and ends. Output audio only
/// flows while input audio does, so silence is streamed meanwhile; the line is over
/// when the audio has stopped coming for a moment.
@MainActor
final class VoicePreviewFetch {
    enum Failure: LocalizedError {
        case live(String)
        case connection(String)
        case noSpeech
        case cancelled

        var errorDescription: String? {
            switch self {
            case .live(let message): return message
            case .connection(let message): return "Couldn't reach GPT-Live: \(message)"
            case .noSpeech: return "GPT-Live said nothing."
            case .cancelled: return "Stopped."
            }
        }
    }

    /// Audio that has stopped coming for this long is the whole line.
    static let quietAfter: TimeInterval = 1.5

    /// Give up on a session that hasn't spoken by then.
    static let timeout: TimeInterval = 25

    private let socket: OpenAILiveSocket
    private let voice: String
    private let line: String
    private let instructions: String
    private var collector = VoicePreviewCollector()
    private var silence: Timer?
    private var quiet: Timer?
    private var deadline: Timer?
    private var completion: ((Result<Data, Error>) -> Void)?

    init(apiKey: String, voice: String, line: String, instructions: String) {
        socket = OpenAILiveSocket(apiKey: apiKey)
        self.voice = voice
        self.line = line
        self.instructions = instructions
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        socket.onEvent = { [weak self] event, _ in self?.handle(event) }
        socket.onClose = { [weak self] error in
            guard let self, self.completion != nil else { return }
            if let error {
                self.finish(.failure(Failure.connection(error.localizedDescription)))
            } else if !self.collector.audio.isEmpty {
                self.finish(.success(self.collector.sample))
            } else {
                self.finish(.failure(Failure.noSpeech))
            }
        }
        socket.connect()
        socket.send([
            "type": "session.start",
            "session": [
                "model": "gpt-live-1",
                "instructions": instructions,
                "audio": [
                    "format": ["type": "audio/pcm", "rate": VoiceAudioFormat.sampleRate],
                    "output": ["voice": voice],
                ],
            ],
        ])
        deadline = Timer.scheduledTimer(withTimeInterval: Self.timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finish(self.collector.audio.isEmpty ? .failure(Failure.noSpeech) : .success(self.collector.sample))
            }
        }
    }

    func cancel() {
        finish(.failure(Failure.cancelled))
    }

    private func handle(_ event: OpenAILiveEvent) {
        switch collector.take(event) {
        case .ask:
            // Input audio keeps the session's clock going; an appended instruction makes
            // GPT-Live speak without being spoken to, as the voice's greeting does.
            let frame = Data(count: VoiceAudioFormat.chunkBytes)
            socket.sendAudio(frame)
            silence = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.socket.sendAudio(frame) }
            }
            socket.send(["type": "session.instructions.append", "delegation_id": NSNull(), "content": "Say this line now, word for word, then stop: \"\(line)\""])
        case .heard:
            // Should the stream stop short, what was heard is the sample.
            quiet?.invalidate()
            quiet = Timer.scheduledTimer(withTimeInterval: Self.quietAfter, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.finish(.success(self.collector.sample))
                }
            }
        case .done(let sample):
            finish(.success(sample))
        case .failed(let message):
            finish(.failure(Failure.live(message)))
        case .nothing:
            break
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let completion else { return }
        self.completion = nil
        silence?.invalidate()
        quiet?.invalidate()
        deadline?.invalidate()
        socket.send(["type": "session.close"])
        socket.close()
        completion(result)
    }
}

/// What a sample's session has said so far, and what each event means for it. GPT-Live
/// streams output audio for as long as input audio goes in, silence included, so the
/// line is over not when the audio stops but when it goes quiet after having spoken.
struct VoicePreviewCollector: Equatable {
    enum Step: Equatable {
        /// The session is up: stream silence and give it the line.
        case ask

        /// More audio arrived.
        case heard

        /// The line was spoken and has gone quiet: this is the sample, trimmed.
        case done(Data)
        case failed(String)
        case nothing
    }

    /// A chunk with a sample this far from zero has speech in it (about -38 dBFS).
    static let loud: Int16 = 400

    /// Quiet this long after speech is the end of the line.
    static let tailSeconds = 0.8

    /// How much quiet to keep around the speech.
    static let marginSeconds = 0.2

    private(set) var audio = Data()
    private(set) var started = false
    private var speechStart: Int?
    private var speechEnd: Int?

    /// The speech heard so far, with a little quiet either side; everything, if none was.
    var sample: Data {
        guard let speechStart, let speechEnd else { return audio }
        let margin = Self.bytes(Self.marginSeconds)
        return audio.subdata(in: max(0, speechStart - margin)..<min(audio.count, speechEnd + margin))
    }

    mutating func take(_ event: OpenAILiveEvent) -> Step {
        switch event {
        case .started:
            guard !started else { return .nothing }
            started = true
            return .ask
        case .outputAudio(let pcm):
            let offset = audio.count
            audio.append(pcm)
            if Self.isLoud(pcm) {
                if speechStart == nil { speechStart = offset }
                speechEnd = audio.count
            } else if let speechEnd, audio.count - speechEnd >= Self.bytes(Self.tailSeconds) {
                return .done(sample)
            }
            return .heard
        case .error(_, let message, _):
            return .failed(message)
        case .closed(let reason, _):
            return audio.isEmpty && reason != "client_closed" ? .failed("GPT-Live closed the session: \(reason)") : .nothing
        default:
            return .nothing
        }
    }

    /// Whether any sample in `pcm` is far enough from zero to be speech.
    static func isLoud(_ pcm: Data) -> Bool {
        pcm.withUnsafeBytes { raw in
            for i in stride(from: 0, to: pcm.count - 1, by: 2) {
                let sample = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i, as: Int16.self))
                if sample > loud || sample < -loud { return true }
            }
            return false
        }
    }

    static func bytes(_ seconds: Double) -> Int {
        Int(seconds * Double(VoiceAudioFormat.sampleRate)) * 2
    }
}

// MARK: - Playing a sample

/// Plays one sample through its own small engine, on the chosen speaker or the default.
final class VoicePreviewPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceAudioFormat.sampleRate), channels: 1, interleaved: false)!
    private var generation = 0

    init() {
        engine.attach(player)
    }

    /// Plays `pcm` and calls `finished` on the main thread when it has played, unless
    /// stopped first.
    func play(_ pcm: Data, outputDevice: AudioDeviceID?, finished: @escaping @MainActor () -> Void) throws {
        stop()
        guard let buffer = VoiceAudioFormat.buffer(from: pcm, format: format) else { return }
        if let outputDevice, let unit = engine.outputNode.audioUnit {
            var id = outputDevice
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        generation += 1
        let generation = generation
        player.play()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.stop()
                MainActor.assumeIsolated { finished() }
            }
        }
    }

    func stop() {
        generation += 1
        player.stop()
        engine.stop()
    }
}

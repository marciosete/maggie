import AVFoundation
import Foundation
import OSLog
import Speech

/// Listens, on the Mac alone, for the few words that bring the voice back while it is
/// muted or paused: "unmute", "hey Maggie". Apple's on-device recognition hears them, so
/// nothing leaves the Mac and nothing is billed while the user is quiet.
///
/// Muted, the voice's own engine is still running the microphone, with Apple's voice
/// processing on it; a second engine on the same microphone hears silence, so the
/// listener is fed the voice's microphone instead (`Source.fed`). Paused, nothing else is
/// listening, and the listener runs the microphone itself (`Source.microphone`).
final class VoiceWakeListener: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: VoiceWakeListener.self)
    )

    enum Source: Equatable {
        /// Buffers come in through `append(_:)`.
        case fed

        /// The listener opens the microphone on an engine of its own.
        case microphone
    }

    /// What wakes the voice, as recognised; matched ignoring case and punctuation.
    static let phrases = ["unmute", "un mute", "hey maggie", "hi maggie", "okay maggie", "ok maggie", "maggie wake up", "wake up"]

    /// A recognition request is started afresh this often, so a long quiet spell doesn't
    /// run one request forever.
    private static let restartInterval: TimeInterval = 50

    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var generation = 0

    /// Under `lock`: the request buffers go to, from whichever thread they arrive on.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// Main thread only.
    private(set) var source: Source?
    var isRunning: Bool { source != nil }

    /// Called on the main thread with the phrase heard.
    var onWake: (@MainActor (String) -> Void)?

    /// Whether speech recognition may be used, asking if it hasn't been decided.
    static func requestAccess() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    /// Whether `text` holds a wake phrase.
    static func matches(_ text: String) -> String? {
        let flat = text.lowercased()
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        return phrases.first { flat.contains($0) }
    }

    /// Starts listening from `source`; a listener already running from another source
    /// switches. Main thread only.
    func start(from source: Source) {
        guard self.source != source else { return }
        if isRunning { stop() }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            Self.logger.warning("speech recognition unavailable")
            return
        }
        self.recognizer = recognizer
        if source == .microphone {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                Self.logger.warning("wake engine has no microphone input")
                return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                self?.feed(buffer)
            }
            engine.prepare()
            do {
                try engine.start()
            } catch {
                Self.logger.warning("wake engine couldn't start: \(String(describing: error), privacy: .public)")
                input.removeTap(onBus: 0)
                return
            }
            self.engine = engine
        }
        self.source = source
        beginRequest()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: true) { [weak self] _ in
            self?.beginRequest()
        }
        Self.logger.info("listening for a wake phrase (\(source == .fed ? "fed" : "microphone", privacy: .public))")
    }

    /// Microphone audio from the voice's engine, on any thread. Ignored unless the
    /// listener is running.
    func append(_ buffer: AVAudioPCMBuffer) {
        feed(buffer)
    }

    /// Forgets what has been heard so far, so speech before now can't match: the voice's
    /// own words, say, when it tells the user to say "unmute". Main thread only.
    func reset() {
        guard isRunning else { return }
        beginRequest()
    }

    /// Main thread only.
    func stop() {
        guard isRunning else { return }
        source = nil
        generation += 1
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    /// A fresh recognition request. Main thread only.
    private func beginRequest() {
        guard isRunning, let recognizer else { return }
        generation += 1
        let current = generation
        task?.cancel()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .search
        lock.lock()
        self.request?.endAudio()
        self.request = request
        lock.unlock()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Off the main thread; state is only touched back on it.
            let text = result?.bestTranscription.formattedString ?? ""
            let phrase = Self.matches(text)
            let ended = result?.isFinal == true || error != nil
            let code = (error as NSError?)?.code
            DispatchQueue.main.async {
                guard let self, self.generation == current, self.isRunning else { return }
                if let phrase {
                    Self.logger.info("heard \(phrase, privacy: .public)")
                    MainActor.assumeIsolated { self.onWake?(phrase) }
                }
                guard ended, self.generation == current, self.isRunning else { return }
                // A request ends after a final result, a long pause, or an error. Without
                // a new one nothing more would be heard until the restart timer fired.
                // 216 and 1110 are the task being cancelled or ended by us.
                if let code, code != 216, code != 1110 {
                    Self.logger.info("recognition ended (\(code)); starting again")
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + (code == nil ? 0 : 0.5)) {
                    guard self.generation == current, self.isRunning else { return }
                    self.beginRequest()
                }
            }
        }
    }
}

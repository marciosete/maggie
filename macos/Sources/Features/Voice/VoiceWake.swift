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
///
/// On macOS 26 and later the words are heard with SpeechAnalyzer. The older
/// `SFSpeechRecognizer` refuses every request (error 201) while Siri and Dictation are
/// off, which is how many Macs are set up; it is used only on older systems.
final class VoiceWakeListener: @unchecked Sendable {
    static let logger = Logger(
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

    private var engine: AVAudioEngine?
    private var recognizer: VoiceWakeRecognizer?

    /// Main thread only.
    private(set) var source: Source?
    var isRunning: Bool { source != nil }

    /// Called on the main thread with the phrase heard.
    var onWake: (@MainActor (String) -> Void)?

    /// Called on the main thread when listening can't work, with what the user can do.
    var onFailure: (@MainActor (String) -> Void)?

    /// Whether speech recognition may be used, asking if it hasn't been decided. Both
    /// recognisers need it; without it SpeechAnalyzer hears nothing and says nothing.
    /// See `VoicePermission` for what the answer depends on and how it is recovered.
    static func requestAccess() async -> Bool {
        await VoicePermission.speechRecognition.request() == .allowed
    }

    /// Whether `text` holds a wake phrase.
    static func matches(_ text: String) -> String? {
        let flat = text.lowercased()
            .replacingOccurrences(of: #"[^a-z ]"#, with: " ", options: .regularExpression)
            .split(whereSeparator: { $0 == " " })
            .joined(separator: " ")
        return phrases.first { flat.contains($0) }
    }

    /// The recogniser this Mac can use.
    static func makeRecognizer() -> VoiceWakeRecognizer {
        if #available(macOS 26.0, *) { return AnalyzerWakeRecognizer() }
        return LegacyWakeRecognizer()
    }

    /// Starts listening from `source`; a listener already running from another source
    /// switches. Main thread only.
    func start(from source: Source) {
        guard self.source != source else { return }
        if isRunning { stop() }
        let recognizer = Self.makeRecognizer()
        recognizer.onText = { [weak self] text in
            guard let phrase = Self.matches(text) else { return }
            DispatchQueue.main.async {
                guard let self, self.recognizer === recognizer else { return }
                Self.logger.info("heard \(phrase, privacy: .public)")
                MainActor.assumeIsolated { self.onWake?(phrase) }
            }
        }
        recognizer.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.recognizer === recognizer else { return }
                MainActor.assumeIsolated { self.onFailure?(message) }
            }
        }
        if source == .microphone {
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                Self.logger.warning("wake engine has no microphone input")
                return
            }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                recognizer.append(buffer)
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
        self.recognizer = recognizer
        self.source = source
        recognizer.begin()
        Self.logger.info("listening for a wake phrase (\(source == .fed ? "fed" : "microphone", privacy: .public))")
    }

    /// Microphone audio from the voice's engine, on any thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        recognizer?.append(buffer)
    }

    /// Forgets what has been heard so far, so speech before now can't match: the voice's
    /// own words, say, when it tells the user to say "unmute". Main thread only.
    func reset() {
        guard isRunning else { return }
        recognizer?.begin()
    }

    /// Main thread only.
    func stop() {
        guard isRunning else { return }
        source = nil
        recognizer?.end()
        recognizer = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }
}

/// Speech to text for the wake listener, over a stream of microphone buffers.
protocol VoiceWakeRecognizer: AnyObject, Sendable {
    /// Called on any thread with the text of what is being said, growing as it is heard.
    var onText: (@Sendable (String) -> Void)? { get set }

    /// Called on any thread when recognition can't go on, with what the user can do.
    var onFailure: (@Sendable (String) -> Void)? { get set }

    /// Starts recognising afresh, forgetting anything heard. Main thread only.
    func begin()

    /// Microphone audio in any PCM format, on any thread.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Stops for good. Main thread only.
    func end()
}

/// SpeechAnalyzer's transcriber, on device, with no need for Dictation. It needs the
/// speech recognition permission, and takes audio only once its analysis has started:
/// audio queued before that is never transcribed.
@available(macOS 26.0, *)
final class AnalyzerWakeRecognizer: VoiceWakeRecognizer, @unchecked Sendable {
    var onText: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    /// Under `lock`: where buffers go, in the format the transcriber wants.
    private let lock = NSLock()
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?

    private var task: Task<Void, Never>?
    private var failed = false

    /// The transcriber is set up and takes audio; anything appended before is dropped.
    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        return format != nil
    }

    func begin() {
        stopAnalysis()
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        lock.lock()
        input = continuation
        format = nil
        converter = nil
        lock.unlock()
        task = Task { [weak self] in
            await self?.analyze(stream)
        }
    }

    private func analyze(_ stream: AsyncStream<AnalyzerInput>) async {
        let fallback = Locale(identifier: "en-US")
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: fallback) ?? fallback
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                VoiceWakeListener.logger.info("installing speech assets")
                try await request.downloadAndInstall()
            }
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
                throw Failure.noFormat
            }
            try Task.checkCancellation()
            // Results are read alongside the analysis.
            let results = Task { [weak self] in
                for try await result in transcriber.results {
                    self?.onText?(String(result.text.characters))
                }
            }
            defer { results.cancel() }
            try await withTaskCancellationHandler {
                try await analyzer.start(inputSequence: stream)
                // Audio is taken only once the analysis is running.
                lock.withLock { self.format = format }
                try await results.value
            } onCancel: {
                results.cancel()
            }
        } catch is CancellationError {
            // Ended or begun again.
        } catch {
            if !Task.isCancelled, !failed {
                failed = true
                VoiceWakeListener.logger.warning("speech analysis failed: \(String(describing: error), privacy: .public)")
                onFailure?("The Mac couldn't listen for \"unmute\" (\(error.localizedDescription)). Click the microphone instead.")
            }
        }
        await analyzer.cancelAndFinishNow()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let input, let format, let converted = convert(buffer, to: format) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// `buffer` in `format`, under `lock`.
    private func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            // Priming would shift each converted buffer against the analyzer's timeline.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    func end() {
        stopAnalysis()
    }

    private func stopAnalysis() {
        lock.lock()
        input?.finish()
        input = nil
        format = nil
        lock.unlock()
        task?.cancel()
        task = nil
    }

    enum Failure: Error, LocalizedError {
        case noFormat
        var errorDescription: String? { "no audio format for speech" }
    }
}

/// `SFSpeechRecognizer`, for systems before SpeechAnalyzer. A request ends after a final
/// result, a pause or an error, and is started again; while Siri and Dictation are off
/// every request fails, and it says so once instead of trying again forever.
final class LegacyWakeRecognizer: VoiceWakeRecognizer, @unchecked Sendable {
    var onText: (@Sendable (String) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    /// A request is started afresh this often, so a long quiet spell doesn't run one
    /// request forever.
    private static let restartInterval: TimeInterval = 50

    /// The error a request fails with while Siri and Dictation are off.
    static let dictationOffCode = 201

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer()
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var generation = 0
    private var failures = 0
    private var running = false

    /// Under `lock`.
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    /// How long to wait before starting again after `failures` requests in a row ended in
    /// an error.
    static func retryDelay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(0.5 * pow(2, Double(failures - 1)), 30)
    }

    func begin() {
        guard let recognizer, recognizer.isAvailable else {
            onFailure?("Speech recognition isn't available on this Mac, so \"unmute\" by voice won't work; click the microphone instead.")
            return
        }
        running = true
        if restartTimer == nil {
            restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: true) { [weak self] _ in
                self?.beginRequest()
            }
        }
        beginRequest()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let request = self.request
        lock.unlock()
        request?.append(buffer)
    }

    func end() {
        running = false
        generation += 1
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        lock.lock()
        request?.endAudio()
        request = nil
        lock.unlock()
    }

    private func beginRequest() {
        guard running, let recognizer else { return }
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
            if let result { self?.onText?(result.bestTranscription.formattedString) }
            let ended = result?.isFinal == true || error != nil
            let code = (error as NSError?)?.code
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == current else { return }
                if result != nil, error == nil { self.failures = 0 }
                guard ended else { return }
                // 216 and 1110 are the task being cancelled or ended by us.
                if let code, code != 216, code != 1110 {
                    self.failures += 1
                    VoiceWakeListener.logger.info("recognition ended (\(code)); failures \(self.failures)")
                    if code == Self.dictationOffCode {
                        self.end()
                        self.onFailure?("Listening for \"unmute\" needs Dictation: turn it on in System Settings › Keyboard, or click the microphone instead.")
                        return
                    }
                }
                let delay = Self.retryDelay(afterFailures: self.failures)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard self.running, self.generation == current else { return }
                    self.beginRequest()
                }
            }
        }
    }
}

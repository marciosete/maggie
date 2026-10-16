import AVFoundation
import Foundation
import OSLog
import Speech

/// Listens, on the Mac alone, for the few words that bring the voice back while it is
/// muted or paused: "unmute", "hey Maggie". Apple's on-device recognition hears them, so
/// nothing leaves the Mac and nothing is billed while the user is quiet.
final class VoiceWakeListener: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: VoiceWakeListener.self)
    )

    /// What wakes the voice, as recognised; matched ignoring case and punctuation.
    static let phrases = ["unmute", "un mute", "hey maggie", "hi maggie", "okay maggie", "ok maggie", "maggie wake up", "wake up"]

    /// A recognition request is started afresh this often, so a long quiet spell doesn't
    /// run one request forever.
    private static let restartInterval: TimeInterval = 50

    private let engine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var heard = ""
    private var running = false

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

    func start() {
        guard !running else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else {
            Self.logger.warning("speech recognition unavailable")
            return
        }
        self.recognizer = recognizer
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            Self.logger.warning("wake engine couldn't start: \(String(describing: error), privacy: .public)")
            input.removeTap(onBus: 0)
            return
        }
        running = true
        beginRequest()
        DispatchQueue.main.async {
            self.restartTimer = Timer.scheduledTimer(withTimeInterval: Self.restartInterval, repeats: true) { [weak self] _ in
                self?.beginRequest()
            }
        }
        Self.logger.info("listening for a wake phrase")
    }

    func stop() {
        guard running else { return }
        running = false
        DispatchQueue.main.async {
            self.restartTimer?.invalidate()
            self.restartTimer = nil
        }
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func beginRequest() {
        guard running, let recognizer else { return }
        task?.cancel()
        request?.endAudio()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.taskHint = .search
        self.request = request
        heard = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.running else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                if let phrase = Self.matches(text), self.heard != text {
                    self.heard = text
                    Self.logger.info("heard \(phrase, privacy: .public)")
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self.onWake?(phrase) }
                    }
                }
            }
            if let error {
                let code = (error as NSError).code
                // 216 and 1110 are the task being cancelled or ended by us.
                if code != 216, code != 1110 {
                    Self.logger.info("recognition ended: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }
}

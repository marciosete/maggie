import AVFoundation
import Foundation
import OSLog

/// What GPT-Live hears and says: 16-bit little-endian mono PCM at this rate, the same
/// rate ElevenLabs speech plays at.
enum VoiceAudioFormat {
    static let sampleRate = 24_000

    /// Audio goes to GPT-Live in chunks of this many bytes: a tenth of a second.
    static let chunkBytes = sampleRate / 10 * 2

    /// `samples`, floats in -1...1, as little-endian 16-bit PCM.
    static func pcm16(from samples: UnsafeBufferPointer<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            for (i, sample) in samples.enumerated() {
                let clamped = max(-1, min(1, sample))
                let value = Int16(clamped < 0 ? clamped * 0x8000 : clamped * 0x7FFF)
                raw.storeBytes(of: value.littleEndian, toByteOffset: i * 2, as: Int16.self)
            }
        }
        return data
    }

    static func pcm16(from samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { pcm16(from: $0) }
    }

    /// Little-endian 16-bit PCM as a buffer the engine plays.
    static func buffer(from pcm: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = pcm.count / 2
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            for i in 0..<frames {
                samples[i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))) / 32768
            }
        }
        return buffer
    }
}

/// The Mac's microphone and speaker for the voice, on one audio engine, so Apple's voice
/// processing hears what is played and cancels it from what is heard. (Two engines, one
/// each way, leave the echo in and can leave the speaker silent.)
///
/// The microphone comes out as GPT-Live wants it: mono 16-bit PCM at 24 kHz, a tenth of
/// a second at a time, on an audio thread. Speech goes in as the same PCM and plays as it
/// arrives.
///
/// Each call gets an engine of its own, built by `start` and destroyed, whole, by `stop`.
/// Apple's voice processing unit turns the rest of the Mac's sound down and takes over the
/// microphone's gain for as long as the unit exists, not only while audio flows: an engine
/// that is merely stopped keeps the unit, and the Mac stayed at call volume after the
/// voice was hung up, until the app quit (v0.28). Nothing survives a hang-up now.
final class VoiceAudioEngine: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: VoiceAudioEngine.self)
    )

    /// One call's audio: the engine and the nodes attached to it.
    private struct Graph {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        /// Where the microphone goes in the graph: nowhere audible. Voice processing wants
        /// the microphone and the speaker on the same client-side format, and this gives
        /// the microphone one (mono at the hardware rate) that the output is given too.
        let sink = AVAudioMixerNode()

        init() {
            engine.attach(player)
            engine.attach(sink)
            sink.outputVolume = 0
        }
    }

    /// Only under `lock`; nil between calls.
    private var graph: Graph?

    private let playerFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(VoiceAudioFormat.sampleRate), channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()

    /// Speech is held back this long before an utterance starts playing, so a chunk that
    /// is late over the network doesn't leave a gap.
    static let prebufferSeconds = 0.3

    /// Only under `lock`.
    private var pending = Data()
    private var queued = 0

    /// Speech received but not yet scheduled, while an utterance's start is held back.
    private var held = Data()
    private var playGeneration = 0
    private(set) var chunksCaptured = 0
    private(set) var bytesPlayed = 0

    /// Muted, the microphone sends silence, so the session's clock keeps running. Set on
    /// the main thread, read on the audio thread.
    var isMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return muted }
        set { lock.lock(); muted = newValue; lock.unlock() }
    }

    /// Called on the audio thread with what the microphone hears while muted, at 24 kHz
    /// mono, for the Mac's own listening for "unmute".
    var onMutedAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return mutedAudio }
        set { lock.lock(); mutedAudio = newValue; lock.unlock() }
    }

    /// Only under `lock`.
    private var muted = false
    private var mutedAudio: (@Sendable (AVAudioPCMBuffer) -> Void)?

    /// Speech has been scheduled that hasn't finished playing. Set on any thread.
    private(set) var isPlaying = false

    /// Called on the main thread when `isPlaying` changes.
    var onPlayingChanged: (@MainActor (Bool) -> Void)?

    init() {}

    deinit {
        if let graph = takeGraph() { Self.tearDown(graph) }
    }

    /// Whether the user has let the app use the microphone, asking if they haven't been.
    static func requestAccess() async -> Bool {
        await VoicePermission.microphone.request() == .allowed
    }

    /// A call's engine is running.
    var isCapturing: Bool { currentGraph?.engine.isRunning ?? false }

    /// A call's engine has Apple's voice processing on it. Between calls there is no engine,
    /// so this is false, and the rest of the Mac's sound is its own again.
    var isVoiceProcessing: Bool { currentGraph?.engine.inputNode.isVoiceProcessingEnabled ?? false }

    /// How far the call's voice processing turns the rest of the Mac down; nil between
    /// calls or without voice processing.
    @available(macOS 14.0, *)
    var duckingLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level? {
        guard let input = currentGraph?.engine.inputNode, input.isVoiceProcessingEnabled else { return nil }
        return input.voiceProcessingOtherAudioDuckingConfiguration.duckingLevel
    }

    /// The call's engine, for tests to hold weakly and see let go of.
    var engineForTesting: AVAudioEngine? { currentGraph?.engine }

    private var currentGraph: Graph? {
        lock.lock(); defer { lock.unlock() }
        return graph
    }

    private func takeGraph() -> Graph? {
        lock.lock(); defer { lock.unlock() }
        let taken = graph
        graph = nil
        return taken
    }

    /// The aggregate device made for a microphone and speaker that aren't one device.
    private var aggregate: AudioDeviceID?

    /// The microphone's gain as the user had it before the call, put back after it should
    /// anything have moved it meanwhile. Voice processing may drive the input device's
    /// gain for its own ends; the user's setting is theirs. Main thread only.
    private var microphoneLevel: (device: AudioDeviceID, volume: Float)?

    /// Whether a gain that was `before` the call and is `after` it has been moved: more
    /// than a rounding error, as System Settings shows it.
    static func microphoneLevelMoved(from before: Float, to after: Float) -> Bool {
        abs(before - after) > 0.01
    }

    private static func rememberMicrophoneLevel(of input: AudioDeviceID?) -> (device: AudioDeviceID, volume: Float)? {
        guard let device = input ?? VoiceDevices.defaultDevice(input: true),
              let volume = VoiceDevices.inputVolume(of: device) else { return nil }
        return (device, volume)
    }

    private static func restoreMicrophoneLevel(_ level: (device: AudioDeviceID, volume: Float)) {
        guard let now = VoiceDevices.inputVolume(of: level.device), microphoneLevelMoved(from: level.volume, to: now) else { return }
        let restored = VoiceDevices.setInputVolume(level.volume, of: level.device)
        logger.notice("microphone gain moved from \(level.volume) to \(now) during the call; put back: \(restored)")
    }

    /// Starts the engine both ways, on the given devices (nil for the system's defaults),
    /// calling `onChunk` off the main thread with each chunk of microphone audio.
    func start(
        echoCancellation: Bool, inputDevice: AudioDeviceID? = nil, outputDevice: AudioDeviceID? = nil,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        do {
            try start(voiceProcessing: echoCancellation, inputDevice: inputDevice, outputDevice: outputDevice, onChunk: onChunk)
        } catch where echoCancellation {
            // Voice processing refused this hardware; the plain engine is better than none.
            Self.logger.warning("voice processing couldn't start (\(String(describing: error), privacy: .public)); going without")
            try start(voiceProcessing: false, inputDevice: inputDevice, outputDevice: outputDevice, onChunk: onChunk)
        }
    }

    private func start(
        voiceProcessing: Bool, inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        // Never two engines: the one before, if any, goes first, voice processing and all.
        stop()
        for attempt in 1...Self.startAttempts {
            let graph = Graph()
            lock.lock()
            self.graph = graph
            lock.unlock()
            do {
                try build(graph, voiceProcessing: voiceProcessing, inputDevice: inputDevice, outputDevice: outputDevice, onChunk: onChunk)
                return
            } catch {
                // Half-built, the engine would still hold the voice processing unit.
                stop()
                guard attempt < Self.startAttempts else { throw error }
                Self.logger.notice("audio engine wouldn't start (\(String(describing: error), privacy: .public)); trying again")
                Thread.sleep(forTimeInterval: Self.startRetryInterval)
            }
        }
    }

    /// Right after an engine is torn down, CoreAudio can report the hardware's format as
    /// nothing for a moment while it lets the old units go, and a new engine refuses to
    /// start (-10875, "IsFormatSampleRateAndChannelCountValid(outputHWFormat)", seen when
    /// echo cancellation was switched off mid-call). A few tries, a moment apart, see it
    /// through; a Mac with no microphone at all fails after a second, as before.
    static let startAttempts = 10
    static let startRetryInterval: TimeInterval = 0.1

    private func build(
        _ graph: Graph, voiceProcessing: Bool, inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        let engine = graph.engine
        let input = engine.inputNode
        if voiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                Self.limitDucking(on: input)
            } catch {
                Self.logger.warning("voice processing unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        applyDevices(engine, input: inputDevice, output: outputDevice, voiceProcessing: input.isVoiceProcessingEnabled)
        microphoneLevel = Self.rememberMicrophoneLevel(of: inputDevice)

        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noInput }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: playerFormat) else { throw Failure.noConverter }
        self.converter = converter

        // Microphone, mono, into a silent sink; speech into the mixer; both out in mono at
        // the microphone's rate, which is what voice processing insists on.
        engine.connect(input, to: graph.sink, format: mono)
        engine.connect(graph.sink, to: engine.mainMixerNode, format: mono)
        engine.connect(graph.player, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        Self.logger.info("microphone \(hardware.sampleRate)Hz x\(hardware.channelCount), voice processing \(input.isVoiceProcessingEnabled)")

        input.installTap(onBus: 0, bufferSize: 2048, format: mono) { [weak self] buffer, _ in
            self?.convert(buffer, with: converter, onChunk: onChunk)
        }
        engine.prepare()
        try engine.start()
        graph.player.play()
    }

    /// How far voice processing may turn the rest of the Mac's sound down during a call:
    /// as little as Apple allows. Its default is tuned for a phone call, and halved the
    /// user's music and videos for as long as the voice was on (v0.28). Nothing is
    /// settable before macOS 14; there the default stands.
    static func limitDucking(on input: AVAudioInputNode) {
        guard #available(macOS 14.0, *) else { return }
        input.voiceProcessingOtherAudioDuckingConfiguration = duckingConfiguration
    }

    @available(macOS 14.0, *)
    static var duckingConfiguration: AVAudioVoiceProcessingOtherAudioDuckingConfiguration {
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
    }

    /// Voice processing is its own aggregate of an input device and an output device,
    /// set one each; the plain I/O unit takes one device, an aggregate when they differ.
    private func applyDevices(_ engine: AVAudioEngine, input: AudioDeviceID?, output: AudioDeviceID?, voiceProcessing: Bool) {
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        func set(_ unit: AudioUnit?, element: AudioUnitElement, _ device: AudioDeviceID) {
            guard let unit else { return }
            var id = device
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, element, &id, size)
            if status != noErr {
                Self.logger.warning("couldn't set audio device \(device) on element \(element): \(status)")
            }
        }
        if voiceProcessing {
            if let input { set(engine.inputNode.audioUnit, element: 1, input) }
            if let output { set(engine.outputNode.audioUnit, element: 0, output) }
        } else if let device = chooseDevice(input: input, output: output) {
            set(engine.inputNode.audioUnit, element: 0, device)
            set(engine.outputNode.audioUnit, element: 0, device)
        }
    }

    /// Ends the call's audio and lets go of everything it held: the engine, Apple's voice
    /// processing unit, and the aggregate device; and puts the microphone's gain back where
    /// the user had it. Safe to call at any time, as often as wanted.
    func stop() {
        if let graph = takeGraph() { Self.tearDown(graph) }
        if let aggregate {
            VoiceDevices.destroy(aggregate: aggregate)
            self.aggregate = nil
        }
        if let microphoneLevel {
            self.microphoneLevel = nil
            Self.restoreMicrophoneLevel(microphoneLevel)
        }
        lock.lock()
        pending.removeAll()
        held = Data()
        queued = 0
        playGeneration += 1
        lock.unlock()
        setPlaying(false)
    }

    /// Takes a call's engine apart so nothing of it outlives the call. Each step is one
    /// more way the voice processing unit is let go of, should the one before it not be
    /// enough: the unit is switched off on the stopped engine, the engine's graph is
    /// reset and its nodes detached, and the engine itself is dropped on return.
    private static func tearDown(_ graph: Graph) {
        let engine = graph.engine
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        graph.player.stop()
        engine.stop()
        if input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(false)
            } catch {
                logger.warning("voice processing wouldn't switch off: \(String(describing: error), privacy: .public)")
            }
        }
        engine.reset()
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.disconnectNodeInput(engine.outputNode)
        engine.detach(graph.player)
        engine.detach(graph.sink)
        logger.info("audio engine torn down, voice processing \(input.isVoiceProcessingEnabled)")
    }

    /// The one device the engine runs on, or nil to leave it on the system's defaults.
    private func chooseDevice(input: AudioDeviceID?, output: AudioDeviceID?) -> AudioDeviceID? {
        guard input != nil || output != nil else { return nil }
        guard let input = input ?? VoiceDevices.defaultDevice(input: true),
              let output = output ?? VoiceDevices.defaultDevice(input: false) else { return nil }
        let combined = VoiceDevices.combined(input: input, output: output)
        aggregate = combined.aggregate
        return combined.device
    }

    // MARK: Microphone

    private func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, onChunk: (Data) -> Void) {
        let ratio = playerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: playerFormat, frameCapacity: capacity) else { return }
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
        if let error {
            Self.logger.warning("conversion failed: \(String(describing: error), privacy: .public)")
            return
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else { return }
        let samples = UnsafeBufferPointer(start: channel, count: Int(output.frameLength))
        lock.lock()
        let muted = self.muted
        let listener = muted ? mutedAudio : nil
        lock.unlock()
        let pcm = muted ? Data(count: samples.count * 2) : VoiceAudioFormat.pcm16(from: samples)
        listener?(output)

        lock.lock()
        pending.append(pcm)
        var chunks: [Data] = []
        while pending.count >= VoiceAudioFormat.chunkBytes {
            chunks.append(pending.prefix(VoiceAudioFormat.chunkBytes))
            pending.removeFirst(VoiceAudioFormat.chunkBytes)
        }
        chunksCaptured += chunks.count
        lock.unlock()
        for chunk in chunks { onChunk(chunk) }
    }

    // MARK: Speaker

    /// Plays `pcm` after what is already playing. The first of an utterance waits for a
    /// little more to arrive, so playback keeps ahead of the network.
    func play(_ pcm: Data) {
        guard let graph = currentGraph, graph.engine.isRunning, !pcm.isEmpty else { return }
        lock.lock()
        held.append(pcm)
        let starting = queued == 0
        let enough = Double(held.count) / 2 / Double(VoiceAudioFormat.sampleRate) >= Self.prebufferSeconds
        guard !starting || enough else {
            lock.unlock()
            return
        }
        let chunk = held
        held = Data()
        lock.unlock()
        schedule(chunk)
    }

    /// What is held back plays now: the utterance ended before the prebuffer filled.
    func flush() {
        lock.lock()
        let chunk = held
        held = Data()
        lock.unlock()
        if !chunk.isEmpty { schedule(chunk) }
    }

    private func schedule(_ pcm: Data) {
        guard let graph = currentGraph, let buffer = VoiceAudioFormat.buffer(from: pcm, format: playerFormat) else { return }
        let player = graph.player
        lock.lock()
        queued += 1
        bytesPlayed += pcm.count
        let generation = playGeneration
        lock.unlock()
        setPlaying(true)
        if !player.isPlaying { player.play() }
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            let current = generation == self.playGeneration
            if current { self.queued -= 1 }
            let done = current && self.queued <= 0
            if done { self.queued = 0 }
            self.lock.unlock()
            if done { self.setPlaying(false) }
        }
    }

    /// Drops what hasn't played yet.
    func stopPlayback() {
        lock.lock()
        playGeneration += 1
        queued = 0
        held = Data()
        lock.unlock()
        if let graph = currentGraph {
            graph.player.stop()
            if graph.engine.isRunning { graph.player.play() }
        }
        setPlaying(false)
    }

    private func setPlaying(_ playing: Bool) {
        lock.lock()
        let changed = isPlaying != playing
        isPlaying = playing
        lock.unlock()
        guard changed, let onPlayingChanged else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { onPlayingChanged(playing) }
        }
    }

    /// How much has gone each way, for the log.
    var stats: (captured: Int, played: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (chunksCaptured, bytesPlayed)
    }

    enum Failure: Error, CustomStringConvertible {
        case noInput
        case noConverter

        var description: String {
            switch self {
            case .noInput: return "No microphone is available."
            case .noConverter: return "The microphone's audio can't be converted."
            }
        }
    }
}

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
final class VoiceAudioEngine: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: String(describing: VoiceAudioEngine.self)
    )

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()

    /// Where the microphone goes in the graph: nowhere audible. Voice processing wants
    /// the microphone and the speaker on the same client-side format, and this gives the
    /// microphone one (mono at the hardware rate) that the output is given too.
    private let sink = AVAudioMixerNode()
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

    init() {
        engine.attach(player)
        engine.attach(sink)
        sink.outputVolume = 0
    }

    /// Whether the user has let the app use the microphone, asking if they haven't been.
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    /// The aggregate device made for a microphone and speaker that aren't one device.
    private var aggregate: AudioDeviceID?

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
            stop()
            try start(voiceProcessing: false, inputDevice: inputDevice, outputDevice: outputDevice, onChunk: onChunk)
        }
    }

    private func start(
        voiceProcessing: Bool, inputDevice: AudioDeviceID?, outputDevice: AudioDeviceID?,
        onChunk: @escaping @Sendable (Data) -> Void
    ) throws {
        let input = engine.inputNode
        if voiceProcessing != input.isVoiceProcessingEnabled {
            do {
                try input.setVoiceProcessingEnabled(voiceProcessing)
            } catch {
                Self.logger.warning("voice processing unavailable: \(String(describing: error), privacy: .public)")
            }
        }
        applyDevices(input: inputDevice, output: outputDevice, voiceProcessing: input.isVoiceProcessingEnabled)

        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0 else { throw Failure.noInput }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: mono, to: playerFormat) else { throw Failure.noConverter }
        self.converter = converter

        // Microphone, mono, into a silent sink; speech into the mixer; both out in mono at
        // the microphone's rate, which is what voice processing insists on.
        engine.connect(input, to: sink, format: mono)
        engine.connect(sink, to: engine.mainMixerNode, format: mono)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: mono)
        Self.logger.info("microphone \(hardware.sampleRate)Hz x\(hardware.channelCount), voice processing \(input.isVoiceProcessingEnabled)")

        input.installTap(onBus: 0, bufferSize: 2048, format: mono) { [weak self] buffer, _ in
            self?.convert(buffer, with: converter, onChunk: onChunk)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
    }

    /// Voice processing is its own aggregate of an input device and an output device,
    /// set one each; the plain I/O unit takes one device, an aggregate when they differ.
    private func applyDevices(input: AudioDeviceID?, output: AudioDeviceID?, voiceProcessing: Bool) {
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

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        engine.stop()
        if let aggregate {
            VoiceDevices.destroy(aggregate: aggregate)
            self.aggregate = nil
        }
        lock.lock()
        pending.removeAll()
        held = Data()
        queued = 0
        playGeneration += 1
        lock.unlock()
        setPlaying(false)
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
        guard engine.isRunning, !pcm.isEmpty else { return }
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
        guard let buffer = VoiceAudioFormat.buffer(from: pcm, format: playerFormat) else { return }
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
        player.stop()
        if engine.isRunning { player.play() }
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

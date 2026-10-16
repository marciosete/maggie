import Combine
import Foundation

/// A paired device as the voice's handset: its microphone frames feed GPT-Live, and the
/// voice's speech goes back to it as frames. The Mac stays the brain, with the one
/// session, memory and tools; the device is a microphone and a speaker anywhere the
/// paired connection reaches.
@MainActor
final class RemoteVoiceEndpoint: VoiceAudioEndpoint {
    let endpointName: String
    private let socket: RemoteSocket
    private var onChunk: (@Sendable (Data) -> Void)?
    private var muted = false

    init(deviceName: String, socket: RemoteSocket) {
        endpointName = deviceName
        self.socket = socket
    }

    func startCapture(muted: Bool, onChunk: @escaping @Sendable (Data) -> Void) throws {
        self.muted = muted
        self.onChunk = onChunk
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
    }

    func stopCapture() {
        onChunk = nil
    }

    /// A microphone frame from the device. Muted, silence of the same length goes on,
    /// so GPT-Live's clock keeps running.
    func received(_ pcm: Data) {
        guard let onChunk else { return }
        onChunk(muted ? Data(count: pcm.count) : pcm)
    }

    func play(_ pcm: Data) {
        socket.send(RemoteFrame(stream: RemoteProtocol.voiceStream, kind: .voiceOutput, payload: pcm))
    }

    func flushPlayback() {}

    func stopPlayback() {
        // The device plays frames as they come; there is nothing queued here to drop.
    }
}

/// One device's view of the voice: answers its voice messages, and while it subscribes,
/// sends it the state and each turn as they come.
@MainActor
final class RemoteVoiceBridge {
    private let socket: RemoteSocket
    private let agent = VoiceAgent.shared
    private var endpoint: RemoteVoiceEndpoint?
    private var subscriptions: Set<AnyCancellable> = []
    private var sentTurns = 0
    private var lastState: VoiceState?

    init(socket: RemoteSocket) {
        self.socket = socket
    }

    var isHandset: Bool { endpoint != nil && agent.endpointName == endpoint?.endpointName }

    func handle(_ message: ClientMessage) -> Bool {
        switch message {
        case .startVoice(let request):
            let endpoint = RemoteVoiceEndpoint(deviceName: request.deviceName, socket: socket)
            self.endpoint = endpoint
            agent.use(endpoint)
            if !agent.phase.isOn { agent.start() } else if agent.phase == .paused { agent.resume() }
            subscribe()
            sendState(force: true)
        case .stopVoice(let request):
            if isHandset { agent.use(nil) }
            endpoint = nil
            if request.endsVoice { agent.stop() }
            sendState(force: true)
        case .muteVoice(let request):
            if agent.isMuted != request.muted { agent.toggleMute() }
            sendState(force: true)
        case .subscribeVoice:
            subscribe()
            sentTurns = max(0, agent.turns.count - 40)
            sendTurns()
            sendState(force: true)
        default:
            return false
        }
        return true
    }

    /// A voice frame from the device.
    func received(_ frame: RemoteFrame) -> Bool {
        guard frame.kind == .voiceInput else { return false }
        if frame.stream == RemoteProtocol.voiceStream, isHandset { endpoint?.received(frame.payload) }
        return true
    }

    /// The device went away: the Mac's own microphone takes over.
    func closed() {
        if isHandset { agent.use(nil) }
        endpoint = nil
        subscriptions = []
    }

    private func subscribe() {
        guard subscriptions.isEmpty else { return }
        agent.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sendTurns()
                    self?.sendState(force: false)
                }
            }
            .store(in: &subscriptions)
    }

    private func sendTurns() {
        let turns = agent.turns
        guard sentTurns < turns.count else {
            sentTurns = turns.count
            return
        }
        for turn in turns[sentTurns...] {
            socket.send(.voiceTurn(VoiceTurnMessage(
                id: turn.id.uuidString, role: Self.role(turn.role), text: turn.text, at: turn.at)))
        }
        sentTurns = turns.count
    }

    private func sendState(force: Bool) {
        let state = currentState()
        guard force || state != lastState else { return }
        lastState = state
        socket.send(.voiceState(state))
    }

    func currentState() -> VoiceState {
        var error: String?
        let phase: VoiceState.Phase
        switch agent.phase {
        case .off: phase = .off
        case .connecting: phase = .connecting
        case .live: phase = .live
        case .paused: phase = .paused
        case .failed(let message):
            phase = .failed
            error = message
        }
        return VoiceState(
            phase: phase,
            muted: agent.isMuted,
            isHandset: isHandset,
            handsetName: agent.endpointName,
            billedSeconds: (agent.liveSeconds * 10).rounded() / 10,
            userSpeaking: agent.userSpeaking,
            assistantSpeaking: agent.assistantSpeaking,
            workingOn: agent.workingOn,
            error: error)
    }

    private static func role(_ role: VoiceTurn.Role) -> VoiceTurnMessage.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .notice: return .notice
        case .tool: return .tool
        }
    }
}

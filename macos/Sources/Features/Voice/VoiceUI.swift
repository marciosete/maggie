import AppKit
import Combine
import SwiftUI

/// The microphone in the status bar, or at the bottom of the tab sidebar when the status
/// bar doesn't show it. Off, it offers to start the voice; on, it shows what the voice is
/// doing and opens the transcript.
struct VoiceButton: View {
    @ObservedObject var agent = VoiceAgent.shared

    /// Says what the voice is doing next to the microphone, as the status bar's items do.
    var showsState = false

    @State private var isShowingPopover = false

    var body: some View {
        Button {
            if agent.phase == .off || agent.phase.isFailed {
                agent.start()
                isShowingPopover = agent.phase.isFailed
            } else {
                isShowingPopover.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: showsState ? 10 : 13))
                if showsState {
                    Text(stateText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(style)
        .help(help)
        .popover(isPresented: $isShowingPopover, arrowEdge: .top) {
            VoicePopover(agent: agent) { isShowingPopover = false }
        }
    }

    private var symbol: String {
        switch agent.phase {
        case .off: return "mic"
        case .connecting: return "mic.badge.xmark"
        case .live: return agent.isMuted ? "mic.slash.fill" : "mic.fill"
        case .paused: return "mic.badge.plus"
        case .failed: return "mic.slash"
        }
    }

    private var stateText: String {
        switch agent.phase {
        case .off: return "Voice"
        case .connecting: return "Connecting"
        case .live:
            if let tool = agent.workingOn { return tool.replacingOccurrences(of: "_", with: " ") }
            if agent.isMuted { return "Muted" }
            if agent.assistantSpeaking { return "Speaking" }
            if agent.userSpeaking { return "Listening" }
            return "On"
        case .paused: return "Paused"
        case .failed: return "Failed"
        }
    }

    private var style: AnyShapeStyle {
        switch agent.phase {
        case .off: return AnyShapeStyle(.secondary)
        case .connecting, .paused: return AnyShapeStyle(Color.orange)
        case .live: return AnyShapeStyle(agent.userSpeaking ? Color.green : Color.accentColor)
        case .failed: return AnyShapeStyle(Color.red)
        }
    }

    private var help: String {
        switch agent.phase {
        case .off: return "Talk to Maggie"
        case .connecting: return "Connecting to GPT-Live"
        case .live: return "Talking to Maggie"
        case .paused: return "Voice paused; click or speak to continue"
        case .failed(let message): return message
        }
    }
}

/// The transcript and controls of the voice.
struct VoicePopover: View {
    @ObservedObject var agent: VoiceAgent
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if case .failed(let message) = agent.phase {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            transcript
            controls
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("Voice")
                .font(.headline)
            Spacer()
            Text(usage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var usage: String {
        let minutes = Int(agent.liveSeconds / 60)
        let seconds = Int(agent.liveSeconds) % 60
        let cost = agent.liveSeconds / 60 * VoiceAgent.perMinuteUSD
        return String(format: "%d:%02d · $%.2f · %@", minutes, seconds, cost, agent.endpointName)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if agent.turns.isEmpty {
                        Text(agent.phase == .live ? "Listening. Ask what's happening, or tell a session what to do." : "Nothing said yet.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    ForEach(agent.turns.suffix(80)) { turn in
                        VoiceTurnView(turn: turn)
                            .id(turn.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(height: 260)
            .onChange(of: agent.turns.count) { _ in
                if let last = agent.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = agent.turns.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var controls: some View {
        HStack {
            switch agent.phase {
            case .off, .failed:
                Button("Start") { agent.start() }
                    .keyboardShortcut(.defaultAction)
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
            case .live:
                Button(agent.isMuted ? "Unmute" : "Mute") { agent.toggleMute() }
            case .paused:
                Button("Continue") { agent.resume() }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
            if agent.phase.isOn {
                Button("Stop") { agent.stop() }
            }
            Button("Settings…") {
                dismiss()
                SettingsController.shared.show()
            }
        }
        .controlSize(.small)
    }
}

private struct VoiceTurnView: View {
    let turn: VoiceTurn

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 44, alignment: .trailing)
            Text(turn.text)
                .font(.callout)
                .foregroundStyle(turn.role == .user || turn.role == .assistant ? .primary : .secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var label: String {
        switch turn.role {
        case .user: return "You"
        case .assistant: return "Maggie"
        case .notice: return "Notice"
        case .tool: return "Did"
        }
    }

    private var color: Color {
        switch turn.role {
        case .user: return .green
        case .assistant: return .accentColor
        case .notice: return .orange
        case .tool: return .secondary
        }
    }
}

/// Settings → Voice: the key, the voices and models, and when to pause.
struct VoiceSettingsView: View {
    @ObservedObject private var settings = VoiceSettings.shared
    @ObservedObject private var agent = VoiceAgent.shared
    @State private var apiKey = OpenAI.apiKey() ?? ""
    @State private var keySaved = OpenAI.apiKey() != nil
    @State private var inputs: [VoiceDevices.Device] = []
    @State private var outputs: [VoiceDevices.Device] = []

    var body: some View {
        Form {
            Section {
                SecureField("OpenAI API key", text: $apiKey)
                    .onSubmit(saveKey)
                HStack {
                    Text(keySaved ? "Kept in ~/.config/ghostty/openai-api-key, readable only by you." : "No key saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save") { saveKey() }
                        .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines) == (OpenAI.apiKey() ?? ""))
                }
            } header: {
                Text("GPT-Live")
            } footer: {
                Text("Maggie talks through OpenAI's GPT-Live, billed by the second (about $3 an hour while on), with a backend model that runs the sessions, billed by the token.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(inputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Picker("Speaker", selection: $settings.outputDeviceUID) {
                    Text("System default").tag("")
                    ForEach(outputs) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                Toggle("Cancel echo from the speaker", isOn: $settings.echoCancellation)
            } header: {
                Text("Audio")
            } footer: {
                Text(audioFooter)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Voice") {
                Picker("Voice", selection: $settings.voice) {
                    ForEach(VoiceSettings.voices, id: \.self) { Text($0.capitalized).tag($0) }
                }
                Picker("Backend model", selection: $settings.backendModel) {
                    ForEach(VoiceSettings.backendModels, id: \.self) { Text($0).tag($0) }
                }
                TextField("Your name", text: $settings.userName, prompt: Text("Optional"))
            }

            Section {
                Picker("Pause after", selection: $settings.idleMinutes) {
                    Text("Never").tag(0)
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                }
                Toggle("Announce every session that finishes or needs me", isOn: $settings.announcesAllSessions)
            } header: {
                Text("While on")
            } footer: {
                Text("Paused or muted, the voice stops billing or listening, and the Mac alone listens for \"hey Maggie\" or \"unmute\" to bring it back; a click does too, and a watched session's news wakes a pause. Say \"mute\", \"pause\" or \"hang up\" to the voice itself. Sessions you open or instruct by voice are always announced.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Memory") {
                LabeledContent("Notes") {
                    Text("\(agent.memory.state.notes.count)").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([agent.memory.file])
                    }
                    Button("Show Transcripts") {
                        NSWorkspace.shared.activateFileViewerSelecting([agent.log.directory])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshDevices)
    }

    /// A chosen device that isn't connected is kept, and said to be missing.
    private var audioFooter: String {
        var missing: [String] = []
        if !settings.inputDeviceUID.isEmpty, !inputs.contains(where: { $0.uid == settings.inputDeviceUID }) {
            missing.append("The chosen microphone isn't connected; the default is used until it is.")
        }
        if !settings.outputDeviceUID.isEmpty, !outputs.contains(where: { $0.uid == settings.outputDeviceUID }) {
            missing.append("The chosen speaker isn't connected; the default is used until it is.")
        }
        if missing.isEmpty {
            return "Changes apply at once, even mid-conversation. With echo cancellation on, the microphone ignores what the speaker says; headphones make it unnecessary."
        }
        return missing.joined(separator: " ")
    }

    private func refreshDevices() {
        inputs = VoiceDevices.inputs()
        outputs = VoiceDevices.outputs()
    }

    private func saveKey() {
        do {
            try OpenAI.saveAPIKey(apiKey)
            keySaved = OpenAI.apiKey() != nil
        } catch {
            keySaved = false
        }
    }
}

/// The View menu's item for the voice.
@MainActor
final class VoiceMenu: NSObject {
    static let shared = VoiceMenu()

    private weak var item: NSMenuItem?
    private var observation: AnyCancellable?

    func install() {
        guard let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu,
              !view.items.contains(where: { $0.action == #selector(toggle(_:)) }) else { return }
        let item = NSMenuItem(title: "Talk to Maggie", action: #selector(toggle(_:)), keyEquivalent: "v")
        item.keyEquivalentModifierMask = [.control, .option]
        item.target = self
        item.setImageIfDesired(systemSymbolName: "mic")
        let usage = view.items.firstIndex { $0.action == #selector(TerminalController.toggleUsage(_:)) }
        let index = usage.map { $0 + 1 } ?? view.items.count
        view.insertItem(item, at: index)
        self.item = item

        let mute = NSMenuItem(title: "Mute Maggie's Microphone", action: #selector(toggleMute(_:)), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = [.control, .option]
        mute.target = self
        mute.setImageIfDesired(systemSymbolName: "mic.slash")
        view.insertItem(mute, at: index + 1)
        muteItem = mute

        observation = VoiceAgent.shared.$phase.combineLatest(VoiceAgent.shared.$isMuted).sink { [weak self] phase, muted in
            self?.item?.state = phase.isOn ? .on : .off
            self?.item?.title = phase.isOn ? "Stop Talking to Maggie" : "Talk to Maggie"
            self?.muteItem?.isEnabled = phase == .live
            self?.muteItem?.state = muted ? .on : .off
        }
    }

    private weak var muteItem: NSMenuItem?

    @objc private func toggle(_ sender: Any?) {
        VoiceAgent.shared.toggle()
    }

    @objc private func toggleMute(_ sender: Any?) {
        VoiceAgent.shared.toggleMute()
    }
}

import SwiftUI

/// The app's settings: which coding agent new sessions start, and whether they start one.
/// Everything else Ghostty configures is in its configuration file, which the view opens.
struct SettingsView: View {
    @ObservedObject private var agentSettings = CodingAgentSettings.shared
    @ObservedObject private var agentStart = AgentStart.shared

    /// What each agent's command reported, once asked: its version, or nil when it isn't
    /// installed. Missing while it hasn't answered.
    @State private var installed: [CodingAgent: String?] = [:]

    var openConfiguration: () -> Void = {}

    var body: some View {
        Form {
            Section {
                ForEach(CodingAgent.allCases, id: \.self) { agent in
                    Toggle(agent.displayName, isOn: Binding(
                        get: { agentSettings.isEnabled(agent) },
                        set: { agentSettings.setEnabled(agent, $0) }))
                }

                if agentSettings.enabled.isEmpty {
                    LabeledContent("Primary") {
                        Text("No agent enabled").foregroundStyle(.secondary)
                    }
                } else {
                    Picker("Primary", selection: Binding(
                        get: { agentSettings.primary ?? agentSettings.enabled[0] },
                        set: { agentSettings.setPrimary($0) })
                    ) {
                        ForEach(agentSettings.enabled, id: \.self) { agent in
                            Text(agent.displayName).tag(agent)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .horizontalRadioGroupLayout()
                }

                Toggle("Start the primary agent in new sessions", isOn: $agentStart.isEnabled)
                    .disabled(agentSettings.primary == nil)
                Toggle("Use a worktree", isOn: $agentStart.startsInWorktree)
                    .disabled(agentSettings.primary == nil || !agentStart.isEnabled)
            } header: {
                Text("Coding Agents")
            } footer: {
                Text("With a worktree, each session in a git repository works in its own worktree (claude -w, codex --worktree) and the sidebar lands it. Without one, sessions work on the main checkout.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Installed") {
                ForEach(CodingAgent.allCases, id: \.self) { agent in
                    LabeledContent(agent.displayName) {
                        installedText(agent)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                LabeledContent("Terminal") {
                    Button("Open Configuration File…", action: openConfiguration)
                }
            } footer: {
                Text("Fonts, colors, keybindings and the rest are set in the configuration file.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .task { await checkInstalled() }
    }

    @ViewBuilder
    private func installedText(_ agent: CodingAgent) -> some View {
        switch installed[agent] {
        case .none: Text("Checking…")
        case .some(.none): Text("Not installed")
        case .some(.some(let version)): Text(version)
        }
    }

    /// Asks each agent's command for its version, off the main thread.
    private func checkInstalled() async {
        let versions = await Task.detached(priority: .utility) {
            var versions: [CodingAgent: String?] = [:]
            for agent in CodingAgent.allCases {
                versions[agent] = .some(agent.installedVersion())
            }
            return versions
        }.value
        installed = versions
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
    }
}

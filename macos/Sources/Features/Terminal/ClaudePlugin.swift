import Foundation

/// The Claude Code plugin Maggie ships in its bundle (`ClaudePlugin`, in Resources). Its
/// skills are commands every Claude Code session in the app has, out of the box, as
/// `/maggie:<skill>`: nothing is installed into `~/.claude`, so they come and go with
/// the app and a session outside it never sees them. The View menu and the command
/// palette list them (`ClaudePluginMenu`).
///
/// Claude Code loads it from `CLAUDE_CODE_PLUGIN_DIRS`, which it reads like a
/// `--plugin-dir` per path. Setting it on the terminal, rather than in the start command,
/// reaches a resumed session and an agent started by hand there just the same.
enum ClaudePlugin {
    static let environmentVariable = "CLAUDE_CODE_PLUGIN_DIRS"

    /// The plugin's name in `plugin.json`, which Claude Code puts before each command.
    static let name = "maggie"

    /// A command the plugin ships: one of its skills.
    struct Command: Equatable {
        /// The skill's name, from its `SKILL.md`: `force-multiplier`.
        let name: String

        /// What the skill does, from its `SKILL.md`.
        let description: String

        /// What is typed into Claude Code to run it: `/maggie:force-multiplier`.
        var slashCommand: String { "/\(ClaudePlugin.name):\(name)" }

        /// The name as a menu title: `Force Multiplier`.
        var title: String {
            name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
    }

    /// The commands of the plugin in this build's bundle.
    static var commands: [Command] {
        directory.map { commands(in: $0) } ?? []
    }

    /// The commands of the plugin at `directory`, by name: a folder in `skills/` with a
    /// `SKILL.md` that names it.
    static func commands(in directory: URL) -> [Command] {
        let skills = directory.appendingPathComponent("skills")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skills.path)) ?? []
        return names.sorted().compactMap { folder in
            let file = skills.appendingPathComponent(folder).appendingPathComponent("SKILL.md")
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let fields = frontmatter(text)
            guard let name = fields["name"], !name.isEmpty else { return nil }
            return Command(name: name, description: fields["description"] ?? "")
        }
    }

    /// The `key: value` lines between a Markdown file's opening `---` lines.
    static func frontmatter(_ text: String) -> [String: String] {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }
        return fields
    }

    /// Whether `surface` runs Claude Code, which has the plugin's commands. Codex and a
    /// plain shell don't.
    @MainActor
    static func canRun(in surface: Ghostty.SurfaceView?) -> Bool {
        guard let pid = surface?.surfaceModel?.foregroundPID else { return false }
        return ClaudeCodeSession.id(ofRunning: pid) != nil
    }

    /// Runs `command` in the Claude Code session in `surface`, as if it were typed and
    /// sent: the command goes in as text, then Return sends it. A session that is busy
    /// queues it, the way it does anything typed while it works.
    @MainActor
    static func run(_ command: Command, in surface: Ghostty.SurfaceView) {
        guard let model = surface.surfaceModel else { return }
        model.sendText(command.slashCommand)
        model.sendKeyEvent(Ghostty.Input.KeyEvent(
            synthesizing: .enter,
            action: .press,
            mods: [],
            translationMods: []))
    }

    /// The plugin in this build's bundle, if it has one.
    static var directory: URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("ClaudePlugin"),
              FileManager.default.fileExists(atPath: url.appendingPathComponent(".claude-plugin/plugin.json").path)
        else { return nil }
        return url
    }

    /// Adds the plugin to the terminal's plugin directories, after any the terminal or
    /// the app's own environment already lists.
    static func addEnvironment(to configuration: inout Ghostty.SurfaceConfiguration) {
        guard let directory else { return }
        let existing = configuration.environmentVariables[environmentVariable]
            ?? ProcessInfo.processInfo.environment[environmentVariable]
        configuration.environmentVariables[environmentVariable] = pluginDirectories(existing, adding: directory.path)
    }

    /// `existing`, a colon-separated list, with `path` on the end unless it is there.
    static func pluginDirectories(_ existing: String?, adding path: String) -> String {
        let paths = (existing ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if paths.contains(path) { return paths.joined(separator: ":") }
        return (paths + [path]).joined(separator: ":")
    }
}

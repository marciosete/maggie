import Foundation

/// The Claude Code plugin Maggie ships in its bundle (`ClaudePlugin`, in Resources). Its
/// skills are commands every Claude Code session in the app has, out of the box, as
/// `/maggie:<skill>`: nothing is installed into `~/.claude`, so they come and go with
/// the app and a session outside it never sees them.
///
/// Claude Code loads it from `CLAUDE_CODE_PLUGIN_DIRS`, which it reads like a
/// `--plugin-dir` per path. Setting it on the terminal, rather than in the start command,
/// reaches a resumed session and an agent started by hand there just the same.
enum ClaudePlugin {
    static let environmentVariable = "CLAUDE_CODE_PLUGIN_DIRS"

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

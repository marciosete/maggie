import AppKit

/// Pasting an image into an agent with the paste key. With only an image on the
/// clipboard there is no text to paste, and the paste binding lets the key through to
/// the program. Claude Code and Codex don't read ⌘V: both paste the clipboard's image on
/// ⌃V. So a paste with only an image to give, in a terminal running one of them, sends
/// the agent ⌃V, and it reads the image off the clipboard itself.
///
/// A paste of text, and a paste into anything else, is left as it was.
@MainActor
enum AgentImagePaste {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
    ]

    /// `pasteboard` has an image and nothing a paste would type.
    static func hasOnlyImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.availableType(from: imageTypes) != nil
            && pasteboard.ghosttyData(forMime: "text/plain") == nil
    }

    /// Process `pid`, the foreground process of a terminal, is an agent. Claude Code
    /// registers its process; Codex installed with npm runs under a node wrapper.
    nonisolated static func isAgent(pid: Int) -> Bool {
        if ClaudeCodeSession.directory(ofRunning: pid) != nil { return true }
        guard let pid = pid_t(exactly: pid), pid > 0 else { return false }
        return ([pid] + RunningProcess.children(pid)).contains {
            RunningProcess.name($0)?.hasPrefix(CodingAgent.codex.command) ?? false
        }
    }

    /// `event` is the key bound to paste.
    static func isPaste(_ event: NSEvent, config: Ghostty.Config) -> Bool {
        typealias Key = Ghostty.MenuShortcutManager.MenuShortcutKey
        guard let shortcut = config.keyboardShortcut(for: "paste_from_clipboard"),
              let binding = Key(shortcut),
              let pressed = Key(event: event) else { return false }
        return binding == pressed
    }

    /// Sends the agent in `view` its image paste key, if the paste key `event` has only
    /// an image to paste there. False when the paste should go on as usual.
    static func perform(for event: NSEvent, in view: Ghostty.SurfaceView) -> Bool {
        guard let config = (NSApp.delegate as? AppDelegate)?.ghostty.config,
              isPaste(event, config: config) else { return false }
        return perform(in: view)
    }

    /// Sends the agent in `view` its image paste key, if a paste has only an image to
    /// paste there. False when the paste should go on as usual.
    static func perform(in view: Ghostty.SurfaceView, pasteboard: NSPasteboard = .general) -> Bool {
        guard let surface = view.surfaceModel,
              hasOnlyImage(pasteboard),
              let pid = surface.foregroundPID,
              isAgent(pid: pid) else { return false }
        surface.sendKeyEvent(.init(key: .v, mods: .ctrl, unshiftedCodepoint: UInt32(("v" as Unicode.Scalar).value)))
        return true
    }
}

import AppKit

/// The commands Maggie's Claude Code plugin ships (`ClaudePlugin`), in the View menu
/// after Show Usage — View > Force Multiplier — so they can be found without knowing to
/// type `/`. An item runs its command in the focused terminal's Claude Code session, and
/// is greyed out when that terminal isn't running Claude Code.
@MainActor
final class ClaudePluginMenu: NSObject, NSMenuItemValidation {
    static let shared = ClaudePluginMenu()

    /// Adds an item per command to the View menu, after Show Usage (or at its end).
    /// Nothing when the build ships no plugin commands.
    func install() {
        let commands = ClaudePlugin.commands
        guard !commands.isEmpty,
              let view = NSApp.mainMenu?.items.first(where: { $0.submenu?.title == "View" })?.submenu,
              !view.items.contains(where: { $0.action == #selector(run(_:)) }) else { return }

        let usage = view.items.firstIndex { $0.action == #selector(TerminalController.toggleUsage(_:)) }
        var index = usage.map { $0 + 1 } ?? view.items.count
        for command in commands {
            let item = NSMenuItem(title: command.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.name
            item.toolTip = "\(command.slashCommand) — \(command.description)"
            item.setImageIfDesired(systemSymbolName: Self.symbol(for: command))
            view.insertItem(item, at: index)
            index += 1
        }
    }

    /// The SF Symbol beside a command's item.
    static func symbol(for command: ClaudePlugin.Command) -> String {
        switch command.name {
        case "force-multiplier": return "chart.bar.xaxis"
        default: return "sparkles"
        }
    }

    /// The focused terminal of the key window.
    private var focusedSurface: Ghostty.SurfaceView? {
        (NSApp.keyWindow?.windowController as? BaseTerminalController)?.focusedSurface
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(run(_:)) else { return true }
        return ClaudePlugin.canRun(in: focusedSurface)
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let command = ClaudePlugin.commands.first(where: { $0.name == name }),
              let surface = focusedSurface, ClaudePlugin.canRun(in: surface) else { return }
        ClaudePlugin.run(command, in: surface)
    }
}

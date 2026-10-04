import AppKit

/// The Claude menu, between View and Window: one item per command Maggie's Claude Code
/// plugin ships (`ClaudePlugin`), so they can be found without knowing to type `/`. An
/// item runs its command in the focused terminal's Claude Code session, and is greyed
/// out when that terminal isn't running Claude Code.
@MainActor
final class ClaudePluginMenu: NSObject, NSMenuItemValidation {
    static let shared = ClaudePluginMenu()

    static let title = "Claude"

    /// Adds the menu to the main menu, before the Window menu. Nothing when the build
    /// ships no plugin commands.
    func install() {
        let commands = ClaudePlugin.commands
        guard !commands.isEmpty, let mainMenu = NSApp.mainMenu,
              !mainMenu.items.contains(where: { $0.submenu?.title == Self.title }) else { return }

        let menu = NSMenu(title: Self.title)
        for command in commands {
            let item = NSMenuItem(title: command.title, action: #selector(run(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command.name
            item.toolTip = "\(command.slashCommand) — \(command.description)"
            item.setImageIfDesired(systemSymbolName: Self.symbol(for: command))
            menu.addItem(item)
        }

        let top = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        top.submenu = menu
        let window = mainMenu.items.firstIndex { $0.submenu?.title == "Window" } ?? mainMenu.items.count
        mainMenu.insertItem(top, at: window)
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

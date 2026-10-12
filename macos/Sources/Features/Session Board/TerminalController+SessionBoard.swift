import AppKit

extension TerminalController {
    /// Shows the session board over the terminal, or hides it.
    @IBAction func toggleSessionBoard(_ sender: Any?) {
        guard let window = window as? TerminalWindow, window.supportsTabSidebar else { return }
        window.tabSidebarModel.isBoardOpen.toggle()
    }
}

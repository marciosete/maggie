import AppKit

/// What a device can ask the Mac to do with its sessions, done the way the sidebar does.
@MainActor
enum RemoteCommands {
    /// Opens a session in a folder, as the folder's New Session does, so the agent starts
    /// in it as in any new tab. Only folders holding a git checkout take one.
    static func newSession(folderID: String, feed: RemoteSessionFeed) -> Result<SessionCreated, RemoteError> {
        guard let uuid = UUID(uuidString: folderID), let folder = UserTabFolderStore.shared[uuid] else {
            return .failure(RemoteError(code: .notFound, message: "That folder is no longer open on the Mac."))
        }
        guard Git.checkout(of: folder.url) != nil else {
            return .failure(RemoteError(code: .badRequest, message: "No git repository in \(folder.abbreviatedPath)."))
        }

        // The tab group the folder is open in, or else any.
        let windows = NSApp.windows.compactMap { $0 as? TerminalWindow }
        guard let host = windows.first(where: { $0.folderSpace.folderIDs.contains(uuid) }) ?? windows.first else {
            return .failure(RemoteError(code: .internal, message: "The Mac has no window to open a session in."))
        }
        guard let window = host.tabSidebarModel.newTab(inFolder: uuid) else {
            return .failure(RemoteError(code: .internal, message: "The Mac could not open a session."))
        }
        feed.setNeedsUpdate()
        return .success(SessionCreated(id: feed.ids.id(for: window), folderID: folderID))
    }

    /// Brings the session's tab to the front on the Mac.
    static func focus(sessionID: String, feed: RemoteSessionFeed) -> Bool {
        guard let window = feed.ids.window(for: sessionID) else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Closes the session's tab. Like the Mac's close button, it won't close one with a
    /// process running without asking, so the device asks and sends `force`.
    static func close(sessionID: String, force: Bool, feed: RemoteSessionFeed) -> SessionClosed.Reason {
        guard let window = feed.ids.window(for: sessionID), let controller = window.terminalController else {
            return .notFound
        }
        if !force, controller.surfaceTree.contains(where: { $0.needsConfirmQuit }) {
            return .processRunning
        }
        controller.closeTabImmediately()
        feed.setNeedsUpdate()
        return .closed
    }
}

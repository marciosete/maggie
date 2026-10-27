import AppKit

extension TerminalRestorableState {
    /// Internal State we use to perform unit tests
    ///
    /// Since we can't really change the type of `TerminalRestorableState`
    /// due to `CodableBridge<TerminalRestorableState>` supporting secure coding,
    /// we use an internal type to perform migration and tests
    struct InternalState<ViewType: NSView & Codable & Identifiable>: Codable {
        // MARK: - Version 5 (1.2.3)
        let focusedSurface: String?
        let surfaceTree: SplitTree<ViewType>

        // MARK: - Version 7 (1.3.0)
        let effectiveFullscreenMode: FullscreenMode?
        let tabColor: TerminalTabColor?
        let titleOverride: String?

        // MARK: - Tab sidebar
        // Optional, so state saved without it still decodes.
        let userTabGroup: UserTabGroup?

        // MARK: - Speech
        // The ElevenLabs voice picked for the session. Optional, like the group.
        let speechVoiceID: String?

        // MARK: - Folders
        // The tab's folder, and every folder open in its sidebar, so a folder with no
        // sessions comes back too. Optional, like the group.
        let userTabFolder: UserTabFolder?
        let sidebarFolders: [UserTabFolder]?

        // The folder groups those folders were in, from before a group could hold
        // folders; they come back as groups. Optional, like the folders, and no longer
        // written: `sidebarGroups` carries the groups now.
        let sidebarFolderGroups: [UserTabFolderGroup]?

        // MARK: - Session board
        // The session's column and place on the board. Optional, like the folders.
        var boardPlace: SessionBoardPlace?

        // The work item the session is linked to. Optional, like the place.
        var workItemID: UUID?

        // MARK: - Window
        // The name of the window the tab is in. Optional, like the folders.
        var windowName: String?

        // The id of the window the tab is in. Optional, like the name.
        var windowID: UUID?

        // MARK: - Nested groups
        // The groups the tab's group is in, outermost first, and the groups the sidebar's
        // folders are in, so a group of groups and a group of folders come back whole.
        // Optional, like the group; state saved before groups nested has none.
        var sidebarGroups: [UserTabGroup]?
    }
}

extension TerminalRestorableState.InternalState where ViewType == Ghostty.SurfaceView {
    init(from controller: TerminalController) {
        let window = controller.window as? TerminalWindow
        let folders = UserTabFolderStore.shared
        let sidebarFolders = window.map { $0.folderSpace.folderIDs.compactMap { folders[$0] } }

        // The groups the tab's group is in, and every folder's group with the groups that
        // is in, so a group of groups and a group of folders come back whole.
        let groups = UserTabGroupStore.shared
        var groupIDs = groups.path(of: window?.userTabGroupID).dropLast().map { $0 }
        for folder in sidebarFolders ?? [] {
            for groupID in groups.path(of: folder.groupID) where !groupIDs.contains(groupID) {
                groupIDs.append(groupID)
            }
        }
        self.init(
            focusedSurface: controller.focusedSurface?.id.uuidString,
            surfaceTree: controller.surfaceTree,
            effectiveFullscreenMode: controller.fullscreenStyle?.fullscreenMode,
            tabColor: window?.tabColor,
            titleOverride: controller.titleOverride,
            userTabGroup: UserTabGroupStore.shared[window?.userTabGroupID],
            speechVoiceID: window?.speechVoiceID,
            userTabFolder: folders[window?.userTabFolderID],
            sidebarFolders: sidebarFolders,
            sidebarFolderGroups: nil,
            boardPlace: window?.boardPlace,
            workItemID: window?.workItemID,
            windowName: window?.folderSpace.name,
            windowID: window?.folderSpace.id,
            sidebarGroups: groupIDs.compactMap { groups[$0] },
        )
    }
}

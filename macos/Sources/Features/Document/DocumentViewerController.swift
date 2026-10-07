import AppKit

/// A window of its own for a Markdown file, for windows that have no pane to show
/// it in beside the session, and for a document popped out of that pane. It reads
/// the file rendered, or edits it as text.
@MainActor
final class DocumentViewerController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    /// The windows open, by the file each shows.
    private static var open: [URL: DocumentViewerController] = [:]
    private static var cascadePoint = NSPoint.zero

    /// Shows `file`, in the window already showing it when there is one.
    static func show(_ file: URL) {
        let key = file.standardizedFileURL
        let controller = open[key] ?? DocumentViewerController(file: key)
        open[key] = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    let file: URL
    private let documentView: DocumentWebView
    private var editorView: DocumentEditorView?
    private var isEditing = false

    private init(file: URL) {
        self.file = file
        documentView = DocumentWebView(file: file)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = file.lastPathComponent
        window.subtitle = (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        window.representedURL = file
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 360, height: 240)
        window.contentView = documentView
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)

        super.init(window: window)
        window.delegate = self
        documentView.onOpenDocument = { Self.show($0) }

        let toolbar = NSToolbar(identifier: "MaggieDocumentViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Toolbar

    private static let editItem = NSToolbarItem.Identifier("edit")
    private static let openInAppItem = NSToolbarItem.Identifier("openInApp")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.editItem, Self.openInAppItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self
        item.isBordered = true
        switch itemIdentifier {
        case Self.editItem:
            item.label = "Edit"
            item.toolTip = "Edit this file as text"
            item.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: "Edit")
            item.action = #selector(toggleEditing(_:))
        case Self.openInAppItem:
            item.label = "Open in Default App"
            item.toolTip = "Open this file in its default app"
            item.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: "Open in Default App")
            item.action = #selector(openInEditor(_:))
        default:
            return nil
        }
        return item
    }

    @objc func openInEditor(_ sender: Any?) {
        DocumentWebView.openInEditor(file)
    }

    /// Switches between the rendered document and the text to edit.
    @objc func toggleEditing(_ sender: Any?) {
        guard let window else { return }
        isEditing.toggle()
        if isEditing {
            let editor = DocumentEditorView(file: file)
            editorView = editor
            window.contentView = editor
        } else {
            editorView?.save()
            editorView = nil
            window.contentView = documentView
        }
        if let item = window.toolbar?.items.first(where: { $0.itemIdentifier == Self.editItem }) {
            item.image = NSImage(
                systemSymbolName: isEditing ? "checkmark" : "pencil",
                accessibilityDescription: isEditing ? "Done" : "Edit")
            item.label = isEditing ? "Done" : "Edit"
            item.toolTip = isEditing ? "Show the rendered document" : "Edit this file as text"
        }
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        editorView?.save()
        Self.open[file] = nil
    }

    @IBAction func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any?) {
        window?.performClose(sender)
    }
}

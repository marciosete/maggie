import AppKit
import SwiftUI

/// A Markdown file as text to edit. Edits save themselves shortly after typing
/// stops, and ⌘S saves at once. While there is nothing unsaved, a change to the
/// file on disk, as when an agent writes it, is picked up.
@MainActor
final class DocumentEditorView: NSView, NSTextViewDelegate {
    let file: URL

    private let scrollView = NSScrollView()
    private let textView: EditorTextView
    private var watcher: FileChangeWatcher?
    /// The text as last read from or written to the file.
    private var savedText = ""
    private var pendingSave: DispatchWorkItem?

    /// How long after typing stops the file is written.
    static let saveDelay: TimeInterval = 0.6

    init(file: URL) {
        self.file = file
        textView = EditorTextView()
        super.init(frame: .zero)

        textView.delegate = self
        textView.onSave = { [weak self] in self?.save() }
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        load()
        watcher = FileChangeWatcher(path: file.path) { [weak self] in self?.fileChanged() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { window?.makeFirstResponder(textView) }
    }

    var hasUnsavedChanges: Bool { textView.string != savedText }

    private func load() {
        let data = (try? Data(contentsOf: file)) ?? Data()
        savedText = String(decoding: data, as: UTF8.self)
        textView.string = savedText
        textView.undoManager?.removeAllActions()
    }

    /// Reloads the file after a change on disk, unless there are edits here
    /// that would be lost.
    private func fileChanged() {
        guard !hasUnsavedChanges else { return }
        let selection = textView.selectedRange()
        load()
        let end = (textView.string as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, end), length: 0))
    }

    func textDidChange(_ notification: Notification) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    /// Writes the text to the file now.
    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        let text = textView.string
        guard text != savedText else { return }
        do {
            try text.write(to: file, atomically: true, encoding: .utf8)
            savedText = text
        } catch {
            NSSound.beep()
        }
    }

    /// The text view, with ⌘S for saving.
    private final class EditorTextView: NSTextView {
        var onSave: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "s" {
                onSave?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// `DocumentEditorView` for SwiftUI.
struct DocumentEditorRepresentable: NSViewRepresentable {
    let file: URL

    func makeNSView(context: Context) -> DocumentEditorView {
        DocumentEditorView(file: file)
    }

    func updateNSView(_ view: DocumentEditorView, context: Context) {}

    /// Edits still waiting to be written are written when the editor goes away.
    static func dismantleNSView(_ view: DocumentEditorView, coordinator: ()) {
        MainActor.assumeIsolated { view.save() }
    }
}

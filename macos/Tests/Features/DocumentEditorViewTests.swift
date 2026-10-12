import AppKit
import Testing
@testable import Ghostty

@Suite
struct DocumentEditorViewTests {
    private func temporaryFile(_ contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maggie-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.md")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func textView(of editor: DocumentEditorView) -> NSTextView? {
        editor.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? NSTextView }.first
    }

    /// Gives a windowless text view an undo manager while forwarding edits to
    /// the editor as its usual delegate does.
    @MainActor
    private final class UndoDelegate: NSObject, NSTextViewDelegate {
        let manager = UndoManager()
        let editor: DocumentEditorView

        init(editor: DocumentEditorView) {
            self.editor = editor
        }

        func undoManager(for view: NSTextView) -> UndoManager? { manager }

        func textDidChange(_ notification: Notification) {
            editor.textDidChange(notification)
        }
    }

    @Test @MainActor func showsTheFileAndSavesEdits() throws {
        let file = try temporaryFile("# Notes\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let editor = DocumentEditorView(file: file)
        let text = try #require(textView(of: editor))
        #expect(text.string == "# Notes\n")
        #expect(!editor.hasUnsavedChanges)

        text.string = "# Notes\n\nMore.\n"
        #expect(editor.hasUnsavedChanges)
        editor.save()
        #expect(!editor.hasUnsavedChanges)
        #expect(try String(contentsOf: file, encoding: .utf8) == "# Notes\n\nMore.\n")
    }

    @Test @MainActor func typingSavesByItself() async throws {
        let file = try temporaryFile("one\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let editor = DocumentEditorView(file: file)
        let text = try #require(textView(of: editor))
        text.string = "two\n"
        text.didChangeText()
        try await Task.sleep(for: .seconds(DocumentEditorView.saveDelay + 0.4))
        #expect(try String(contentsOf: file, encoding: .utf8) == "two\n")
    }

    @Test(arguments: [true, false])
    @MainActor func savingPreservesUndoAndSelection(autosave: Bool) async throws {
        let file = try temporaryFile("original\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let editor = DocumentEditorView(file: file)
        let text = try #require(textView(of: editor))
        let delegate = UndoDelegate(editor: editor)
        text.delegate = delegate
        text.insertText("edit ", replacementRange: NSRange(location: 0, length: 0))
        let selection = NSRange(location: 0, length: 4)
        text.setSelectedRange(selection)
        #expect(delegate.manager.canUndo)

        if !autosave { editor.save() }
        try await Task.sleep(for: .seconds(DocumentEditorView.saveDelay + 0.7))
        #expect(try String(contentsOf: file, encoding: .utf8) == "edit original\n")
        #expect(!editor.hasUnsavedChanges)
        #expect(text.selectedRange() == selection)
        #expect(delegate.manager.canUndo)

        delegate.manager.undo()
        #expect(text.string == "original\n")
        // Calling the undo manager directly bypasses the text view's edit notification.
        text.didChangeText()
        if !autosave { editor.save() }
        try await Task.sleep(for: .seconds(DocumentEditorView.saveDelay + 0.7))
        #expect(try String(contentsOf: file, encoding: .utf8) == "original\n")
        #expect(delegate.manager.canRedo)
        delegate.manager.redo()
        #expect(text.string == "edit original\n")
    }

    @Test @MainActor func aChangeOnDiskShowsWhenNothingIsUnsaved() async throws {
        let file = try temporaryFile("first\n")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        let editor = DocumentEditorView(file: file)
        let text = try #require(textView(of: editor))
        try "second\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(0.8))
        #expect(text.string == "second\n")

        // Edits here win over a later change on disk.
        text.string = "mine\n"
        try "theirs\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(0.8))
        #expect(text.string == "mine\n")
    }
}

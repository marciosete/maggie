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

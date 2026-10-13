import Foundation
import Testing
@testable import Ghostty

@Suite
struct DocumentLinkTests {
    private let home = "/Users/me"
    private let project = "/Users/me/projects/maggie"

    /// The files on disk, for the resolver to check against.
    private func resolve(_ text: String, pwd: String? = "/Users/me/projects/maggie", files: Set<String>) -> String? {
        DocumentLink.markdownFile(in: text, relativeTo: pwd, home: home, isFile: { files.contains($0) })?.path
    }

    /// `claude -w` writes in a worktree while the shell stays in the checkout, so a
    /// path it names is found from the agent's directory too.
    @Test func aRelativePathIsAlsoTakenFromTheAgentsDirectory() {
        let worktree = "\(project)/.claude/worktrees/brave-otter"
        let report = "\(worktree)/docs/review.md"
        let found = DocumentLink.markdownFile(
            in: "docs/review.md", relativeTo: [project, worktree], home: home, isFile: { $0 == report })
        #expect(found?.path == report)

        // The terminal's own directory wins when both have the file.
        let own = "\(project)/docs/review.md"
        let first = DocumentLink.markdownFile(
            in: "docs/review.md", relativeTo: [project, worktree], home: home, isFile: { $0 == own || $0 == report })
        #expect(first?.path == own)

        #expect(DocumentLink.markdownFile(in: "/tmp/notes.md", relativeTo: [], home: home, isFile: { $0 == "/tmp/notes.md" })?.path
            == "/tmp/notes.md")
    }

    /// An agent may name `timesheets/2026-09-25.md` for `docs/timesheets/2026-09-25.md`.
    @Test func thePathsEndFindsTheOneFileItNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("doc-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("# Note\n".utf8).write(to: url)
        }
        try write("docs/timesheets/2026-09-25.md")
        try write(".claude/worktrees/other/docs/timesheets/2026-09-25.md")
        try write("node_modules/pkg/README.md")
        try write("a/notes.md")
        try write("b/notes.md")

        let found = DocumentLink.markdownFile(endingWith: "timesheets/2026-09-25.md", under: root.path)
        #expect(found?.standardizedFileURL.path == root.appendingPathComponent("docs/timesheets/2026-09-25.md").standardizedFileURL.path)
        #expect(DocumentLink.markdownFile(endingWith: "./timesheets/2026-09-25.md", under: root.path) != nil)

        // Two files end with it: nothing to choose between.
        #expect(DocumentLink.markdownFile(endingWith: "notes.md", under: root.path) == nil)
        // Dependencies aren't searched, nor is anything but a relative Markdown path.
        #expect(DocumentLink.markdownFile(endingWith: "pkg/README.md", under: root.path) == nil)
        #expect(DocumentLink.markdownFile(endingWith: "/docs/timesheets/2026-09-25.md", under: root.path) == nil)
        #expect(DocumentLink.markdownFile(endingWith: "timesheets/2026-09-25.txt", under: root.path) == nil)
    }

    @Test func aRelativeMarkdownPathIsKnown() {
        #expect(DocumentLink.isRelativeMarkdownPath("timesheets/2026-09-25.md"))
        #expect(!DocumentLink.isRelativeMarkdownPath("/tmp/a.md"))
        #expect(!DocumentLink.isRelativeMarkdownPath("~/a.md"))
        #expect(!DocumentLink.isRelativeMarkdownPath("file:///tmp/a.md"))
        #expect(!DocumentLink.isRelativeMarkdownPath("src/main.swift"))
    }

    @Test func aRelativePathIsTakenFromTheTerminalDirectory() {
        let report = "\(project)/docs/artefacts/self-hosted-open-weight-models.md"
        #expect(resolve("docs/artefacts/self-hosted-open-weight-models.md", files: [report]) == report)
        #expect(resolve("./docs/artefacts/self-hosted-open-weight-models.md", files: [report]) == report)
    }

    @Test func anAbsolutePathAndAFileURLAreTakenAsTheyAre() {
        let report = "\(project)/README.md"
        #expect(resolve("\(project)/README.md", pwd: nil, files: [report]) == report)
        #expect(resolve("file://\(project)/README.md", pwd: nil, files: [report]) == report)
        #expect(resolve("\(project)/notes/../README.md", pwd: nil, files: [report]) == report)
    }

    @Test func homeAndVariablesExpand() {
        let notes = "\(home)/Documents/notes.md"
        #expect(resolve("~/Documents/notes.md", files: [notes]) == notes)
        #expect(resolve("$HOME/Documents/notes.md", files: [notes]) == notes)
        #expect(resolve("$PWD/README.md", files: ["\(project)/README.md"]) == "\(project)/README.md")
    }

    @Test func theSentencesPunctuationIsNotPartOfThePath() {
        let report = "\(project)/docs/report.md"
        #expect(resolve("docs/report.md.", files: [report]) == report)
        #expect(resolve("docs/report.md).", files: [report]) == report)
        #expect(resolve("docs/report.md:12", files: [report]) == report)
        #expect(resolve("docs/report.md:12:4", files: [report]) == report)
        #expect(resolve("docs/report.md#results", files: [report]) == report)
        #expect(resolve("docs/report.md\"", files: [report]) == report)
    }

    @Test func aFileThatIsntMarkdownIsLeftToTheSystem() {
        #expect(resolve("src/main.swift", files: ["\(project)/src/main.swift"]) == nil)
        #expect(resolve("https://example.com/readme.md", files: []) == nil)
        #expect(resolve("docs/", files: ["\(project)/docs/"]) == nil)
    }

    @Test func aFileThatIsntThereIsLeftToTheSystem() {
        #expect(resolve("docs/report.md", files: []) == nil)
        #expect(resolve("docs/report.md", pwd: nil, files: ["\(project)/docs/report.md"]) == nil)
    }

    @Test func theCandidatesComeLongestFirst() {
        #expect(DocumentLink.candidates("a/b.md:3).") == ["a/b.md:3).", "a/b.md:3)", "a/b.md:3", "a/b.md"])
        #expect(DocumentLink.candidates("a/b.md#x") == ["a/b.md#x", "a/b.md"])
        #expect(DocumentLink.candidates("a/b.md") == ["a/b.md"])
    }
}

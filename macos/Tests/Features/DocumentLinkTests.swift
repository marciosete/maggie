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

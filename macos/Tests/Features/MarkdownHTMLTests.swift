import Foundation
import Testing
@testable import Ghostty

@Suite
struct MarkdownHTMLTests {
    private func html(_ markdown: String) -> String {
        MarkdownHTML.body(markdown: markdown, baseDirectory: nil)
            .replacingOccurrences(of: "\n", with: "")
    }

    @Test func headingsGetAnchorsTheWayGitHubNamesThem() {
        #expect(html("# Self-hosted open-weight models") ==
            "<h1 id=\"self-hosted-open-weight-models\">Self-hosted open-weight models</h1>")
        #expect(html("## Notes\n\n## Notes") ==
            "<h2 id=\"notes\">Notes</h2><h2 id=\"notes-1\">Notes</h2>")
        #expect(html("### A *styled* `heading`") ==
            "<h3 id=\"a-styled-heading\">A <em>styled</em> <code>heading</code></h3>")
    }

    @Test func inlineMarksAndLinks() {
        #expect(html("Some *emph*, **strong**, `code`, ~~gone~~ and a [link](https://example.com/a?b=1&c=2).") ==
            "<p>Some <em>emph</em>, <strong>strong</strong>, <code>code</code>, <s>gone</s> and a " +
            "<a href=\"https://example.com/a?b=1&amp;c=2\">link</a>.</p>")
        // Foundation's parser flattens the styling inside a link's text.
        #expect(html("[**bold** link](x.md)") == "<p><a href=\"x.md\">bold link</a></p>")
    }

    @Test func textIsEscaped() {
        #expect(html("a < b & c > d") == "<p>a &lt; b &amp; c &gt; d</p>")
        #expect(html("```\nif (a < b) { x = \"y\"; }\n```") ==
            "<pre><code>if (a &lt; b) { x = &quot;y&quot;; }</code></pre>")
    }

    @Test func rawHTMLKeepsOnlyBareSafeTags() {
        #expect(html("line<br>break") == "<p>line<br>break</p>")
        #expect(html("<script>alert(1)</script>") == "&lt;script&gt;alert(1)&lt;/script&gt;")
        #expect(html("x <a href=\"javascript:alert(1)\">y</a>") ==
            "<p>x &lt;a href=&quot;javascript:alert(1)&quot;&gt;y&lt;/a&gt;</p>")
        #expect(html("<details>\n<summary>More</summary>\n\ntext\n\n</details>") ==
            "<details><summary>More</summary><p>text</p></details>")
        #expect(html("<img src=x onerror=alert(1)>") == "&lt;img src=x onerror=alert(1)&gt;")
    }

    @Test func listsNestAndNumber() {
        #expect(html("- one\n- two\n  - nested") ==
            "<ul><li><p>one</p></li><li><p>two</p><ul><li><p>nested</p></li></ul></li></ul>")
        #expect(html("3. three\n4. four") ==
            "<ol start=\"3\"><li><p>three</p></li><li><p>four</p></li></ol>")
    }

    @Test func taskItemsBecomeCheckboxes() {
        #expect(html("- [ ] todo\n- [x] done") ==
            "<ul><li><p><input type=\"checkbox\" disabled>todo</p></li>" +
            "<li><p><input type=\"checkbox\" disabled checked>done</p></li></ul>")
    }

    @Test func codeBlocksCarryTheirLanguage() {
        #expect(html("```swift\nlet x = 1\n```") ==
            "<pre><code class=\"language-swift\">let x = 1</code></pre>")
    }

    @Test func quotesAndRules() {
        #expect(html("> said\n\n---\n\nafter") == "<blockquote><p>said</p></blockquote><hr><p>after</p>")
    }

    @Test func tablesHaveHeadersAndAlignment() {
        #expect(html("| Model | Size |\n|:--|--:|\n| Llama | 70B |") ==
            "<table><thead><tr><th>Model</th><th style=\"text-align:right\">Size</th></tr></thead>" +
            "<tbody><tr><td>Llama</td><td style=\"text-align:right\">70B</td></tr></tbody></table>")
    }

    @Test func frontMatterIsNotShown() {
        #expect(html("---\ntitle: Report\n---\n\n# Report") == "<h1 id=\"report\">Report</h1>")
        #expect(MarkdownHTML.strippingFrontMatter("---\nno end") == "---\nno end")
    }

    @Test func aLocalImageIsEmbedded() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maggie-markdown-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.appendingPathComponent("pic.png"))

        let body = MarkdownHTML.body(markdown: "![a picture](pic.png)", baseDirectory: directory)
        #expect(body == "<p><img src=\"data:image/png;base64,iVBORw==\" alt=\"a picture\"></p>\n")

        let remote = MarkdownHTML.body(markdown: "![r](https://example.com/p.png)", baseDirectory: directory)
        #expect(remote == "<p><img src=\"https://example.com/p.png\" alt=\"r\"></p>\n")
    }

    @Test func thePageWrapsTheBody() {
        let page = MarkdownHTML.page(markdown: "# Hi", title: "a <b>.md", baseDirectory: nil)
        #expect(page.contains("<title>a &lt;b&gt;.md</title>"))
        #expect(page.contains("<article>\n<h1 id=\"hi\">Hi</h1>"))
        #expect(page.contains("prefers-color-scheme: dark"))
    }
}

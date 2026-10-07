import Foundation

/// Markdown rendered as HTML for the document viewer.
///
/// Foundation's own Markdown parser (`AttributedString(markdown:)`, cmark underneath)
/// does the parsing, so there is no library to carry. Its runs come tagged with the
/// blocks they sit in, innermost first; this walks them and opens and closes the
/// matching tags as the blocks change.
enum MarkdownHTML {
    /// A whole page: `markdown` rendered, with the viewer's stylesheet and `title`.
    static func page(markdown: String, title: String, baseDirectory: URL?) -> String {
        """
        <!doctype html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>\(stylesheet)</style>
        </head>
        <body>
        <article>
        \(body(markdown: markdown, baseDirectory: baseDirectory))
        </article>
        </body>
        </html>
        """
    }

    /// The blocks of `markdown` as HTML, without a page around them. Images with a
    /// relative path are read from `baseDirectory` and embedded.
    static func body(markdown: String, baseDirectory: URL?) -> String {
        let source = strippingFrontMatter(markdown)
        let attributed: AttributedString
        do {
            attributed = try AttributedString(
                markdown: source,
                options: .init(
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible))
        } catch {
            return "<pre>\(escape(source))</pre>"
        }

        var writer = Writer(baseDirectory: baseDirectory)
        for run in attributed.runs {
            writer.write(run, text: String(attributed[run.range].characters))
        }
        return writer.finish()
    }

    /// `markdown` without a YAML front matter block at its top.
    static func strippingFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---\n") || markdown.hasPrefix("---\r\n") else { return markdown }
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)
        guard let end = lines.dropFirst().firstIndex(where: { $0 == "---" || $0 == "---\r" }) else {
            return markdown
        }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    /// The id a heading reading `text` gets, GitHub's way: lowercase, punctuation
    /// dropped, spaces as hyphens.
    static func headingID(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        for scalar in lowered.unicodeScalars {
            if scalar == " " || scalar == "-" {
                slug.append("-")
            } else if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                slug.unicodeScalars.append(scalar)
            }
        }
        return slug
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    /// Tags that raw HTML in the Markdown may keep. They carry no attributes, so
    /// nothing in them can run or fetch; everything else is shown as text.
    static let allowedRawTags: Set<String> = [
        "b", "blockquote", "br", "code", "dd", "del", "details", "div", "dl", "dt", "em",
        "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "ins", "kbd", "li", "ol", "p",
        "pre", "s", "small", "span", "strong", "sub", "summary", "sup", "table", "tbody",
        "td", "th", "thead", "tr", "u", "ul",
    ]

    /// `raw`, with its allowed bare tags kept and everything else escaped.
    static func sanitizeRawHTML(_ raw: String) -> String {
        var out = ""
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<") {
            out += escape(String(rest[..<open]))
            guard let close = rest[open...].firstIndex(of: ">") else {
                out += escape(String(rest[open...]))
                return out
            }
            let tag = String(rest[open...close])
            out += isAllowedRawTag(tag) ? tag : escape(tag)
            rest = rest[rest.index(after: close)...]
        }
        out += escape(String(rest))
        return out
    }

    private static func isAllowedRawTag(_ tag: String) -> Bool {
        var inner = tag.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        if inner.hasPrefix("/") { inner = String(inner.dropFirst()) }
        if inner.hasSuffix("/") { inner = String(inner.dropLast()) }
        let name = inner.trimmingCharacters(in: .whitespaces).lowercased()
        return allowedRawTags.contains(name)
    }

    /// `url` as the `src` of an image: a local file embedded as data, so the page
    /// needs no file access, or the URL itself when it is remote.
    static func imageSource(_ url: URL, baseDirectory: URL?) -> String {
        if let scheme = url.scheme, scheme != "file" {
            return url.absoluteString
        }
        let file: URL
        if url.isFileURL {
            file = url
        } else if let directory = baseDirectory,
                  let resolved = URL(string: url.relativeString, relativeTo: URL(filePath: directory.path, directoryHint: .isDirectory)) {
            file = resolved.absoluteURL
        } else {
            return url.absoluteString
        }
        guard let data = try? Data(contentsOf: file), data.count <= 16 * 1024 * 1024 else {
            return url.absoluteString
        }
        let type: String
        switch file.pathExtension.lowercased() {
        case "png": type = "image/png"
        case "jpg", "jpeg": type = "image/jpeg"
        case "gif": type = "image/gif"
        case "svg": type = "image/svg+xml"
        case "webp": type = "image/webp"
        default: return url.absoluteString
        }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    // MARK: - Writer

    /// Turns the parser's runs into HTML, one at a time.
    private struct Writer {
        let baseDirectory: URL?

        /// Finished HTML, outside any heading.
        private var html = ""
        /// The blocks open right now, outermost first.
        private var open: [PresentationIntent.IntentType] = []
        /// The heading being collected, if one is open: its HTML and plain text.
        private var heading: (html: String, text: String)?
        private var headingIDs: [String: Int] = [:]
        /// The link an `<a>` is open for.
        private var link: URL?
        /// The columns of the table being written.
        private var columns: [PresentationIntent.TableColumn] = []
        private var inTableHeader = false
        private var inTableBody = false
        /// A list item has opened and its first text hasn't been seen yet, where a
        /// task checkbox would be.
        private var listItemStarting = false

        init(baseDirectory: URL?) {
            self.baseDirectory = baseDirectory
        }

        mutating func write(_ run: AttributedString.Runs.Run, text: String) {
            let blocks = Array((run.presentationIntent?.components ?? []).reversed())
            var shared = 0
            while shared < open.count, shared < blocks.count, open[shared].identity == blocks[shared].identity {
                shared += 1
            }
            if shared < open.count || shared < blocks.count { closeLink() }
            while open.count > shared { close(open.removeLast()) }
            for index in shared..<blocks.count {
                openTag(blocks[index], inner: blocks[(index + 1)...].first)
                open.append(blocks[index])
            }

            // Raw HTML blocks come without a block of their own.
            guard let kind = open.last?.kind else {
                let inline = run.inlinePresentationIntent ?? []
                if inline.contains(.blockHTML) || inline.contains(.inlineHTML) {
                    emit(MarkdownHTML.sanitizeRawHTML(text))
                } else {
                    emit(MarkdownHTML.escape(text))
                }
                return
            }
            switch kind {
            case .thematicBreak:
                return
            case .codeBlock:
                emit(MarkdownHTML.escape(text.hasSuffix("\n") ? String(text.dropLast()) : text))
                return
            default:
                break
            }

            if run.link != link {
                closeLink()
                if let url = run.link {
                    emit("<a href=\"\(MarkdownHTML.escape(url.absoluteString))\">")
                    link = url
                }
            }

            if let image = run.imageURL {
                let source = MarkdownHTML.imageSource(image, baseDirectory: baseDirectory)
                emit("<img src=\"\(MarkdownHTML.escape(source))\" alt=\"\(MarkdownHTML.escape(text))\">")
                return
            }

            var content = text
            if listItemStarting {
                listItemStarting = false
                if let box = taskBox(&content) { emit(box) }
            }

            let inline = run.inlinePresentationIntent ?? []
            if inline.contains(.lineBreak) {
                emit("<br>")
                return
            }
            if inline.contains(.softBreak) {
                emit("\n")
                return
            }
            if inline.contains(.inlineHTML) || inline.contains(.blockHTML) {
                emit(MarkdownHTML.sanitizeRawHTML(content))
                return
            }

            var opening = ""
            var closing = ""
            if inline.contains(.code) { opening += "<code>"; closing = "</code>" + closing }
            if inline.contains(.stronglyEmphasized) { opening += "<strong>"; closing = "</strong>" + closing }
            if inline.contains(.emphasized) { opening += "<em>"; closing = "</em>" + closing }
            if inline.contains(.strikethrough) { opening += "<s>"; closing = "</s>" + closing }
            emit(opening + MarkdownHTML.escape(content) + closing)
            heading?.text += content
        }

        mutating func finish() -> String {
            closeLink()
            while let block = open.popLast() { close(block) }
            return html
        }

        private mutating func emit(_ fragment: String) {
            if heading != nil {
                heading?.html += fragment
            } else {
                html += fragment
            }
        }

        private mutating func closeLink() {
            guard link != nil else { return }
            emit("</a>")
            link = nil
        }

        /// A checkbox when `content` starts the way a task item does, with the
        /// marker taken off `content`.
        private func taskBox(_ content: inout String) -> String? {
            if content.hasPrefix("[ ] ") {
                content.removeFirst(4)
                return "<input type=\"checkbox\" disabled>"
            }
            if content.hasPrefix("[x] ") || content.hasPrefix("[X] ") {
                content.removeFirst(4)
                return "<input type=\"checkbox\" disabled checked>"
            }
            return nil
        }

        private mutating func openTag(_ block: PresentationIntent.IntentType, inner: PresentationIntent.IntentType?) {
            switch block.kind {
            case .paragraph:
                emit("<p>")
            case .header:
                heading = ("", "")
            case .codeBlock(let language):
                if let language, !language.isEmpty {
                    emit("<pre><code class=\"language-\(MarkdownHTML.escape(language))\">")
                } else {
                    emit("<pre><code>")
                }
            case .blockQuote:
                emit("<blockquote>")
            case .orderedList:
                if case .listItem(let ordinal)? = inner?.kind, ordinal != 1 {
                    emit("<ol start=\"\(ordinal)\">")
                } else {
                    emit("<ol>")
                }
            case .unorderedList:
                emit("<ul>")
            case .listItem:
                emit("<li>")
                listItemStarting = true
            case .table(let tableColumns):
                columns = tableColumns
                inTableBody = false
                emit("<table>")
            case .tableHeaderRow:
                inTableHeader = true
                emit("<thead><tr>")
            case .tableRow:
                if !inTableBody {
                    inTableBody = true
                    emit("<tbody>")
                }
                emit("<tr>")
            case .tableCell(let column):
                let tag = inTableHeader ? "th" : "td"
                switch columns.indices.contains(column) ? columns[column].alignment : .left {
                case .center: emit("<\(tag) style=\"text-align:center\">")
                case .right: emit("<\(tag) style=\"text-align:right\">")
                default: emit("<\(tag)>")
                }
            case .thematicBreak:
                emit("<hr>")
            @unknown default:
                emit("<div>")
            }
        }

        private mutating func close(_ block: PresentationIntent.IntentType) {
            switch block.kind {
            case .paragraph:
                emit("</p>\n")
            case .header(let level):
                guard let collected = heading else { return }
                heading = nil
                let id = uniqueHeadingID(collected.text)
                let tag = "h\(min(max(level, 1), 6))"
                emit("<\(tag) id=\"\(MarkdownHTML.escape(id))\">\(collected.html)</\(tag)>\n")
            case .codeBlock:
                emit("</code></pre>\n")
            case .blockQuote:
                emit("</blockquote>\n")
            case .orderedList:
                emit("</ol>\n")
            case .unorderedList:
                emit("</ul>\n")
            case .listItem:
                listItemStarting = false
                emit("</li>\n")
            case .table:
                if inTableBody { emit("</tbody>") }
                inTableBody = false
                columns = []
                emit("</table>\n")
            case .tableHeaderRow:
                inTableHeader = false
                emit("</tr></thead>")
            case .tableRow:
                emit("</tr>")
            case .tableCell:
                emit(inTableHeader ? "</th>" : "</td>")
            case .thematicBreak:
                emit("\n")
            @unknown default:
                emit("</div>\n")
            }
        }

        private mutating func uniqueHeadingID(_ text: String) -> String {
            let base = MarkdownHTML.headingID(text)
            let seen = headingIDs[base, default: 0]
            headingIDs[base] = seen + 1
            return seen == 0 ? base : "\(base)-\(seen)"
        }
    }

    // MARK: - Stylesheet

    static let stylesheet = """
    :root {
      color-scheme: light dark;
      --bg: #ffffff; --fg: #1d1d1f; --muted: #6e6e73; --rule: #e3e3e8;
      --code-bg: #f4f4f6; --link: #0b63ce; --th-bg: #f7f7f9;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1e1e20; --fg: #e8e8ea; --muted: #9b9ba1; --rule: #39393f;
        --code-bg: #2a2a2e; --link: #78b4ff; --th-bg: #26262a;
      }
    }
    html { background: var(--bg); }
    body {
      margin: 0; background: var(--bg); color: var(--fg);
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
      -webkit-font-smoothing: antialiased; -webkit-text-size-adjust: 100%;
    }
    article { max-width: 760px; margin: 0 auto; padding: 32px 40px 96px; }
    @media (max-width: 640px) { article { padding: 20px 22px 72px; } }
    h1, h2, h3, h4, h5, h6 { font-weight: 650; line-height: 1.25; letter-spacing: -0.01em; }
    h1 { font-size: 2em; margin: 0.4em 0 0.6em; }
    h2 { font-size: 1.5em; margin: 1.5em 0 0.6em; padding-bottom: 0.25em; border-bottom: 1px solid var(--rule); }
    h3 { font-size: 1.2em; margin: 1.4em 0 0.5em; }
    h4, h5, h6 { font-size: 1.05em; margin: 1.2em 0 0.4em; }
    p { margin: 0 0 1em; }
    a { color: var(--link); text-decoration: none; }
    a:hover { text-decoration: underline; }
    code, pre { font-family: ui-monospace, "SF Mono", Menlo, monospace; }
    code { font-size: 0.88em; background: var(--code-bg); padding: 0.12em 0.4em; border-radius: 4px; }
    pre { background: var(--code-bg); padding: 12px 14px; border-radius: 8px; overflow-x: auto; line-height: 1.45; margin: 0 0 1em; }
    pre code { background: none; padding: 0; font-size: 0.85em; }
    blockquote { margin: 0 0 1em; padding: 0.1em 1em; border-left: 3px solid var(--rule); color: var(--muted); }
    blockquote > :last-child { margin-bottom: 0; }
    ul, ol { margin: 0 0 1em; padding-left: 1.6em; }
    li > p { margin: 0.15em 0; }
    li > ul, li > ol { margin-bottom: 0; }
    li:has(> p > input[type=checkbox]) { list-style: none; margin-left: -1.4em; }
    input[type=checkbox] { margin: 0 0.5em 0 0; vertical-align: -1px; }
    table { border-collapse: collapse; margin: 0 0 1em; font-size: 0.94em; display: block; overflow-x: auto; }
    th, td { border: 1px solid var(--rule); padding: 6px 10px; text-align: left; vertical-align: top; }
    th { background: var(--th-bg); font-weight: 600; }
    hr { border: 0; border-top: 1px solid var(--rule); margin: 1.6em 0; }
    img { max-width: 100%; height: auto; }
    """
}

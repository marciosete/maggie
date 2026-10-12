import Foundation

/// A Claude Code transcript, the JSON lines a session or subagent writes, as Markdown to
/// read in the document pane: the prompt, then what the agent said and each tool it ran
/// with a little of what came back. It is read only; the transcript is Claude Code's.
enum ClaudeTranscriptMarkdown {
    /// How much of a tool's result is shown.
    static let resultLineLimit = 12
    static let resultCharacterLimit = 1500

    /// Whether `file` is a transcript, which is shown this way rather than as Markdown.
    static func handles(_ file: URL) -> Bool {
        file.pathExtension == "jsonl"
    }

    static func markdown(fromJSONL text: String, title: String?) -> String {
        var out: [String] = []
        if let title { out.append("# \(title)") }
        var sawPrompt = false

        for line in text.split(whereSeparator: \.isNewline) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String,
                  let message = object["message"] as? [String: Any] else { continue }
            let blocks = contentBlocks(message["content"])

            switch type {
            case "user":
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        guard let text = block["text"] as? String, !text.isEmpty else { continue }
                        out.append(sawPrompt ? "**Message**" : "## Prompt")
                        out.append(quoted(text))
                        sawPrompt = true
                    case "tool_result":
                        let result = resultText(block["content"])
                        guard !result.isEmpty else { continue }
                        let failed = block["is_error"] as? Bool ?? false
                        if failed { out.append("_Failed:_") }
                        out.append(fenced(clipped(result)))
                    default:
                        break
                    }
                }

            case "assistant":
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.isEmpty { out.append(text) }
                    case "tool_use":
                        let name = block["name"] as? String ?? "Tool"
                        let summary = (block["input"] as? [String: Any]).flatMap(inputSummary)
                        out.append("**→ \(name)**" + (summary.map { " " + inlineCode($0) } ?? ""))
                    default:
                        break
                    }
                }

            default:
                break
            }
        }

        if out.count <= (title == nil ? 0 : 1) { out.append("_Nothing in the transcript yet._") }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// A message's content as blocks: a plain string is one text block.
    private static func contentBlocks(_ content: Any?) -> [[String: Any]] {
        if let text = content as? String { return [["type": "text", "text": text]] }
        return content as? [[String: Any]] ?? []
    }

    private static func resultText(_ content: Any?) -> String {
        contentBlocks(content)
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The one input that says what a tool call did: its command, file, pattern…
    static func inputSummary(_ input: [String: Any]) -> String? {
        let keys = ["command", "file_path", "notebook_path", "pattern", "url", "query", "description", "path", "prompt"]
        for key in keys {
            if let value = input[key] as? String, !value.isEmpty {
                return oneLine(value, limit: 160)
            }
        }
        guard !input.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]) else { return nil }
        return oneLine(String(decoding: data, as: UTF8.self), limit: 160)
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let shown = String(line.prefix(limit))
        return shown.count < trimmed.count ? shown + "…" : shown
    }

    private static func clipped(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var more = 0
        if lines.count > resultLineLimit {
            more = lines.count - resultLineLimit
            lines = Array(lines.prefix(resultLineLimit))
        }
        var shown = lines.joined(separator: "\n")
        if shown.count > resultCharacterLimit {
            shown = String(shown.prefix(resultCharacterLimit)) + "…"
        }
        return more > 0 ? shown + "\n… \(more) more lines" : shown
    }

    private static func quoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0 }
            .joined(separator: "\n")
    }

    /// `text` in a code block whose fence nothing in it can close.
    static func fenced(_ text: String) -> String {
        var fence = "```"
        while text.contains(fence) { fence += "`" }
        return "\(fence)\n\(text)\n\(fence)"
    }

    /// `text` as inline code, with a run of backticks longer than any in it.
    static func inlineCode(_ text: String) -> String {
        var ticks = "`"
        while text.contains(ticks) { ticks += "`" }
        let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
        return ticks + pad + text + pad + ticks
    }
}

import Foundation

/// A file path in terminal output that Maggie shows itself, rather than handing
/// to the system opener: a Markdown document, as agents write their reports.
enum DocumentLink {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

    /// The Markdown file that `text`, the link clicked, names, or `nil` when it names
    /// something else or nothing on disk. A relative path is taken from `directory`,
    /// the terminal's working directory. The punctuation that prose leaves after a
    /// path, and a `:line` suffix, are tried without before giving up.
    static func markdownFile(
        in text: String,
        relativeTo directory: String?,
        home: String = NSHomeDirectory(),
        isFile: (String) -> Bool = { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
    ) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path(percentEncoded: false)
        }

        for candidate in candidates(path) {
            guard markdownExtensions.contains((candidate as NSString).pathExtension.lowercased()) else { continue }
            guard let absolute = absolutePath(candidate, directory: directory, home: home) else { continue }
            if isFile(absolute) { return URL(filePath: absolute) }
        }
        return nil
    }

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// `path` and the shorter paths it may really be: without a trailing `:12:3`,
    /// a `#anchor`, and the sentence punctuation around it, in that order.
    static func candidates(_ path: String) -> [String] {
        var seen: [String] = []
        var current = path
        while !current.isEmpty, !seen.contains(current) {
            seen.append(current)
            if let range = current.range(of: #":\d+(:\d+)?$"#, options: .regularExpression) {
                current = String(current[..<range.lowerBound])
            } else if let hash = current.lastIndex(of: "#"), !current[hash...].contains("/") {
                current = String(current[..<hash])
            } else if let last = current.last, ".,;:)]}'\"`>".contains(last) {
                current = String(current.dropLast())
            } else {
                break
            }
        }
        return seen
    }

    /// `path` from the root: `~` and `$HOME` as the home directory, `$PWD` and a
    /// relative path from `directory`.
    static func absolutePath(_ path: String, directory: String?, home: String) -> String? {
        var expanded = path
        if expanded == "~" || expanded.hasPrefix("~/") {
            expanded = home + expanded.dropFirst()
        } else if expanded.hasPrefix("$HOME/") {
            expanded = home + expanded.dropFirst(5)
        } else if expanded.hasPrefix("$PWD/") {
            guard let directory else { return nil }
            expanded = directory + expanded.dropFirst(4)
        }

        if expanded.hasPrefix("/") {
            return (expanded as NSString).standardizingPath
        }
        guard let directory, !directory.isEmpty else { return nil }
        return ((directory as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
    }
}

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
        isFile: (String) -> Bool = DocumentLink.isFile
    ) -> URL? {
        markdownFile(in: text, relativeTo: [directory].compactMap { $0 }, home: home, isFile: isFile)
    }

    /// Like `markdownFile(in:relativeTo:)`, trying a relative path from each of
    /// `directories` in turn. A terminal's own directory is its shell's, while the
    /// agent in it works elsewhere: `claude -w` runs in a worktree of the checkout the
    /// shell is in, and names the files it writes from there.
    static func markdownFile(
        in text: String,
        relativeTo directories: [String],
        home: String = NSHomeDirectory(),
        isFile: (String) -> Bool = DocumentLink.isFile
    ) -> URL? {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.lowercased().hasPrefix("file://"), let url = URL(string: path), url.isFileURL {
            path = url.path(percentEncoded: false)
        }

        // Without a directory, only an absolute path can be found.
        let bases: [String?] = directories.isEmpty ? [nil] : directories.map { $0 }
        for candidate in candidates(path) {
            guard markdownExtensions.contains((candidate as NSString).pathExtension.lowercased()) else { continue }
            for base in bases {
                guard let absolute = absolutePath(candidate, directory: base, home: home) else { continue }
                if isFile(absolute) { return URL(filePath: absolute) }
            }
        }
        return nil
    }

    /// The one Markdown file under `directory` whose path ends with `relative`, as
    /// `timesheets/2026-09-25.md` names `docs/timesheets/2026-09-25.md` when an agent
    /// names a file from a folder it was talking about, or the link caught only the
    /// path's end. Nil when there is none, or more than one to choose between. The
    /// search stays small: it skips hidden folders, such as `.git` and other
    /// worktrees in `.claude`, and dependencies, and gives up after a few levels.
    static func markdownFile(endingWith relative: String, under directory: String, maxDepth: Int = 5) -> URL? {
        var path = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        while path.hasPrefix("./") { path.removeFirst(2) }
        guard isRelativeMarkdownPath(path) else { return nil }

        let root = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return nil }
        let suffix = "/" + path
        var found: URL?
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 20_000 { return nil }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                if walker.level >= maxDepth || skippedFolders.contains(url.lastPathComponent) { walker.skipDescendants() }
                continue
            }
            guard url.path.hasSuffix(suffix) else { continue }
            if found != nil { return nil }
            found = url
        }
        return found
    }

    /// Folders the search for a path's end doesn't go into: what tools put there,
    /// not what an agent names.
    static let skippedFolders: Set<String> = ["node_modules", "build", "zig-out", "DerivedData", "Pods", "vendor", "target"]

    /// `path` is a Markdown file's path from some directory: not absolute, from home
    /// or from a variable.
    static func isRelativeMarkdownPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.hasPrefix("$"),
              !path.lowercased().hasPrefix("file:") else { return false }
        return markdownExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    static func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
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

import Foundation

/// One thing said in the voice conversation, by the user, by the voice, or by Maggie
/// (a notice about a session, or what a tool did).
struct VoiceTurn: Equatable, Identifiable, Codable {
    enum Role: String, Codable {
        case user
        case assistant
        case notice
        case tool
    }

    let id: UUID
    let role: Role
    let text: String
    let at: Date

    init(id: UUID = UUID(), role: Role, text: String, at: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }
}

/// The bookkeeping of a GPT-Live conversation, kept pure so it can be tested without a
/// socket (after the harness's `LiveCallLedger`): transcript fragments gathered into
/// turns, and the session's billed seconds.
///
/// GPT-Live transcripts arrive as fragments with no turn boundaries, so a turn is what
/// came in before a pause.
struct VoiceLedger: Equatable {
    private(set) var pendingUser = ""
    private(set) var pendingAssistant = ""

    /// `usage.seconds` is cumulative: the latest figure is the running total.
    private(set) var billedSeconds: Double = 0

    mutating func input(_ delta: String) {
        pendingUser += delta
    }

    mutating func output(_ delta: String) {
        pendingAssistant += delta
    }

    /// The user's words since the last flush, now a spoken turn; empty if none.
    mutating func flushUser() -> String {
        let text = pendingUser.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingUser = ""
        return text
    }

    mutating func flushAssistant() -> String {
        let text = pendingAssistant.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAssistant = ""
        return text
    }

    mutating func usage(seconds: Double) {
        if seconds.isFinite, seconds > billedSeconds { billedSeconds = seconds }
    }
}

/// Text made sayable, and cut to what GPT-Live takes in one append.
enum VoiceSpeech {
    /// GPT-Live's cap is 500 tokens per append; about three characters a token keeps
    /// well inside it.
    static let appendCharacters = 1_400

    /// An answer longer than this is a document, not something to say.
    static let maxAppends = 3

    static let truncatedNote = "There is more; ask for the rest if you want it."

    /// Markdown made sayable: no code, no markup, links as their words. The voice
    /// paraphrases what it is given, so this only has to stop it reading punctuation
    /// aloud.
    static func speakable(_ markdown: String) -> String {
        let text = markdown
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: " (there is code here) ", options: .regularExpression)
            .replacingOccurrences(of: #"!\[[^\n\]]{0,200}\]\([^\s)]{0,1000}\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\n\]]{1,200})\]\([^\s)]{0,1000}\)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"`([^\n`]{1,200})`"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"(\*\*|__)([^\n]{1,400}?)\1"#, with: "$2", options: .regularExpression)
            .replacingOccurrences(of: "|", with: " ")
        return text
            .components(separatedBy: "\n")
            .map(plainLine)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// One line without its heading or bullet marker, spaces collapsed.
    private static func plainLine(_ line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        while rest.hasPrefix("#") { rest = rest.dropFirst() }
        for marker in ["- ", "* ", "+ "] where rest.hasPrefix(marker) {
            rest = rest.dropFirst(2)
        }
        return rest.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// `text` as appends GPT-Live accepts, cut at sentence ends, capped.
    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while !rest.isEmpty, chunks.count < maxAppends {
            let (head, tail) = cut(rest)
            chunks.append(head)
            rest = tail
        }
        if !rest.isEmpty, !chunks.isEmpty {
            chunks[chunks.count - 1] += " \(truncatedNote)"
        }
        return chunks
    }

    private static func cut(_ text: String) -> (String, String) {
        guard text.count > appendCharacters else { return (text, "") }
        let window = String(text.prefix(appendCharacters))
        let stops = [window.range(of: ". ", options: .backwards), window.range(of: "\n", options: .backwards)]
            .compactMap { $0 }
            .map { window.distance(from: window.startIndex, to: $0.upperBound) }
        let at = stops.max().flatMap { $0 > appendCharacters / 2 ? $0 : nil } ?? appendCharacters
        let index = text.index(text.startIndex, offsetBy: at)
        return (
            String(text[..<index]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The voice conversation written down: one JSON line per turn, a file a day, so the
/// next session can be seeded with what was said and the user can read back later.
final class VoiceTranscriptLog {
    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    func file(for date: Date) -> URL {
        directory.appendingPathComponent("\(Self.dayFormatter.string(from: date)).jsonl")
    }

    func append(_ turn: VoiceTurn) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(turn) else { return }
        line.append(UInt8(ascii: "\n"))
        let url = file(for: turn.at)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    /// The last `limit` spoken turns of today and yesterday, oldest first.
    func recent(limit: Int, now: Date = Date()) -> [VoiceTurn] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let days = [now.addingTimeInterval(-86_400), now]
        let turns = days.flatMap { day -> [VoiceTurn] in
            guard let data = try? Data(contentsOf: file(for: day)) else { return [] }
            return data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(VoiceTurn.self, from: $0) }
        }
        return Array(turns.filter { $0.role == .user || $0.role == .assistant }.suffix(limit))
    }
}

import AppKit
import Foundation

/// How a spoken reference picks out a session: a number, as the voice numbers them,
/// or words from a title or folder. Pure, so it can be tested.
enum VoiceSessionReference {
    struct Candidate: Equatable {
        let number: Int
        let session: SidebarSession
        let folder: String?
    }

    /// The candidate `reference` means: "4", "session 4", "#4", "four"; or the one whose
    /// title (then folder) contains the words; or the selected one for "this" / "current".
    static func resolve(_ reference: String, among candidates: [Candidate]) -> Candidate? {
        let text = reference.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }

        if ["this", "current", "the current session", "this session", "selected", "the selected session"].contains(text) {
            return candidates.first { $0.session.isSelected }
        }
        if let number = number(in: text) {
            if let exact = candidates.first(where: { $0.number == number }) { return exact }
        }
        if let exact = candidates.first(where: { $0.session.id == reference }) { return exact }

        let words = text
            .replacingOccurrences(of: #"^(session|tab)\s+"#, with: "", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return nil }

        func score(_ candidate: Candidate) -> Int {
            let title = candidate.session.title.lowercased()
            let folder = (candidate.folder ?? candidate.session.abbreviatedDirectory ?? "").lowercased()
            let branch = (candidate.session.branch ?? "").lowercased()
            var score = 0
            for word in words {
                if title.contains(word) { score += 3 }
                if branch.contains(word) { score += 2 }
                if folder.contains(word) { score += 1 }
            }
            return score
        }
        let scored = candidates.map { ($0, score($0)) }.filter { $0.1 > 0 }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        // Two sessions matching equally well is a question for the user, not a guess.
        let ties = scored.filter { $0.1 == best.1 }
        return ties.count == 1 ? best.0 : nil
    }

    private static let numberWords = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20,
    ]

    /// The number in "4", "#4", "session 4", "session four", "number four"; nil when the
    /// text has other words too, which are then a title.
    static func number(in text: String) -> Int? {
        let stripped = text
            .replacingOccurrences(of: #"^(session|tab|number|no\.?|#)\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(session|tab|number|no\.?|#)\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if let number = Int(stripped) { return number }
        return numberWords[stripped]
    }
}

/// The sessions as the voice knows them: the sidebar's rows, each session given a number
/// when first seen that it keeps while it is open, so "session four" means the same
/// thing all day however the sidebar is reordered.
@MainActor
final class VoiceSessionDirectory {
    let feed = RemoteSessionFeed()

    /// Each new snapshot, with the one before it.
    var onChange: ((_ old: SidebarSnapshot, _ new: SidebarSnapshot) -> Void)?

    private var numbers: [String: Int] = [:]
    private var nextNumber = 1
    private(set) var snapshot = SidebarSnapshot(rows: [])

    func start() {
        feed.onChange = { [weak self] new in
            guard let self else { return }
            let old = self.snapshot
            self.snapshot = new
            self.assignNumbers(new)
            self.onChange?(old, new)
        }
        feed.setActive(true)
        snapshot = feed.snapshot
        assignNumbers(snapshot)
    }

    func stop() {
        feed.setActive(false)
        feed.onChange = nil
    }

    func refresh() {
        feed.update()
        snapshot = feed.snapshot
        assignNumbers(snapshot)
    }

    private func assignNumbers(_ snapshot: SidebarSnapshot) {
        for session in snapshot.sessions where numbers[session.id] == nil {
            numbers[session.id] = nextNumber
            nextNumber += 1
        }
    }

    func number(for sessionID: String) -> Int? {
        numbers[sessionID]
    }

    /// The folder a session sits in, by the sidebar's rows.
    func folderName(of sessionID: String) -> String? {
        for row in snapshot.rows {
            switch row {
            case .folder(let folder) where folder.rows.flatMap(\.sessions).contains(where: { $0.id == sessionID }):
                return folder.name
            case .folderGroup(let group):
                if let folder = group.folders.first(where: { $0.rows.flatMap(\.sessions).contains { $0.id == sessionID } }) {
                    return folder.name
                }
            default:
                continue
            }
        }
        return nil
    }

    var candidates: [VoiceSessionReference.Candidate] {
        snapshot.sessions.compactMap { session in
            guard let number = numbers[session.id] else { return nil }
            return VoiceSessionReference.Candidate(number: number, session: session, folder: folderName(of: session.id))
        }.sorted { $0.number < $1.number }
    }

    func resolve(_ reference: String) -> VoiceSessionReference.Candidate? {
        VoiceSessionReference.resolve(reference, among: candidates)
    }

    func candidate(for window: TerminalWindow) -> VoiceSessionReference.Candidate? {
        let id = feed.ids.id(for: window)
        return candidates.first { $0.session.id == id }
    }

    func window(for candidate: VoiceSessionReference.Candidate) -> TerminalWindow? {
        feed.ids.window(for: candidate.session.id)
    }

    /// A session as the backend hears about it.
    func describe(_ candidate: VoiceSessionReference.Candidate, now: Date = Date()) -> [String: Any] {
        let session = candidate.session
        var row: [String: Any] = [
            "number": candidate.number,
            "title": session.title,
            "status": session.lightLabel ?? "no agent running",
        ]
        if let light = session.light { row["light"] = light.rawValue }
        if let since = session.statusText(at: now) { row["since"] = since }
        if let agent = session.agent { row["agent"] = agent.rawValue }
        if let folder = candidate.folder { row["folder"] = folder }
        if let directory = session.abbreviatedDirectory { row["directory"] = directory }
        if let branch = session.branch { row["branch"] = branch }
        if session.isWorktree { row["worktree"] = true }
        if session.light == .waiting { row["needs_you"] = true }
        if session.finishedUnseen { row["finished_unseen"] = true }
        if session.isSelected { row["selected"] = true }
        if session.bell { row["bell"] = true }
        if let model = session.model { row["model"] = model }
        return row
    }
}

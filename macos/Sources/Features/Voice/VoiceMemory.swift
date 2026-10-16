import Foundation

/// Something the voice keeps about the user across sessions: a fact, a term they use, a
/// preference, or a pattern in how they work.
struct VoiceMemoryNote: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        /// A plain fact: "the mobile app lives in maggie-pro".
        case fact

        /// A word the user says and what it means: "the board" is ~/projects/board.
        case alias

        /// How they like things done: "always open sessions in a worktree".
        case preference

        /// What they tend to do: "runs tests in session two before landing".
        case pattern
    }

    let id: String
    var kind: Kind
    var text: String
    let createdAt: Date

    init(id: String = String(UUID().uuidString.prefix(8)).lowercased(), kind: Kind, text: String, createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
    }
}

/// What the voice remembers, kept in a JSON file: notes, and how often each folder has a
/// session opened by voice, so "the usual folder" means something.
struct VoiceMemoryState: Codable, Equatable {
    var notes: [VoiceMemoryNote] = []

    /// Sessions opened by voice in each folder, by path.
    var folderUse: [String: Int] = [:]

    /// Folders by how often they are used, most first.
    var favouriteFolders: [String] {
        folderUse.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }
}

/// Keeps `VoiceMemoryState` in a file, and renders it for the backend's instructions.
@MainActor
final class VoiceMemoryStore: ObservableObject {
    /// Notes beyond this many are the oldest dropped from the prompt, not the file.
    static let promptNoteLimit = 120

    let file: URL

    @Published private(set) var state = VoiceMemoryState()

    init(file: URL) {
        self.file = file
        load()
    }

    /// Apart for each build, so Maggie Dev's memory isn't Maggie's.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty", isDirectory: true)
            .appendingPathComponent("Voice", isDirectory: true)
    }

    func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file),
              let loaded = try? decoder.decode(VoiceMemoryState.self, from: data) else { return }
        state = loaded
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    @discardableResult
    func remember(_ kind: VoiceMemoryNote.Kind, _ text: String) -> VoiceMemoryNote {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = state.notes.first(where: { $0.kind == kind && $0.text.caseInsensitiveCompare(text) == .orderedSame }) {
            return existing
        }
        let note = VoiceMemoryNote(kind: kind, text: text)
        state.notes.append(note)
        save()
        return note
    }

    /// Removes the note with `id`; false if there is none.
    @discardableResult
    func forget(id: String) -> Bool {
        let before = state.notes.count
        state.notes.removeAll { $0.id == id }
        guard state.notes.count != before else { return false }
        save()
        return true
    }

    func recordFolderUse(_ path: String) {
        state.folderUse[path, default: 0] += 1
        save()
    }

    /// The notes, newest last, cut to the prompt's limit.
    var promptNotes: [VoiceMemoryNote] {
        Array(state.notes.suffix(Self.promptNoteLimit))
    }

    /// What the backend is told it knows about the user.
    func prompt() -> String {
        Self.prompt(for: state, notes: promptNotes)
    }

    static func prompt(for state: VoiceMemoryState, notes: [VoiceMemoryNote]) -> String {
        var lines: [String] = []
        for kind in VoiceMemoryNote.Kind.allCases {
            let ofKind = notes.filter { $0.kind == kind }
            guard !ofKind.isEmpty else { continue }
            lines.append("\(heading(for: kind)):")
            lines += ofKind.map { "- [\($0.id)] \($0.text)" }
        }
        let folders = state.favouriteFolders.prefix(8)
        if !folders.isEmpty {
            lines.append("Folders sessions are most often opened in by voice, most first:")
            lines += folders.map { "- \(($0 as NSString).abbreviatingWithTildeInPath) (\(state.folderUse[$0] ?? 0))" }
        }
        return lines.isEmpty ? "Nothing yet. Use remember as you learn how this user works." : lines.joined(separator: "\n")
    }

    private static func heading(for kind: VoiceMemoryNote.Kind) -> String {
        switch kind {
        case .fact: return "Facts"
        case .alias: return "Terms the user uses"
        case .preference: return "Preferences"
        case .pattern: return "Patterns"
        }
    }
}

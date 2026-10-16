import Foundation

/// The few things the user says that Maggie acts on itself, without GPT-Live: "mute" and
/// "unmute". GPT-Live often answers "muting now" without delegating, so a mute that waits
/// for the model and then the backend's tool can take several tries; the user's own words,
/// from the input transcript, are enough.
///
/// Only an utterance that is the command, give or take politeness, counts: "can you mute
/// yourself, please" mutes, "it doesn't seem muted" and "the mute didn't work" don't.
enum VoiceCommand: Equatable {
    case mute
    case unmute

    /// The command `text` is, or nil when it is anything else.
    static func parse(_ text: String) -> VoiceCommand? {
        var words = normalized(text)
        strip(&words)
        guard !words.isEmpty else { return nil }
        let core = words.joined(separator: " ")
        if muteForms.contains(core) { return .mute }
        if unmuteForms.contains(core) { return .unmute }
        return nil
    }

    private static let objects = ["", " yourself", " you", " the mic", " the microphone", " your mic", " your microphone", " mic", " microphone", " now"]

    private static let muteForms: Set<String> = Set(
        objects.map { "mute\($0)" } + [
            "stop listening", "go on mute", "go mute", "be muted", "put yourself on mute",
            "mute mute",
        ])

    private static let unmuteForms: Set<String> = Set(
        objects.map { "unmute\($0)" } + objects.map { "un mute\($0)" } + ["start listening", "unmute unmute"])

    /// Words around a command that don't change it, longest first so "can you please"
    /// goes before "can you".
    private static let fillers: [[String]] = [
        "can you please", "could you please", "would you please", "will you please",
        "can you", "could you", "would you", "will you", "i need you to", "i want you to",
        "hey maggie", "ok maggie", "okay maggie", "maggie",
        "right now", "for a sec", "for a second", "for a moment", "for a bit", "for a minute", "for me",
        "thank you", "thanks", "please", "now", "just", "all right", "alright",
        "yeah", "yes", "yep", "ok", "okay", "so", "um", "uhm", "uh", "hey", "and", "then", "oh",
    ].map { $0.split(separator: " ").map(String.init) }

    private static func normalized(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: #"[^a-z]+"#, with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
    }

    /// Drops fillers from both ends until none is left there.
    private static func strip(_ words: inout [String]) {
        var changed = true
        while changed, !words.isEmpty {
            changed = false
            for filler in fillers {
                if words.count >= filler.count, Array(words.prefix(filler.count)) == filler {
                    words.removeFirst(filler.count)
                    changed = true
                    break
                }
                if words.count >= filler.count, Array(words.suffix(filler.count)) == filler {
                    words.removeLast(filler.count)
                    changed = true
                    break
                }
            }
        }
    }
}

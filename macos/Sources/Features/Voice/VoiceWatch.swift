import Foundation

/// Which changes to a session the voice tells the user about, whichever of two things
/// reports them: the sidebar's lights, polled every second, and the hook events Claude
/// Code hands the app the moment they happen (`VoiceHookNotice`). Like `RemotePushRules`,
/// at most one notice of a kind a session every half minute, so a light that follows a
/// hook, or one that flaps, isn't a nag.
struct VoiceWatchRules: Equatable {
    struct Notice: Equatable {
        enum Kind: Equatable {
            /// A question, a permission prompt, a dialog: it can't go on without the user.
            case needsYou

            /// It stopped working.
            case finished

            /// Its turn ended on an error: a rate limit, an outage, a billing problem.
            case failed

            /// Claude Code exited.
            case ended
        }

        let sessionID: String
        let kind: Kind
    }

    static let minimumInterval: TimeInterval = 30

    private struct Key: Hashable {
        let session: String
        let kind: Notice.Kind
    }

    private var lastNoticed: [Key: Date] = [:]

    /// The notice for a session's light going from `old` to `new` at `now`, if any.
    mutating func notice(from old: SessionLight?, to new: SessionLight?, session: String, at now: Date) -> Notice? {
        guard let old, let new, old != new else { return nil }
        let kind: Notice.Kind
        if new == .waiting {
            kind = .needsYou
        } else if old == .working, [.clean, .pending, .unlanded].contains(new) {
            kind = .finished
        } else {
            return nil
        }
        return notice(of: kind, session: session, at: now)
    }

    /// A notice of `kind` for `session` at `now`, unless one of that kind went out for the
    /// session in the last half minute.
    mutating func notice(of kind: Notice.Kind, session: String, at now: Date) -> Notice? {
        let key = Key(session: session, kind: kind)
        if let last = lastNoticed[key], now.timeIntervalSince(last) < Self.minimumInterval { return nil }
        lastNoticed[key] = now
        return Notice(sessionID: session, kind: kind)
    }

    /// The notices for everything that changed between two snapshots, for the sessions in
    /// `watched` (or all of them when `all`).
    mutating func notices(
        from old: SidebarSnapshot, to new: SidebarSnapshot, watched: Set<String>, all: Bool, at now: Date
    ) -> [Notice] {
        let before = Dictionary(old.sessions.map { ($0.id, $0.light) }, uniquingKeysWith: { first, _ in first })
        return new.sessions.compactMap { session in
            guard Self.announces(session.id, watched: watched, all: all), let earlier = before[session.id] else { return nil }
            return notice(from: earlier, to: session.light, session: session.id, at: now)
        }
    }

    /// Whether `session`'s news is told: it is watched, or every session is.
    static func announces(_ session: String, watched: Set<String>, all: Bool) -> Bool {
        all || watched.contains(session)
    }

    /// What the voice is told: "Session 4, Login tests, finished: Done. Its last words: …".
    /// `status` is the session's light label; `detail` says more about the kind, such as
    /// the permission asked for or the error; `lastWords` is the agent's last response.
    static func line(
        number: Int, title: String, kind: Notice.Kind, status: String?, detail: String? = nil, lastWords: String? = nil
    ) -> String {
        let what: String
        switch kind {
        case .needsYou: what = "needs you: \(detail ?? status ?? "waiting")"
        case .finished: what = "finished: \(status ?? "done")"
        case .failed: what = "stopped on an error: \(detail ?? "unknown")"
        case .ended: what = "ended" + (detail.map { " (\($0))" } ?? "")
        }
        var text = "Session \(number), \(title), \(what)."
        if let lastWords, !lastWords.isEmpty { text += " Its last words: \(lastWords)" }
        return text
    }
}

/// What a Claude Code hook event means to the voice, if anything. The plugin's hooks
/// (`ClaudePlugin/hooks/hooks.json`) hand the app each session's `Notification`, `Stop`,
/// `StopFailure` and `SessionEnd` as they happen, well before the sidebar's light, read
/// from the session registry, catches up; and they carry what the light can't: the
/// message of a permission prompt, the error a turn died on, the last response.
enum VoiceHookNotice {
    struct Meaning: Equatable {
        let kind: VoiceWatchRules.Notice.Kind

        /// What the session needs, or what went wrong.
        var detail: String?

        /// The response the session ended its turn with.
        var lastWords: String?
    }

    /// The `notification_type`s that mean the session can't go on without the user.
    /// `idle_prompt` isn't one: it is a reminder a minute after a `Stop` already told.
    static let needsYouNotifications: Set<String> = [
        "permission_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input",
    ]

    /// `SessionEnd` reasons after which the session goes on under a new id, so nothing
    /// ended for the user.
    static let continuingEndReasons: Set<String> = ["clear", "resume"]

    static func meaning(of event: ClaudeAgentEvent) -> Meaning? {
        switch event.name {
        case "Notification":
            guard let type = event.notificationType, needsYouNotifications.contains(type) else { return nil }
            return Meaning(kind: .needsYou, detail: event.message)

        case "Stop":
            // A subagent's stop arrives as SubagentStop; a Stop that names an agent is a
            // turn inside one, not the session's.
            guard event.agentID == nil else { return nil }
            return Meaning(kind: .finished, lastWords: event.lastAssistantMessage)

        case "StopFailure":
            guard event.agentID == nil else { return nil }
            var detail = event.error?.replacingOccurrences(of: "_", with: " ")
            if let details = event.errorDetails, !details.isEmpty {
                detail = detail.map { "\($0) (\(details))" } ?? details
            }
            return Meaning(kind: .failed, detail: detail)

        case "SessionEnd":
            if let reason = event.reason, continuingEndReasons.contains(reason) { return nil }
            return Meaning(kind: .ended, detail: event.reason?.replacingOccurrences(of: "_", with: " "))

        default:
            return nil
        }
    }
}

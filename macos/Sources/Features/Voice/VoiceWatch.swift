import Foundation

/// Which changes to a session the voice tells the user about: a session that starts
/// waiting for them, and one that finishes working. Like `RemotePushRules`, at most one
/// notice a session every half minute, so a flapping light isn't a nag.
struct VoiceWatchRules: Equatable {
    struct Notice: Equatable {
        enum Kind: Equatable {
            case needsYou
            case finished
        }

        let sessionID: String
        let kind: Kind
    }

    static let minimumInterval: TimeInterval = 30

    private var lastNoticed: [String: Date] = [:]

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
        if let last = lastNoticed[session], now.timeIntervalSince(last) < Self.minimumInterval { return nil }
        lastNoticed[session] = now
        return Notice(sessionID: session, kind: kind)
    }

    /// The notices for everything that changed between two snapshots, for the sessions in
    /// `watched` (or all of them when `all`).
    mutating func notices(
        from old: SidebarSnapshot, to new: SidebarSnapshot, watched: Set<String>, all: Bool, at now: Date
    ) -> [Notice] {
        let before = Dictionary(old.sessions.map { ($0.id, $0.light) }, uniquingKeysWith: { first, _ in first })
        return new.sessions.compactMap { session in
            guard all || watched.contains(session.id), let earlier = before[session.id] else { return nil }
            return notice(from: earlier, to: session.light, session: session.id, at: now)
        }
    }
}

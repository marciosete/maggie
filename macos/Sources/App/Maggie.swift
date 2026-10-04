import AppKit

/// What this build is: Maggie, the Ghostty it was forked from, or a build under some
/// other bundle ID. `fork/package.sh` sets Maggie's.
///
/// Ghostty's name is in its menus, windows and dialogs. Rather than edit each of them,
/// which upstream would conflict with on every merge, Maggie puts its own name in at
/// the few places they pass through.
enum Maggie {
    static let bundleID = "com.marciosete.maggie"

    /// Where releases are published, and the update feed with them.
    static let repositoryURL = "https://github.com/marciosete/maggie"
    static let releasesURL = "\(repositoryURL)/releases"
    static let feedURL = "\(releasesURL)/latest/download/appcast.xml"

    /// Ghostty's own documentation, which covers everything Maggie inherits.
    static let ghosttyDocsURL = "https://ghostty.org/docs"

    /// The release notes of version `version` (x.y.z): Maggie's GitHub release, or
    /// Ghostty's page for it in a build that isn't Maggie.
    static func releaseNotesURL(version: String, maggie: Bool = isMaggie) -> URL? {
        if maggie { return URL(string: "\(releasesURL)/tag/v\(version)") }
        let slug = version.replacingOccurrences(of: ".", with: "-")
        return URL(string: "https://ghostty.org/docs/install/release-notes/\(slug)")
    }

    /// Commit `hash` in this app's repository.
    static func commitURL(_ hash: String, maggie: Bool = isMaggie) -> URL? {
        URL(string: "\(maggie ? repositoryURL : "https://github.com/ghostty-org/ghostty")/commit/\(hash)")
    }

    /// The changes from commit `from` to commit `to` in this app's repository.
    static func compareURL(from: String, to: String, maggie: Bool = isMaggie) -> URL? {
        URL(string: "\(maggie ? repositoryURL : "https://github.com/ghostty-org/ghostty")/compare/\(from)...\(to)")
    }

    static var isMaggie: Bool {
        Bundle.main.bundleIdentifier == bundleID
    }

    static var isGhostty: Bool {
        Bundle.main.bundleIdentifier?.hasPrefix("com.mitchellh.ghostty") ?? false
    }

    /// What the app is called, as the bundle says.
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Maggie"
    }

    /// What stands in for a title the terminal hasn't set: Ghostty's ghost, or Maggie's
    /// name. Where a view can draw, the sidebar shows the magpie (`MaggieGlyph`) instead.
    static var placeholderTitle: String {
        isMaggie ? appName : "👻"
    }

    /// `text` with Ghostty's name replaced by this app's, when this app is Maggie.
    /// Ghostty's ghost goes with it: "👻 Ghostty" is "Maggie".
    static func branded(_ text: String) -> String {
        guard isMaggie else { return text }
        return text
            .replacingOccurrences(of: "👻 Ghostty", with: appName)
            .replacingOccurrences(of: "👻", with: appName)
            .replacingOccurrences(of: "Ghostty", with: appName)
    }

    /// The first item under `menu`, at any depth, whose action is `action`.
    static func item(withAction action: Selector, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.action == action { return item }
            if let submenu = item.submenu, let found = Self.item(withAction: action, in: submenu) {
                return found
            }
        }
        return nil
    }

    /// Puts this app's name in every title under `menu`, when this app is Maggie.
    static func brand(menu: NSMenu) {
        guard isMaggie else { return }
        menu.title = branded(menu.title)
        for item in menu.items {
            item.title = branded(item.title)
            if let submenu = item.submenu { brand(menu: submenu) }
        }
    }
}

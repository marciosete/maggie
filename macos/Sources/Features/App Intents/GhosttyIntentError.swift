enum GhosttyIntentError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case surfaceNotFound
    case permissionDenied

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: LocalizedStringResource(stringLiteral: Maggie.branded("The Ghostty app isn't properly initialized."))
        case .surfaceNotFound: "The terminal no longer exists."
        case .permissionDenied: LocalizedStringResource(stringLiteral: Maggie.branded("Ghostty doesn't allow Shortcuts."))
        }
    }
}

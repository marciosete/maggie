import AppKit
import Combine

/// App-wide settings for the vertical tab sidebar. These are shared by every terminal
/// window so toggling the sidebar in one window applies to all of them, and they are
/// persisted in user defaults so they survive relaunches.
final class TabSidebarSettings: ObservableObject {
    static let shared = TabSidebarSettings()

    private static let enabledKey = "TabSidebarEnabled"
    private static let collapsedKey = "TabSidebarCollapsed"
    private static let widthKey = "TabSidebarWidth"
    private static let rowStyleKey = "TabSidebarRowStyle"
    private static let showsSubagentsKey = "TabSidebarShowsSubagents"
    private static let groupByKey = "TabSidebarGroupBy"
    private static let collapsedStatusesKey = "TabSidebarCollapsedStatuses"

    static let minWidth: CGFloat = 150
    static let maxWidth: CGFloat = 420
    static let defaultWidth: CGFloat = 220

    /// When true, tabs are shown in a vertical sidebar instead of the native tab bar.
    @Published var isEnabled: Bool {
        didSet { UserDefaults.ghostty.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// When true, the sidebar is hidden completely (but vertical tabs remain enabled,
    /// so the native tab bar stays hidden too).
    @Published var isCollapsed: Bool {
        didSet { UserDefaults.ghostty.set(isCollapsed, forKey: Self.collapsedKey) }
    }

    /// The width of the sidebar in points.
    @Published var width: CGFloat {
        didSet { UserDefaults.ghostty.set(Double(width), forKey: Self.widthKey) }
    }

    /// How much each session's row shows.
    enum RowStyle: String, CaseIterable {
        /// One line: the title and what the session is doing.
        case simple

        /// A taller row that also shows where the session works: its branch, or its
        /// directory.
        case extended

        var localizedName: String {
            switch self {
            case .simple: return "Simple"
            case .extended: return "Extended"
            }
        }
    }

    @Published var rowStyle: RowStyle {
        didSet { UserDefaults.ghostty.set(rowStyle.rawValue, forKey: Self.rowStyleKey) }
    }

    /// Whether the subagents and teammates a Claude Code session starts are listed under
    /// its row.
    @Published var showsSubagents: Bool {
        didSet { UserDefaults.ghostty.set(showsSubagents, forKey: Self.showsSubagentsKey) }
    }

    /// How the sidebar lists sessions.
    enum GroupBy: String, CaseIterable {
        /// In their folders and groups.
        case folders

        /// Under their columns on the session board.
        case status

        var localizedName: String {
            switch self {
            case .folders: return "Folders"
            case .status: return "Status"
            }
        }
    }

    @Published var groupBy: GroupBy {
        didSet { UserDefaults.ghostty.set(groupBy.rawValue, forKey: Self.groupByKey) }
    }

    /// The board columns folded away while the sidebar lists by status.
    @Published var collapsedStatuses: Set<String> {
        didSet { UserDefaults.ghostty.set(collapsedStatuses.sorted(), forKey: Self.collapsedStatusesKey) }
    }

    private init() {
        let defaults = UserDefaults.ghostty
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        groupBy = defaults.string(forKey: Self.groupByKey).flatMap(GroupBy.init(rawValue:)) ?? .folders
        collapsedStatuses = Set(defaults.stringArray(forKey: Self.collapsedStatusesKey) ?? [])
        showsSubagents = defaults.object(forKey: Self.showsSubagentsKey) as? Bool ?? true
        isCollapsed = defaults.bool(forKey: Self.collapsedKey)
        rowStyle = defaults.string(forKey: Self.rowStyleKey).flatMap(RowStyle.init(rawValue:)) ?? .extended

        let storedWidth = defaults.double(forKey: Self.widthKey)
        width = storedWidth > 0
            ? Self.clampWidth(CGFloat(storedWidth))
            : Self.defaultWidth
    }

    static func clampWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, minWidth), maxWidth)
    }
}

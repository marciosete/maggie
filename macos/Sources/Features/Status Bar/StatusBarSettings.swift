import AppKit
import Combine

/// Whether the status bar along the bottom of each window shows, and which of its items.
final class StatusBarSettings: NSObject, ObservableObject {
    static let shared = StatusBarSettings()

    enum Item: String, CaseIterable {
        case claudeUsage
        case codexUsage
        case caffeine
        case voice
        case resources

        var localizedName: String {
            switch self {
            case .claudeUsage: return "Claude Usage"
            case .codexUsage: return "Codex Usage"
            case .caffeine: return "Keep Awake"
            case .voice: return "Voice"
            case .resources: return "Resource Manager"
            }
        }
    }

    private static let visibleKey = "StatusBarVisible"
    private static let hiddenItemsKey = "StatusBarHiddenItems"

    @Published var isVisible: Bool {
        didSet {
            UserDefaults.ghostty.set(isVisible, forKey: Self.visibleKey)
            updateMenuItem()
        }
    }

    /// Items taken off the bar. Kept as what's hidden, so an item added later shows.
    @Published private(set) var hiddenItems: Set<Item> {
        didSet { UserDefaults.ghostty.set(hiddenItems.map(\.rawValue).sorted(), forKey: Self.hiddenItemsKey) }
    }

    private weak var menuItem: NSMenuItem?

    override private init() {
        let defaults = UserDefaults.ghostty
        isVisible = defaults.object(forKey: Self.visibleKey) as? Bool ?? true
        hiddenItems = Set((defaults.stringArray(forKey: Self.hiddenItemsKey) ?? []).compactMap(Item.init(rawValue:)))
        super.init()
    }

    func shows(_ item: Item) -> Bool {
        isVisible && !hiddenItems.contains(item)
    }

    func toggle(_ item: Item) {
        if hiddenItems.contains(item) { hiddenItems.remove(item) } else { hiddenItems.insert(item) }
    }

    // MARK: Menu

    func installMenuItem(in menu: NSMenu, at index: Int) {
        let item = NSMenuItem(title: "Show Status Bar", action: #selector(toggleVisible(_:)), keyEquivalent: "")
        item.target = self
        item.setImageIfDesired(systemSymbolName: "rectangle.bottomthird.inset.filled")
        menu.insertItem(item, at: index)
        menuItem = item
        updateMenuItem()
    }

    private func updateMenuItem() {
        menuItem?.state = isVisible ? .on : .off
    }

    @objc private func toggleVisible(_ sender: Any?) {
        isVisible.toggle()
    }
}

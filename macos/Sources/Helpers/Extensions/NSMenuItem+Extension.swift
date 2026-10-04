import AppKit

extension NSMenuItem {
    /// Sets the image property from a symbol if we want images on our menu items.
    func setImageIfDesired(systemSymbolName symbol: String) {
        // We only set on macOS 26 when icons on menu items became the norm.
        if #available(macOS 26, *) {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            showImageOnMacOS27()
        }
    }

    /// macOS 27 hides menu item images unless the item asks for them to be visible.
    /// Maggie keeps its icons, so every item that sets one asks.
    ///
    /// `preferredImageVisibility` is set by key, not by name, because the release is
    /// built with an SDK older than macOS 27's, which doesn't declare it. 1 is
    /// `NSMenuItem.ImageVisibility.visible`.
    private func showImageOnMacOS27() {
        guard #available(macOS 27, *),
              responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        setValue(1, forKey: "preferredImageVisibility")
    }
}

import AppKit

/// Builds the status-item menu. Rebuilt every time it opens so feature state/status stay fresh.
///
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let manager: FeatureManager

    init(manager: FeatureManager) {
        self.manager = manager
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()

        if let chat = manager.features.first {
            for item in chat.menuItems() { menu.addItem(item) }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: AppText.t("Quit Quick Chat Omni"),
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
    }
}

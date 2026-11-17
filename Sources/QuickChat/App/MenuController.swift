import AppKit

/// Builds the status-item menu. Rebuilt every time it opens so feature state/status stay fresh.
///
/// Layout per feature:
///   [✓] <feature.title>
///         <feature.statusText>          (greyed, if non-nil)
///         <feature.menuItems()...>      (indented)
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

        let header = NSMenuItem(title: "Quick Chat Omni", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if let chat = manager.features.first {
            for item in chat.menuItems() { menu.addItem(item) }
            menu.addItem(.separator())
            let shortcut = ActionMenuItem(chat.title) { [weak self] in self?.manager.toggle(chat) }
            shortcut.state = chat.isEnabled ? .on : .off
            menu.addItem(shortcut)
        }
        let advanced = NSMenuItem(title: "ChatGPT Integration", action: nil, keyEquivalent: "")
        let integration = NSMenu()
        integration.autoenablesItems = false
        for feature in manager.features.dropFirst() {
            let toggle = ActionMenuItem(feature.title) { [weak self] in self?.manager.toggle(feature) }
            toggle.state = feature.isChecked ? .on : .off
            toggle.isEnabled = feature.canToggle
            integration.addItem(toggle)
            if let status = feature.statusText {
                let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                item.isEnabled = false
                integration.addItem(item)
            }
            for item in feature.menuItems() { integration.addItem(item) }
        }
        advanced.submenu = integration
        menu.addItem(advanced)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Quick Chat Omni",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
    }
}

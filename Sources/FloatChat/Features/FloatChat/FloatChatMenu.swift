import AppKit

extension FloatChatController {
    func quickMenuItems() -> [NSMenuItem] {
        let open = ActionMenuItem(AppText.t("Open Chat")) { [weak self] in self?.show() }
        open.image = NSImage(systemSymbolName: "bubble.left", accessibilityDescription: nil)
        let switchChat = NSMenuItem(title: AppText.t("Switch Chat"), action: nil, keyEquivalent: "")
        let chats = NSMenu()
        switchChat.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        switchChat.submenu = chats
        for pinned in pinnedFirst ? [true, false] : [false, true] {
            let group = enabledTabIndices.filter { providers[$0].isPinned == pinned }
            guard !group.isEmpty else { continue }
            let heading = NSMenuItem(title: AppText.t(pinned ? "Pinned Conversations" : "Instant Chats"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            chats.addItem(heading)
            for index in group {
                let provider = providers[index]
                let item = ActionMenuItem(displayName(provider)) { [weak self] in
                    guard let self, let currentIndex = self.providers.firstIndex(where: { $0.key == provider.key }) else { return }
                    self.selectProvider(currentIndex)
                    self.show()
                }
                item.image = ProviderIcon.image(for: provider.url, size: 16)
                item.state = index == selectedIndex ? .on : .off
                chats.addItem(item)
            }
        }
        let settings = ActionMenuItem(AppText.t("Settings…")) { [weak self] in self?.showSettings() }
        settings.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        let updates = ActionMenuItem(AppText.t("Check for Updates…")) {
            AppUpdates.check()
        }
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        return [open, switchChat, .separator(), settings, updates]
    }
    func reorderProviders(_ offsets: IndexSet, to destination: Int) {
        let selected = providers[selectedIndex].key
        var ordered = providers.map(\.key)
        ordered.move(fromOffsets: offsets, toOffset: destination)
        providerOrder = ordered
        preferences.set(ordered, forKey: "providerOrder")
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        refreshPicker(); updateSettings()
    }
}

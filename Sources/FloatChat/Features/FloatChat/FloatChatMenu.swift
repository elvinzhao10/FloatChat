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
        let record = ActionMenuItem(meetingRecorder.actionTitle) { [weak self] in self?.toggleRecording() }
        record.image = NSImage(systemSymbolName: meetingRecorder.isRecording ? "stop.circle" : "record.circle", accessibilityDescription: nil)
        var recordingItems: [NSMenuItem] = [record]
        if websiteAudioRelay.isCapturing(webView) {
            recordingItems.append(ActionMenuItem(AppText.t("Stop Sharing Mac Audio")) { [weak self] in
                self?.websiteAudioRelay.stop()
            })
        }
        if meetingRecorder.recordsSystemAudio {
            let status = NSMenuItem(title: AppText.t(meetingRecorder.systemAudioStatus), action: nil, keyEquivalent: "")
            status.isEnabled = false
            recordingItems.append(status)
        }
        if meetingRecorder.usesBuiltInMicrophone {
            let input = NSMenuItem(title: AppText.t("Using the Mac’s microphone for headphone playback"),
                                   action: nil, keyEquivalent: "")
            input.isEnabled = false
            recordingItems.append(input)
        }
        if lastRecordingFile != nil {
            let save = ActionMenuItem(AppText.t("Save Last Recording…")) { [weak self] in self?.saveLastRecording() }
            save.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
            recordingItems.append(save)
        }
        return [open, switchChat, .separator()] + recordingItems + [.separator(), settings, updates]
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

import AppKit
import WebKit
import SwiftUI
import ServiceManagement
import Network
import UniformTypeIdentifiers

/// Floating FloatChat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class FloatChatController: NSObject {
    struct Provider: Codable {
        var name: String
        var url: URL
        var sessionID: String? = nil
        var conversationURL: URL? = nil
        var topic: String? = nil
        var pinned: Bool? = nil
        var manualTopic: String? = nil
        var builtInKey: String? = nil
        var key: String { sessionID ?? builtInKey ?? url.absoluteString }
        var isPinned: Bool { pinned == true }
    }
    static let doubaoURL = URL(string: "https://www.doubao.com/chat/")!
    private static let builtIns = [
        Provider(name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!),
        Provider(name: "Claude", url: URL(string: "https://claude.ai/")!),
        Provider(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com/")!),
        Provider(name: "Kimi", url: URL(string: "https://www.kimi.com/")!),
        Provider(name: "Gemini", url: URL(string: "https://gemini.google.com/")!),
        Provider(name: "Perplexity", url: URL(string: "https://www.perplexity.ai/")!),
        Provider(name: "Copilot", url: URL(string: "https://copilot.microsoft.com/")!),
        Provider(name: "Grok", url: URL(string: "https://grok.com/")!),
        Provider(name: "豆包 · Doubao", url: doubaoURL),
    ]
    let preferences: UserDefaults
    private var customProviders: [Provider] = []
    var savedSessions: [Provider] = []
    let pinnedDrafts = PinnedDrafts()
    let generationIndicator = GenerationIndicator()
    var pageURLObservation: NSKeyValueObservation?
    var pageTitleObservation: NSKeyValueObservation?
    private weak var pinButton: NSButton?
    private var deletedURLs: Set<String> = []
    var providerOrder: [String] = []

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        if let data = preferences.data(forKey: "customProviders"),
           let stored = try? JSONDecoder().decode([Provider].self, from: data) {
            let builtInKeys = Set(Self.builtIns.map(\.key))
            var seenKeys = Set<String>()
            var seenURLs = Set<URL>()
            customProviders = stored.compactMap { provider in
                guard let url = ProviderAddress.parse(provider.url.absoluteString) else { return nil }
                // Older preferences could contain a custom Doubao entry from before it was bundled.
                let builtInKey = provider.builtInKey ?? (url == Self.doubaoURL ? url.absoluteString : nil)
                let addressKey = url.absoluteString
                let key = builtInKey ?? addressKey
                guard builtInKey.map(builtInKeys.contains) ?? true,
                      !builtInKeys.contains(addressKey) || addressKey == builtInKey,
                      !seenKeys.contains(key), seenURLs.insert(url).inserted else { return nil }
                seenKeys.insert(key)
                return Provider(name: provider.name, url: url, builtInKey: builtInKey)
            }
        }
        if let data = preferences.data(forKey: "pinnedSessions"), let stored = try? JSONDecoder().decode([Provider].self, from: data) {
            var seen = Set<String>()
            savedSessions = stored.filter { item in
                guard item.sessionID != nil, item.isPinned, ProviderAddress.parse(item.url.absoluteString) != nil, seen.insert(item.key).inserted else { return false }
                guard let target = item.conversationURL else { return false }
                return Self.isConversationURL(target, provider: item)
            }
        }
        deletedURLs = Set(preferences.stringArray(forKey: "deletedProviders") ?? [])
        providerOrder = preferences.stringArray(forKey: "providerOrder") ?? []
        disabledURLs = Set(preferences.stringArray(forKey: "disabledProviders") ?? [])
        if providers.isEmpty { deletedURLs.remove(Self.builtIns[0].url.absoluteString) }
        if providers.allSatisfy({ disabledURLs.contains($0.key) }) { disabledURLs.remove(providers[0].key) }
        let saved = preferences.string(forKey: "selectedProvider")
        selectedIndex = providers.firstIndex { $0.key == saved && !disabledURLs.contains($0.key) }
            ?? providers.firstIndex { !disabledURLs.contains($0.key) } ?? 0
        generationIndicator.onChange = { [weak self] in self?.prunePages() }
    }
    private var websites: [Provider] {
        Self.builtIns.map { builtIn in
            customProviders.first { $0.builtInKey == builtIn.key } ?? builtIn
        } + customProviders.filter { $0.builtInKey == nil }
    }

    var providers: [Provider] {
        let available = (websites + savedSessions).filter { !deletedURLs.contains($0.key) }
        return available.enumerated().sorted { lhs, rhs in
            let a = providerOrder.firstIndex(of: lhs.element.key) ?? (providerOrder.count + lhs.offset)
            let b = providerOrder.firstIndex(of: rhs.element.key) ?? (providerOrder.count + rhs.offset)
            return a < b
        }.map(\.element)
    }

    var disabledURLs: Set<String> = []
    var pinnedFirst: Bool { preferences.bool(forKey: "pinnedFirst") }
    var language: String { preferences.string(forKey: "appLanguage") ?? "en" }
    var settingsWindow: NSWindow?
    private var clearingWebsiteData = false
    var panelTranslucency: Double {
        let legacyValue = preferences.bool(forKey: "glassEnabled") ? 16.0 : 0.0
        let value = preferences.object(forKey: "panelTranslucency") as? Double ?? legacyValue
        return min(40, max(0, value))
    }

    func setPanelTranslucency(_ value: Double) {
        let wasTranslucent = panelTranslucency > 0
        preferences.set(value, forKey: "panelTranslucency")
        settingsFields.panelTranslucency = panelTranslucency
        applySurfaceAppearance()
        guard wasTranslucent != (panelTranslucency > 0) else { return }
        for view in parkedPages.values.map(\.view) + [webView].compactMap({ $0 }) {
            configureScripts(view.configuration.userContentController)
            setWebBackground(view)
            if panelTranslucency == 0, view !== webView {
                view.evaluateJavaScript("document.getElementById('floatchat-canvas')?.remove()",
                                        in: nil, in: .defaultClient, completionHandler: nil)
            }
        }
        if let webView {
            cancelPageAppearance()
            matchPageEdge(webView)
        }
    }

    func applySurfaceAppearance() {
        let translucency = panelTranslucency
        // Change only the shared background. Control and web text layers stay opaque.
        contentStack?.layer?.backgroundColor = surfaceColor.withAlphaComponent(1 - translucency / 100).cgColor
        let hidden = translucency == 0
        if glassBackdrop?.isHidden != hidden {
            glassBackdrop?.isHidden = hidden
            panel?.invalidateShadow()
        }
    }
    private var centerOnOpen: Bool { preferences.bool(forKey: "centerOnOpen") }
    var hideOnClickAway: Bool { preferences.bool(forKey: "hideOnClickAway") }
    var zoomKeysEnabled: Bool { preferences.object(forKey: "zoomKeysEnabled") as? Bool ?? true }

    private func setPanelPreference(_ enabled: Bool, for key: String) {
        preferences.set(enabled, forKey: key)
        if key == "centerOnOpen" {
            panel?.remembersFrame = !enabled
        } else if key == "showGenerationIndicator", !enabled {
            generationIndicator.stop()
            prunePages()
        } else if key == "zoomKeysEnabled" {
            panel?.zoomKeysEnabled = enabled
        }
        updateSettings()
    }
    private var refreshingIcons: Set<URL> = []
    private let settingsFields = ChatSettingsFields()

    var configureShortcut: (() -> Void)?
    var shortcutControls: (() -> [ChatSettingsView.ShortcutControl])?

    private func removeProvider(_ index: Int) {
        guard providers.indices.contains(index), providers.count > 1 else { return }
        let provider = providers[index]
        let alert = NSAlert()
        alert.messageText = AppText.t("Remove") + " \(provider.topic ?? provider.name)?"
        alert.informativeText = provider.sessionID == nil
            ? AppText.t("Removes this website from your list. Your account, conversations and sign-in data are kept. You can add it again later.")
            : AppText.t("Closes this chat tab and removes its saved link. Unsent drafts in this tab will be lost. The conversation on the website and your sign-in data are kept.")
        alert.addButton(withTitle: AppText.t("Cancel"))
        alert.addButton(withTitle: AppText.t("Remove"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        deleteProvider(index)
    }
    func deleteProvider(_ index: Int) {
        guard providers.indices.contains(index), providers.count > 1 else { return }
        let provider = providers[index]
        if index == selectedIndex, let next = providers.indices.first(where: { $0 != index }) {
            disabledURLs.remove(providers[next].key)
            preferences.set(Array(disabledURLs), forKey: "disabledProviders")
            selectProvider(next)
        }
        let selected = providers[selectedIndex].key
        let key = provider.key
        if let page = parkedPages.removeValue(forKey: key) { releasePage(page.view) }
        if provider.sessionID == nil && !Self.builtIns.contains(where: { $0.key == key }) {
            customProviders.removeAll { $0.key == key }
        }
        savedSessions.removeAll { $0.key == key }
        pinnedDrafts.forget(key)
        if provider.isPinned {
            var zooms = preferences.dictionary(forKey: "websiteZoom") ?? [:]
            zooms.removeValue(forKey: key)
            preferences.set(zooms, forKey: "websiteZoom")
        }
        saveSessions()
        deletedURLs.insert(key)
        preferences.set(Array(deletedURLs), forKey: "deletedProviders")
        saveCustomProviders()
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        prunePages(); refreshPicker(); updateSettings()
    }
    func toggleProvider(_ index: Int) {
        let key = providers[index].key
        if disabledURLs.contains(key) { disabledURLs.remove(key) }
        else {
            guard providers.filter({ !disabledURLs.contains($0.key) }).count > 1 else { NSSound.beep(); return }
            disabledURLs.insert(key)
        }
        preferences.set(Array(disabledURLs), forKey: "disabledProviders")
        if disabledURLs.contains(providers[selectedIndex].key), let next = providers.firstIndex(where: { !disabledURLs.contains($0.key) }) { selectProvider(next) }
        if disabledURLs.contains(key), let page = parkedPages.removeValue(forKey: key) { releasePage(page.view) }
        prunePages()
        refreshPicker()
        updateSettings()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = AppText.t("Settings")
            window.level = .floating
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        guard let settingsWindow else { return }
        if !settingsWindow.isVisible, let panel, panel.isVisible, let screen = panel.screen {
            let available = screen.visibleFrame
            let frame = panel.frame
            let size = settingsWindow.frame.size
            let right = frame.maxX + 12
            let left = frame.minX - size.width - 12
            let x = right + size.width <= available.maxX ? right : max(available.minX, left)
            let y = max(available.minY, min(frame.maxY, available.maxY) - size.height)
            settingsWindow.setFrameOrigin(NSPoint(x: x, y: y))
        }
        updateSettings()
        NSApp.activate()
        settingsWindow.makeKeyAndOrderFront(nil)
    }
    func updateSettings() {
        guard let settingsWindow else { return }
        settingsFields.panelTranslucency = panelTranslucency
        let view = ChatSettingsView(
            fields: settingsFields,
            pinnedFirst: pinnedFirst,
            setPinnedFirst: { [weak self] first in
                self?.preferences.set(first, forKey: "pinnedFirst"); self?.refreshPicker(); self?.updateSettings()
            },
            language: language,
            setLanguage: { [weak self] code in self?.setLanguage(code) },
            loginStatus: SMAppService.mainApp.status,
            setLaunchAtLogin: { [weak self] enabled in self?.setLaunchAtLogin(enabled) },
            editEntry: { [weak self] index in self?.editEntry(index) },
            chooseIcon: { [weak self] url in self?.chooseIcon(for: url) },
            resetIcon: { [weak self] url in self?.resetIcon(for: url) },
            refreshIcon: { [weak self] url in self?.refreshFavicon(url) },
            clearWebsiteData: { [weak self] in self?.confirmClearWebsiteData() },
            clearingWebsiteData: clearingWebsiteData,
            reloadPages: { [weak self] in self?.reloadForLanguage() },
            setPanelTranslucency: { [weak self] value in self?.setPanelTranslucency(value) },
            centerOnOpen: centerOnOpen,
            hideOnClickAway: hideOnClickAway,
            zoomKeysEnabled: zoomKeysEnabled,
            showGenerationIndicator: preferences.bool(forKey: "showGenerationIndicator"),
            setPanelPreference: { [weak self] value, key in self?.setPanelPreference(value, for: key) },
            zoomFor: { [weak self] key in
                guard let self, let provider = self.providers.first(where: { $0.key == key }) else { return 1 }
                return self.zoom(for: provider)
            },
            setZoom: { [weak self] key, value in self?.setZoom(value, for: key) },
            instantRetention: retentionMinutes(forPinned: false),
            pinnedRetention: retentionMinutes(forPinned: true),
            setRetention: { [weak self] minutes, pinned in self?.setRetention(minutes, forPinned: pinned) },
            shortcutControls: shortcutControls?() ?? [],
            shortcuts: { [weak self] in self?.configureShortcut?() },
            reorder: { [weak self] offsets, destination in self?.reorderProviders(offsets, to: destination) },
            remove: { [weak self] index in self?.removeProvider(index) },
            unpin: { [weak self] index in self?.unpinProvider(index) },
            providers: providers.enumerated().map { index, provider in
                ChatSettingsView.Row(id: provider.key, index: index, name: displayName(provider), url: provider.url, pinned: provider.isPinned, refreshingIcon: refreshingIcons.contains(provider.url), enabled: !disabledURLs.contains(provider.key))
            }, toggle: { [weak self] in self?.toggleProvider($0) },
            add: { [weak self] name, address in
                self?.addWebsite(name, address: address) ?? false
            })
        if let host = settingsWindow.contentView as? NSHostingView<ChatSettingsView> {
            host.rootView = view
        } else {
            settingsWindow.contentView = NSHostingView(rootView: view)
        }
    }
    private func confirmClearWebsiteData() {
        guard !clearingWebsiteData, let settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = AppText.t("Clear all website data?")
        alert.informativeText = AppText.t("This signs out every website in FloatChat and discards open drafts. Your website list and pinned links are kept.")
        alert.addButton(withTitle: AppText.t("Cancel"))
        alert.addButton(withTitle: AppText.t("Clear Website Data")).hasDestructiveAction = true
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.clearingWebsiteData = true
            self.tearDown()
            self.updateSettings()
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                    modifiedSince: .distantPast) { [weak self] in
                self?.clearingWebsiteData = false
                self?.updateSettings()
            }
        }
    }
    private func setLanguage(_ code: String) {
        guard AppText.supported.contains(code) else { return }
        preferences.set(code, forKey: "appLanguage")
        if preferences === UserDefaults.standard { AppText.applyOwnLanguage(); EditMenu.install() }
        for view in parkedPages.values.map(\.view) + [webView].compactMap({ $0 }) {
            configureScripts(view.configuration.userContentController)
        }
        settingsWindow?.title = AppText.t("Settings")
        updateSettings()
        func localize(_ view: NSView) {
            if let button = view as? NSButton, let key = button.identifier?.rawValue, key.hasPrefix("toolbar:") {
                let label = AppText.t(String(key.dropFirst(8)))
                button.toolTip = label; button.setAccessibilityLabel(label)
            }
            for child in view.subviews { localize(child) }
        }
        if let chromeView { localize(chromeView) }
        refreshPicker()
    }
    func pageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let tag = AppText.webTag(for: language)
        let primary = String(tag.split(separator: "-").first ?? "en")
        request.setValue("\(tag),\(primary);q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }
    func configureScripts(_ scripts: WKUserContentController) {
        scripts.removeAllUserScripts()
        scripts.addUserScript(WKUserScript(source: Self.noAutocorrectScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let tag = AppText.webTag(for: language)
        let languages = [tag, String(tag.split(separator: "-").first ?? "en")]
        let data = try! JSONEncoder().encode(languages)
        let json = String(data: data, encoding: .utf8)!
        let source = """
        (() => { try {
          const languages = Object.freeze(\(json));
          Object.defineProperty(navigator, 'language', { configurable: true, get: () => languages[0] });
          Object.defineProperty(navigator, 'languages', { configurable: true, get: () => languages });
        } catch (_) {} })();
        """
        scripts.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if panelTranslucency > 0, Self.canClearWebBackground {
            let canvas = #"""
                (() => {
                    \#(Self.canvasStylesheet)
                    installCanvasStyle();
                })()
                """#
            scripts.addUserScript(WKUserScript(source: canvas, injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true, in: .defaultClient))
        }
    }
    private func reloadForLanguage() {
        let alert = NSAlert()
        alert.messageText = AppText.t("Reload open chats?")
        alert.informativeText = AppText.t("This keeps sign-ins and pinned links. Unsent drafts in open pages may be lost.")
        alert.addButton(withTitle: AppText.t("Cancel"))
        alert.addButton(withTitle: AppText.t("Reload"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        rememberPinnedPage()
        for page in parkedPages.values { releasePage(page.view) }
        parkedPages.removeAll()
        prunePages()
        if let webView { webView.load(pageRequest(webView.url ?? chatURL)) }
    }
    private func chooseIcon(for url: URL) {
        guard let settingsWindow else { return }
        let picker = NSOpenPanel()
        picker.allowedContentTypes = [.image]
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard let self, response == .OK, let source = picker.url,
                  self.providers.contains(where: { !$0.isPinned && $0.url == url }) else { return }
            do {
                let file = try FileHandle(forReadingFrom: source)
                defer { try? file.close() }
                let limit = 5 * 1024 * 1024
                guard let data = try file.read(upToCount: limit + 1), data.count <= limit,
                      let png = WebsiteFavicon.rasterPNG(data) else {
                    self.showIconError()
                    return
                }
                try ProviderIcon.setCustomIcon(png, for: url)
                self.refreshPicker()
                self.updateSettings()
            } catch {
                self.showIconError()
            }
        }
    }

    private func resetIcon(for url: URL) {
        do {
            try ProviderIcon.setCustomIcon(nil, for: url)
            refreshPicker()
            updateSettings()
            refreshFavicon(url)
        } catch {
            showIconError()
        }
    }

    private func showIconError() {
        guard let settingsWindow else { return }
        let alert = NSAlert()
        alert.messageText = AppText.t("Couldn’t use this icon.")
        alert.informativeText = AppText.t("Choose a PNG, JPEG, GIF, ICO, or WebP image under 5 MB.")
        alert.beginSheetModal(for: settingsWindow)
    }

    private func refreshFavicon(_ url: URL) {
        guard refreshingIcons.insert(url).inserted else { return }
        updateSettings()
        Task { [weak self] in
            let png = await WebsiteFavicon.fetch(for: url)
            guard let self else { return }
            self.refreshingIcons.remove(url)
            if let png, self.providers.contains(where: { !$0.isPinned && $0.url == url }) {
                ProviderIcon.store(png, for: url)
                self.refreshPicker()
            }
            self.updateSettings()
        }
    }

    func addWebsite(_ name: String, address: String, fetchIcon: Bool = true) -> Bool {
        guard let url = ProviderAddress.parse(address), !providers.contains(where: { $0.sessionID == nil && $0.url == url }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let selected = providers[selectedIndex].key
        if let website = websites.first(where: { $0.url == url || $0.key == url.absoluteString }) {
            guard deletedURLs.remove(website.key) != nil else { return false }
            disabledURLs.remove(website.key)
        } else {
            customProviders.append(Provider(name: name, url: url))
            deletedURLs.remove(url.absoluteString)
            disabledURLs.remove(url.absoluteString)
        }
        preferences.set(Array(deletedURLs), forKey: "deletedProviders")
        preferences.set(Array(disabledURLs), forKey: "disabledProviders")
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        saveCustomProviders(); refreshPicker(); updateSettings()
        if fetchIcon, !Self.builtIns.contains(where: { $0.url == url }) { refreshFavicon(url) }
        return true
    }
    @objc private func openInBrowser(_ sender: Any?) {
        let url = webView?.url ?? chatURL
        guard Self.isHTTPSPage(url) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func dismissPanel(_ sender: Any?) { hide(restoreFocus: true) }

    var selectedIndex = 0
    private var providerTabs: NSStackView?
    private var pinnedTabs: NSStackView?
    private weak var pinnedRow: NSStackView?
    var enabledTabIndices: [Int] {
        let enabled = providers.indices.filter { !disabledURLs.contains(providers[$0].key) }
        let instant = enabled.filter { !providers[$0].isPinned }
        let pinned = enabled.filter { providers[$0].isPinned }
        return pinnedFirst ? pinned + instant : instant + pinned
    }
    weak var chromeView: NSView?
    var pageColorObservation: NSKeyValueObservation?
    var surfaceColor = NSColor.windowBackgroundColor

    var pageAppearanceTimer: Timer?
    weak var contentStack: NSStackView?
    weak var resizeGrip: NSView?
    struct ParkedPage {
        let view: WKWebView
        let parkedAt: Date
        let isPinned: Bool
        var failureURL: URL? = nil
        var titleObservation: NSKeyValueObservation? = nil
    }
    var parkedPages: [String: ParkedPage] = [:]
    var evictionTimer: Timer?
    var chatURL: URL { providers[selectedIndex].conversationURL ?? providers[selectedIndex].url }

    func selectProvider(_ index: Int) {
        guard providers.indices.contains(index), !disabledURLs.contains(providers[index].key), index != selectedIndex else { return }
        rememberPinnedPage()
        parkActivePage()
        failureURL = nil
        crashReloads.removeAll()
        selectedIndex = index
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        if panel?.isVisible == true {
            attachSelectedPage()
        } else {
            updateTabSelection()
            prunePages()
        }
    }

    @objc private func providerChanged(_ sender: NSButton) {
        panel?.makeKey()
        if sender.tag == selectedIndex {
            sender.state = .on
            sender.needsDisplay = true
            focusSelectedPage()
            return
        }
        selectProvider(sender.tag)
    }
    @objc private func goBack(_ sender: Any?) { webView?.goBack() }
    @objc private func goForward(_ sender: Any?) { webView?.goForward() }
    @objc private func reloadPage(_ sender: Any?) { webView?.reload() }

    private func toolbarButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.controlSize = .small
        button.identifier = NSUserInterfaceItemIdentifier("toolbar:" + label)
        button.toolTip = AppText.t(label)
        button.setAccessibilityLabel(AppText.t(label))
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) { preferences.set(data, forKey: "customProviders") }
    }
    func refreshPicker() {
        guard let instant = providerTabs, let pinned = pinnedTabs else { return }
        for row in [instant, pinned] {
            for view in row.arrangedSubviews { row.removeArrangedSubview(view); view.removeFromSuperview() }
        }
        let enabled = enabledTabIndices
        let instantIndices = enabled.filter { !providers[$0].isPinned }
        let pinnedIndices = enabled.filter { providers[$0].isPinned }
        populateTabs(instant, indices: instantIndices)
        populateTabs(pinned, indices: pinnedIndices)
        pinnedRow?.isHidden = pinnedIndices.isEmpty
        if let group = pinnedRow, let separator = group.arrangedSubviews.first(where: { $0 is NSBox }), let document = instant.superview as? NSStackView {
            for child in group.arrangedSubviews { group.removeArrangedSubview(child); child.removeFromSuperview() }
            for child in pinnedFirst ? [pinned, separator] : [separator, pinned] { group.addArrangedSubview(child) }
            for child in document.arrangedSubviews { document.removeArrangedSubview(child); child.removeFromSuperview() }
            for child in pinnedFirst ? [group, instant] : [instant, group] { document.addArrangedSubview(child) }
        }
        if let document = providerTabs?.superview as? NSStackView {
            document.layoutSubtreeIfNeeded()
            document.setFrameSize(NSSize(width: document.fittingSize.width, height: 28))
        }
        updateTabSelection()
    }

    func updateTabSelection() {
        let provider = providers[selectedIndex]
        let tabs = (providerTabs?.arrangedSubviews ?? []) + (pinnedTabs?.arrangedSubviews ?? [])
        for case let button as ChatTabButton in tabs {
            let selected = button.tabKey == provider.key
            let state: NSControl.StateValue = selected ? .on : .off
            if button.state != state {
                button.state = state
                button.needsDisplay = true
            }
        }
        updateTabPreviews()
        syncReplyIndicators()
        let selectedKey = provider.key
        DispatchQueue.main.async { [weak self] in
            guard let self, self.providers[self.selectedIndex].key == selectedKey else { return }
            for case let button as ChatTabButton in (self.providerTabs?.arrangedSubviews ?? []) + (self.pinnedTabs?.arrangedSubviews ?? [])
                where button.tabKey == selectedKey {
                button.scrollToVisible(button.bounds)
            }
        }
    }

    private func updatePinButton() {
        pinButton?.image = NSImage(systemSymbolName: providers[selectedIndex].isPinned ? "pin.fill" : "pin", accessibilityDescription: "Pin Conversation")
        pinButton?.isEnabled = providers[selectedIndex].isPinned || webView?.url.map { canRemember($0, provider: providers[selectedIndex]) } == true
        pinButton?.toolTip = AppText.t(providers[selectedIndex].isPinned ? "Unpin and close this chat" : "Pin this conversation")
        pinButton?.setAccessibilityLabel(pinButton?.toolTip)
    }

    private func populateTabs(_ row: NSStackView, indices: [Int]) {
        for index in indices {
            let provider = providers[index]
            let button = ChatTabButton(image: ProviderIcon.image(for: provider.url, size: 20), target: self, action: #selector(providerChanged(_:)))
            button.tabKey = provider.key
            button.identifier = NSUserInterfaceItemIdentifier(provider.key)
            button.pinned = provider.isPinned
            button.onReorder = { [weak self] source, target in
                guard let self, let from = self.providers.firstIndex(where: { $0.key == source }), let to = self.providers.firstIndex(where: { $0.key == target }), from != to,
                      self.providers[from].isPinned == self.providers[to].isPinned else { return }
                self.reorderProviders(IndexSet(integer: from), to: from < to ? to + 1 : to)
            }
            button.isBordered = false
            button.setAccessibilityLabel(provider.isPinned ? displayName(provider) : provider.name)
            button.imageScaling = .scaleProportionallyDown
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 28).isActive = true
            button.tag = index
            button.setButtonType(.pushOnPushOff)
            button.state = index == selectedIndex ? .on : .off
            button.contextMenu = { [weak self] in self?.tabMenu(for: provider) }
            button.toolTip = preview(for: provider)
            row.addArrangedSubview(button)
        }
    }
    func saveSessions() {
        if let data = try? JSONEncoder().encode(savedSessions) { preferences.set(data, forKey: "pinnedSessions") }
    }
    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = AppText.t("Couldn’t change Launch at Login.")
            alert.informativeText = error.localizedDescription
            if let settingsWindow { alert.beginSheetModal(for: settingsWindow) }
        }
        updateSettings()
    }

    private func editEntry(_ index: Int) {
        guard providers.indices.contains(index), let settingsWindow else { return }
        let provider = providers[index]
        let alert = NSAlert()
        alert.messageText = AppText.t(provider.isPinned ? "Rename Pinned Chat" : "Edit Website")
        alert.addButton(withTitle: AppText.t("Save"))
        alert.addButton(withTitle: AppText.t("Cancel"))
        let name = NSTextField(string: displayName(provider))
        name.setAccessibilityLabel(AppText.t("Website name"))
        let address = NSTextField(string: provider.url.absoluteString)
        address.setAccessibilityLabel(AppText.t("Website address"))
        alert.accessoryView = Self.websiteEditorFields(provider.isPinned ? [name] : [name, address])
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if provider.isPinned {
                guard let i = self.savedSessions.firstIndex(where: { $0.key == provider.key }) else { return }
                self.savedSessions[i].manualTopic = title.isEmpty ? nil : String(title.prefix(100))
                self.saveSessions()
            } else {
                guard self.saveWebsiteEdit(provider, name: title, address: address.stringValue) else {
                    let warning = NSAlert()
                    warning.messageText = AppText.t("Enter a name and a unique HTTPS website address.")
                    warning.beginSheetModal(for: settingsWindow)
                    return
                }
            }
            self.prunePages()
            self.refreshPicker()
            self.updateSettings()
        }
    }

    static func websiteEditorFields(_ fields: [NSTextField]) -> NSView {
        let width: CGFloat = 310
        let rowHeight: CGFloat = 32
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight * CGFloat(fields.count)))
        accessory.autoresizingMask = [.width]
        for (index, field) in fields.enumerated() {
            field.frame = NSRect(x: 4, y: rowHeight * CGFloat(fields.count - index - 1) + 4,
                                 width: width - 8, height: 24)
            field.autoresizingMask = [.width]
            accessory.addSubview(field)
        }
        return accessory
    }

    func saveWebsiteEdit(_ provider: Provider, name: String, address: String, fetchIcon: Bool = true) -> Bool {
        guard !name.isEmpty, let url = ProviderAddress.parse(address),
              let current = providers.first(where: { !$0.isPinned && $0.key == provider.key }), current.url == provider.url,
              !websites.contains(where: { $0.key != provider.key && ($0.url == url || $0.key == url.absoluteString) }) else { return false }
        let builtInKey = Self.builtIns.first { $0.key == provider.key }?.key
        let edited = Provider(name: name, url: url, builtInKey: builtInKey)
        let selected = providers[selectedIndex].key
        if url != provider.url {
            if selected == provider.key { parkActivePage() }
            if let old = parkedPages.removeValue(forKey: provider.key) { releasePage(old.view) }
        }
        if edited.key != provider.key {
            providerOrder = providers.map { $0.key == provider.key ? edited.key : $0.key }
            deletedURLs.remove(edited.key)
            if disabledURLs.remove(provider.key) != nil { disabledURLs.insert(edited.key) }
            var zooms = preferences.dictionary(forKey: "websiteZoom") ?? [:]
            zooms[edited.key] = zooms.removeValue(forKey: provider.key)
            preferences.set(zooms, forKey: "websiteZoom")
            preferences.set(providerOrder, forKey: "providerOrder")
            preferences.set(Array(deletedURLs), forKey: "deletedProviders")
            preferences.set(Array(disabledURLs), forKey: "disabledProviders")
        }
        if let index = customProviders.firstIndex(where: { $0.key == provider.key }) {
            customProviders[index] = edited
        } else {
            customProviders.append(edited)
        }
        let key = selected == provider.key ? edited.key : selected
        selectedIndex = providers.firstIndex(where: { $0.key == key }) ?? 0
        preferences.set(key, forKey: "selectedProvider")
        saveCustomProviders()
        if url != provider.url {
            ProviderIcon.copyCustomIcon(from: provider.url, to: url)
            if fetchIcon { refreshFavicon(url) }
            if selected == provider.key, panel?.isVisible == true { attachSelectedPage() }
        }
        return true
    }

    func zoom(for provider: Provider) -> Double {
        let values = preferences.dictionary(forKey: "websiteZoom") ?? [:]
        let value = (values[provider.key] ?? values[provider.url.absoluteString]) as? Double ?? 1
        return (0.6...2).contains(value) ? value : 1
    }

    func setZoom(_ value: Double, for key: String) {
        var values = preferences.dictionary(forKey: "websiteZoom") ?? [:]
        values[key] = min(2, max(0.6, value))
        preferences.set(values, forKey: "websiteZoom")
        if providers[selectedIndex].key == key, let provider = providers.first(where: { $0.key == key }) {
            webView?.pageZoom = zoom(for: provider)
        }
    }

    private func changeZoom(for provider: Provider, by delta: Double?) {
        setZoom(delta.map { zoom(for: provider) + $0 } ?? 1, for: provider.key)
        updateSettings()
    }

    private func tabMenu(for provider: Provider) -> NSMenu {
        let page = provider.key == providers[selectedIndex].key ? webView : parkedPages[provider.key]?.view
        let host = page?.url?.host ?? provider.conversationURL?.host ?? provider.url.host ?? ""
        let menu = NSMenu()
        let identity = NSMenuItem(title: host, action: nil, keyEquivalent: "")
        identity.isEnabled = false
        menu.addItem(identity)
        menu.addItem(.separator())
        for (label, delta) in [("Zoom In", 0.1 as Double?), ("Zoom Out", -0.1), ("Actual Size", nil)] {
            menu.addItem(ActionMenuItem(AppText.t(label)) { [weak self] in self?.changeZoom(for: provider, by: delta) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(AppText.t("Reset Window Size")) { [weak self] in self?.panel?.resetSize() })
        return menu
    }

    func preview(for provider: Provider) -> String {
        if provider.isPinned { return displayName(provider) }
        let page = provider.key == providers[selectedIndex].key ? webView : parkedPages[provider.key]?.view
        return topicOnly(page?.title, provider: provider) ?? AppText.t("New chat")
    }

    func displayName(_ provider: Provider) -> String {
        if let label = provider.manualTopic { return label }
        if provider.isPinned { return topicOnly(provider.topic, provider: provider) ?? AppText.t("New chat") }
        return provider.name
    }

    private func topicOnly(_ title: String?, provider: Provider) -> String? {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        let names = Set([provider.name, Self.builtIns.first { $0.url.host == provider.url.host }?.name ?? provider.name])
        for name in names {
            let prefix = name + ": "
            if title.lowercased().hasPrefix(prefix.lowercased()) { title = String(title.dropFirst(prefix.count)) }
            for suffix in [" - " + name, " | " + name, " | " + (provider.url.host ?? "")] where title.lowercased().hasSuffix(suffix.lowercased()) {
                title = String(title.dropLast(suffix.count))
            }
        }
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeholders = names.map { $0.lowercased() } + ["", "new chat", "new conversation", "untitled", "loading…", "loading...", "新对话", "新聊天", "新建对话", "無標題"]
        return placeholders.contains(title.lowercased()) ? nil : String(title.prefix(100))
    }

    func updateTabPreviews() { updateTabPreview(key: providers[selectedIndex].key) }

    private func updateTabPreview(key: String) {
        guard let provider = providers.first(where: { $0.key == key }) else { return }
        let tabs = (providerTabs?.arrangedSubviews ?? []) + (pinnedTabs?.arrangedSubviews ?? [])
        for case let button as ChatTabButton in tabs where button.tabKey == provider.key {
            button.toolTip = preview(for: provider)
            button.setAccessibilityLabel(provider.isPinned ? displayName(provider) : provider.name)
        }
        if key == providers[selectedIndex].key { updatePinButton() }
    }
    func canRemember(_ url: URL, provider: Provider) -> Bool {
        Self.isConversationURL(url, provider: provider)
    }
    private static func isConversationURL(_ url: URL, provider: Provider) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              ProviderAddress.matchesWebsite(host: url.host, baseHost: provider.url.host) else { return false }
        let parts = Set(url.path.lowercased().split(separator: "/").map(String.init))
        let sensitiveQuery = Set((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name.lowercased() })
        let fragment = url.fragment?.lowercased() ?? ""
        let sensitiveNames = ["code", "token", "access_token", "refresh_token", "id_token", "password", "credential", "assertion", "session_token"]
        guard !sensitiveNames.contains(where: { fragment.contains($0 + "=") }) else { return false }
        return parts.isDisjoint(with: ["login", "signin", "sign-in", "sign_in", "signup", "sign-up", "sign_up", "auth", "oauth", "oauth2", "logout"])
            && sensitiveQuery.isDisjoint(with: sensitiveNames)
    }
    func rememberPinnedPage() {
        let pin = providers[selectedIndex]
        guard let webView, let url = webView.url, pin.conversationURL == url else { return }
        if topicOnly(webView.title, provider: pin) != nil {
            rememberPinnedTitle(webView.title, at: url, for: pin.key)
        } else if topicOnly(pin.topic, provider: pin) == nil {
            // Some web apps keep a generic document title but label the selected conversation in navigation.
            webView.evaluateJavaScript("""
                (() => {
                    const links = document.querySelectorAll('nav a[aria-current="page"], [role="navigation"] a[aria-current="page"]');
                    for (const link of links) {
                        if (link.href === location.href) return (link.innerText || '').trim().slice(0, 100);
                    }
                    return null;
                })()
                """, in: nil, in: .defaultClient) { [weak self, weak webView] result in
                    guard let self, webView?.url == url, case .success(let value) = result,
                          let current = self.savedSessions.first(where: { $0.key == pin.key }),
                          self.topicOnly(current.topic, provider: current) == nil else { return }
                    self.rememberPinnedTitle(value as? String, at: url, for: pin.key)
                }
        }
    }

    func rememberPinnedTitle(_ pageTitle: String?, at url: URL?, for key: String) {
        guard let url,
              let index = savedSessions.firstIndex(where: { $0.key == key && $0.conversationURL == url }),
              let topic = topicOnly(pageTitle, provider: savedSessions[index]),
              savedSessions[index].topic != topic else { return }
        savedSessions[index].topic = topic
        saveSessions()
        updateTabPreview(key: key)
        if settingsWindow?.isVisible == true { updateSettings() }
    }

    func unpinProvider(_ index: Int) {
        guard providers.indices.contains(index), providers[index].isPinned else { return }
        if index == selectedIndex { togglePin(nil) }
        else { deleteProvider(index) }
    }
    @objc func togglePin(_ sender: Any?) {
        togglePin(url: webView?.url, title: webView?.title)
    }
    func togglePin(url: URL?, title: String?) {
        var provider = providers[selectedIndex]
        let oldKey = provider.key
        let oldZoom = zoom(for: provider)
        if provider.isPinned {
            var destination = enabledTabIndices.first { !providers[$0].isPinned && providers[$0].url == provider.url }
                ?? enabledTabIndices.first { !providers[$0].isPinned }
            if destination == nil {
                let existing = websites.first { $0.url == provider.url || $0.key == provider.url.absoluteString }
                let instantKey = existing?.key ?? provider.url.absoluteString
                if existing == nil {
                    customProviders.append(Provider(name: provider.name, url: provider.url))
                    saveCustomProviders()
                }
                deletedURLs.remove(instantKey)
                disabledURLs.remove(instantKey)
                preferences.set(Array(deletedURLs), forKey: "deletedProviders")
                preferences.set(Array(disabledURLs), forKey: "disabledProviders")
                selectedIndex = providers.firstIndex(where: { $0.key == oldKey })!
                destination = providers.firstIndex(where: { $0.key == instantKey })
            }
            // Unpin closes the saved tab. It never replaces or discards an existing instant page.
            if let view = webView {
                cancelPageAppearance()
                panel?.detachKeyboardFromPage(view)
                contentStack?.removeArrangedSubview(view)
                view.removeFromSuperview()
                releasePage(view)
                webView = nil
            }
            if let destination { selectProvider(destination) }
            if let closing = providers.firstIndex(where: { $0.key == oldKey }) { deleteProvider(closing) }
            pinFeedback()

            return
        } else {
            guard let url, canRemember(url, provider: provider) else { NSSound.beep(); return }
            provider.sessionID = UUID().uuidString
            provider.pinned = true
            provider.conversationURL = url
            provider.topic = topicOnly(title, provider: provider)
            savedSessions.append(provider)
            selectedIndex = providers.firstIndex(where: { $0.key == provider.key }) ?? selectedIndex
            setZoom(oldZoom, for: provider.key)
            pinFeedback()
        }
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        saveSessions(); refreshPicker(); updateSettings()
        rememberPinnedPage()
    }

    private func pinFeedback() {
        guard panel?.isVisible == true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    func isProviderHost(_ host: String?, provider: Provider) -> Bool {
        ProviderAddress.matchesWebsite(host: host, baseHost: provider.url.host)
    }
    /// OpenAI's sign-in hosts (and their subdomains): where sign-in starts from a chatgpt.com page.
    static let openAISignInHosts = ["auth.openai.com", "auth0.openai.com"]
    static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    let log = Log.make("FloatChat")
    var panel: FloatChatPanel?
    var webView: WKWebView?
    private var previousApp: NSRunningApplication?
    /// When the panel was last shown / last lost key, and until when a Space switch may not
    /// take its focus (see `spaceDidChange()`).
    private var isHiding = false
    private var shownAt: Date?
    private var lostKeyAt: Date?
    private var keepFocusUntil: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Where each in-flight download is being written, for "reveal in Finder" when it finishes.
    var downloads: [ObjectIdentifier: (download: WKDownload, destination: URL)] = [:]
    /// Recent automatic reloads after the web content process died, to stop a crash loop.
    var crashReloads: [Date] = []
    private var connectivity: NWPathMonitor?
    var offline = false
    private var slowPageTimer: Timer?
    private var slowPage = false
    var waitingForPage = false

    private func observeSystemState() {
        guard connectivity == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let offline = path.status == .unsatisfied
            Task { @MainActor in
                guard let self, self.offline != offline else { return }
                self.offline = offline
                self.updateStatus()
            }
        }
        monitor.start(queue: .main)
        connectivity = monitor
    }

    func trackPageLoad(_ view: WKWebView) {
        stopTrackingPageLoad()
        guard view.isLoading else { return }
        waitingForPage = true
        updateStatus()
        slowPageTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, let view, self.webView === view, view.isLoading else { return }
                self.slowPage = true
                self.updateStatus()
            }
        }
    }

    func stopTrackingPageLoad() {
        slowPageTimer?.invalidate()
        slowPageTimer = nil
        slowPage = false
        waitingForPage = false
    }

    /// Local shortcut (only while the panel is key) that triggers the panel's `resetSize()`.
    var resetSizeShortcut = Shortcut.loadResetSize() {
        didSet { panel?.resetSizeShortcut = resetSizeShortcut }
    }

    /// Local shortcut (only while the panel is key) that toggles maximize, like the green button.
    var maximizeShortcut = Shortcut.loadMaximize() {
        didSet { panel?.maximizeShortcut = maximizeShortcut }
    }

    /// Hides the panel whenever it's visible on the current Space (focused or not), otherwise
    /// shows it here. Focus goes back to the previous app only if the panel had it.
    func toggle() {
        if let panel, panel.isVisible, panel.isOnActiveSpace {
            hide(restoreFocus: panel.isKeyWindow)
        } else {
            show()
        }
    }

    func show() {
        guard !clearingWebsiteData else { return }
        let panel = self.panel ?? makePanel()
        if centerOnOpen, !panel.isVisible { center(panel, on: NSScreen.screens.first) }
        keepPanelReachable(panel)
        attachSelectedPage()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        // Don't activate the app: activation is only a request since macOS 14, and after a
        // Space switch macOS hands focus on to another app (Finder, the full-screen app) and the
        // panel loses the keyboard. A non-activating panel takes key without it, like Spotlight.
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        focusSelectedPage()
        shownAt = .now
        syncReplyIndicators()
    }

    /// A Space switch makes macOS activate an app on the new Space (Finder on the desktop, the
    /// full-screen app), which takes the keyboard from the panel; that includes a switch still
    /// landing just after ⌥Space. If the panel had focus (or was just shown), take it back.
    private func observeSpaceChanges() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.spaceDidChange() }
            },
            // The new Space's app can activate just after the Space-change notification.
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                               queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated {
                    self?.otherAppActivated(app)
                }
            },
        ]
    }

    /// Keeps `previousApp` current while the panel is open, so hiding returns focus to the app
    /// you're in now; not the one from when the panel opened, which may sit on another Space
    /// (activating it would switch back there).
    private func otherAppActivated(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              panel?.isVisible == true else { return }
        keepFocusUntil = nil
        previousApp = app
        if hideOnClickAway, panel?.attachedSheet == nil, NSApp.modalWindow == nil { hide(restoreFocus: false) }
    }

    private func spaceDidChange() {
        guard let panel, panel.isVisible else { return }
        let recent = { (date: Date?) in date.map { Date.now.timeIntervalSince($0) < 1 } ?? false }
        guard panel.isKeyWindow || recent(lostKeyAt) || recent(shownAt) else { return }
        keepFocusUntil = .now.addingTimeInterval(1)
        reclaimFocusIfKept()
    }

    private func reclaimFocusIfKept() {
        guard let until = keepFocusUntil, Date.now < until,
              let panel, panel.isVisible, panel.isOnActiveSpace, settingsWindow?.isKeyWindow != true else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let until = self.keepFocusUntil, Date.now < until,
                  let panel = self.panel, panel.isVisible, panel.isOnActiveSpace, !panel.isKeyWindow,
                  self.settingsWindow?.isKeyWindow != true else { return }
            panel.makeKeyAndOrderFront(nil)
            self.focusSelectedPage()
        }
    }

    /// `restoreFocus`: give focus back to the app that was frontmost before showing.
    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        defer { isHiding = false }
        rememberPinnedPage()
        keepFocusUntil = nil
        panel.orderOut(nil)
        recentDownload = nil
        parkActivePage()
        failureURL = nil
        prunePages()
        if restoreFocus { previousApp?.activate() }
    }

    /// A single floating indicator when hidden, and small markers on background tabs when open.
    func syncReplyIndicators() {
        let keys = generationIndicator.generatingKeys
        let tabs = (providerTabs?.arrangedSubviews ?? []) + (pinnedTabs?.arrangedSubviews ?? [])
        for case let button as ChatTabButton in tabs { button.generating = keys.contains(button.tabKey) }
        guard let panel, !panel.isVisible, !keys.isEmpty else {
            generationIndicator.hide()
            return
        }
        generationIndicator.show(near: panel.frame) { [weak self] in
            guard let self, let key = self.generationIndicator.mostRecentKey else { return }
            if let index = self.providers.firstIndex(where: { $0.key == key }) { self.selectProvider(index) }
            self.show()
        }
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
        pinnedDrafts.clear()
        generationIndicator.stop()
        cancelPageAppearance()
        stopTrackingPageLoad()
        connectivity?.cancel()
        connectivity = nil
        offline = false
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        failureURL = nil
        recentDownload = nil
        panel?.orderOut(nil)
        if let webView { releasePage(webView) }
        panel?.contentView = nil
        panel = nil
        webView = nil
        providerTabs = nil
        pinnedTabs = nil
        pinnedRow = nil
        contentStack = nil
        evictionTimer?.invalidate()
        evictionTimer = nil
        for page in parkedPages.values { releasePage(page.view) }
        parkedPages.removeAll()
        chromeView = nil
        surfaceColor = .windowBackgroundColor
        pageColorObservation = nil
        pageURLObservation = nil
        pageTitleObservation = nil
        crashReloads = []
    }

    // MARK: Building

    private func makePanel() -> FloatChatPanel {
        let panel = FloatChatPanel(contentRect: NSRect(origin: .zero, size: FloatChatPanel.defaultSize))
        panel.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        panel.onGoBack = { [weak self] in self?.webView?.goBack() }
        panel.onGoForward = { [weak self] in self?.webView?.goForward() }
        panel.onResignKey = { [weak self, weak panel] in
            guard let self else { return }
            self.lostKeyAt = .now
            if self.hideOnClickAway, let panel, panel.attachedSheet == nil, NSApp.modalWindow == nil,
               let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown,
               event.window !== panel, event.window !== self.settingsWindow {
                self.hide(restoreFocus: false)
            } else if !self.hideOnClickAway {
                self.reclaimFocusIfKept()
            }
        }
        observeSpaceChanges()
        observeSystemState()
        NotificationCenter.default.addObserver(self, selector: #selector(screenConfigurationChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        panel.resetSizeShortcut = resetSizeShortcut
        panel.maximizeShortcut = maximizeShortcut

        if let saved = preferences.string(forKey: "selectedProvider"),
           let index = providers.firstIndex(where: { $0.key == saved }) { selectedIndex = index }
        if disabledURLs.contains(providers[selectedIndex].key), let next = providers.firstIndex(where: { !disabledURLs.contains($0.key) }) { selectedIndex = next }
        let header = DraggableView()
        chromeView = header
        header.toolTip = "Drag to move · Double-click to expand"
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.spacing = 4
        let pins = NSStackView()
        pins.orientation = .horizontal
        pins.spacing = 4
        let separator = NSBox()
        separator.boxType = .separator
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        let pinnedGroup = NSStackView(views: [separator, pins])
        pinnedGroup.spacing = 10
        let document = NSStackView(views: [tabs, pinnedGroup])
        document.spacing = 10
        document.orientation = .horizontal
        document.detachesHiddenViews = true
        document.autoresizingMask = []
        let scroll = ChatTabScrollView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .none
        scroll.verticalScrollElasticity = .none
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(scroll)
        let close = toolbarButton("xmark", label: "Hide Chat", action: #selector(dismissPanel(_:)))
        header.addSubview(close)
        let pin = toolbarButton("pin", label: "Pin Conversation", action: #selector(togglePin(_:)))
        pinButton = pin
        let browser = toolbarButton("arrow.up.right.square", label: "Continue in Default Browser", action: #selector(openInBrowser(_:)))
        let settings = toolbarButton("slider.horizontal.3", label: "Settings", action: #selector(showSettings))
        let controls = NSStackView(views: [pin, browser, settings])
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(controls)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -12),
            scroll.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 28),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -12),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        providerTabs = tabs
        pinnedTabs = pins
        pinnedRow = pinnedGroup
        let stack = NSStackView(views: [header, identityRow(), statusRow()])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets()
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.wantsLayer = true
        stack.layer?.allowsGroupOpacity = true
        stack.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        contentStack = stack
        // Clip the complete window surface so the backdrop and WebKit share one silhouette.
        let root = NSView()
        root.wantsLayer = true
        root.layer?.cornerCurve = .continuous
        root.layer?.cornerRadius = FloatChatPanel.surfaceCornerRadius
        root.layer?.masksToBounds = true
        let backdrop: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = FloatChatPanel.surfaceCornerRadius
            backdrop = glass
        } else {
            let material = NSVisualEffectView()
            material.material = .hudWindow
            material.blendingMode = .behindWindow
            material.state = .active
            backdrop = material
        }
        glassBackdrop = backdrop
        applySurfaceAppearance()
        for layer in [backdrop, stack] {
            layer.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(layer)
            NSLayoutConstraint.activate([
                layer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                layer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                layer.topAnchor.constraint(equalTo: root.topAnchor),
                layer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
            ])
        }
        panel.contentView = root
        let grip = ResizeGrip()
        resizeGrip = grip
        grip.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(grip)
        NSLayoutConstraint.activate([
            grip.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -2),
            grip.bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: -2),
            grip.widthAnchor.constraint(equalToConstant: 18),
            grip.heightAnchor.constraint(equalToConstant: 18)
        ])
        panel.onSelectProvider = { [weak self] offset in
            guard let self else { return }
            let enabled = self.enabledTabIndices
            if enabled.indices.contains(offset) { self.selectProvider(enabled[offset]) }
        }


        panel.zoomKeysEnabled = zoomKeysEnabled
        panel.onPageZoom = { [weak self] delta in
            guard let self else { return }
            self.changeZoom(for: self.providers[self.selectedIndex], by: delta)
        }
        if centerOnOpen || !panel.setFrameUsingName(FloatChatPanel.autosaveName) {
            center(panel)
        }
        panel.remembersFrame = !centerOnOpen

        self.panel = panel
        refreshPicker()
        return panel
    }

    private weak var glassBackdrop: NSView?
    var failureURL: URL?
    var recentDownload: URL?
    private weak var identityLabel: NSTextField?
    private weak var notice: NSStackView?
    private weak var noticeLabel: NSTextField?
    private weak var noticeAction: NSButton?
    private weak var noticeBrowser: NSButton?

    private func identityRow() -> NSView {
        let label = NSTextField(labelWithString: "")
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.heightAnchor.constraint(equalToConstant: 22).isActive = true
        label.isHidden = true
        identityLabel = label
        return label
    }

    func updateWebsiteIdentity() {
        let provider = providers[selectedIndex]
        let host = webView?.url?.host
        identityLabel?.stringValue = host ?? ""
        identityLabel?.isHidden = host == nil || isProviderHost(host, provider: provider)
    }

    private func statusRow() -> NSView {
        let label = NSTextField(labelWithString: "")
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let action = NSButton(title: "", target: self, action: #selector(noticeActionClicked))
        let browser = NSButton(title: AppText.t("Open in Browser"), target: self, action: #selector(openFailedPage))
        let row = NSStackView(views: [label, action, browser])
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.spacing = 8
        row.isHidden = true
        notice = row
        noticeLabel = label
        noticeAction = action
        noticeBrowser = browser
        return row
    }

    var retryURL: URL? {
        if let failureURL { return failureURL }
        return slowPage || (offline && waitingForPage) ? chatURL : nil
    }

    func updateStatus() {
        let message: String?
        if offline { message = "You’re offline." }
        else if failureURL != nil { message = "Couldn’t load this website." }
        else if slowPage { message = "Still loading…" }
        else if waitingForPage { message = "Loading…" }
        else if recentDownload != nil { message = "Downloaded" }
        else { message = nil }

        notice?.isHidden = message == nil
        noticeBrowser?.isHidden = retryURL == nil
        noticeAction?.isHidden = retryURL == nil && (waitingForPage || offline)
        noticeLabel?.stringValue = message.map(AppText.t) ?? ""
        noticeAction?.title = AppText.t(retryURL == nil ? "Show in Finder" : "Retry")
    }

    @objc private func noticeActionClicked() {
        if let url = retryURL {
            crashReloads.removeAll()
            failureURL = nil
            stopTrackingPageLoad()
            updateStatus()
            webView?.load(pageRequest(url))
        } else if let url = recentDownload {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            recentDownload = nil
            updateStatus()
        }
    }

    @objc private func openFailedPage() {
        if let url = retryURL { NSWorkspace.shared.open(url) }
    }

    func pageFailed(_ view: WKWebView, error: Error) {
        let error = error as NSError
        guard !(error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled),
              !(error.domain == "WebKitErrorDomain" && error.code == 102) else { return }
        let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if view === webView {
            stopTrackingPageLoad()
            failureURL = url.flatMap { canRemember($0, provider: providers[selectedIndex]) ? $0 : nil } ?? chatURL
            updateStatus()
        } else if let key = parkedPages.first(where: { $0.value.view === view })?.key,
                  let provider = providers.first(where: { $0.key == key }) {
            parkedPages[key]?.failureURL = url.flatMap { canRemember($0, provider: provider) ? $0 : nil } ?? provider.conversationURL ?? provider.url
        }
    }

    @objc private func screenConfigurationChanged() {
        if let panel, panel.isVisible { keepPanelReachable(panel) }
    }

    func keepPanelReachable(_ panel: NSPanel) {
        guard let screen = NSScreen.screens.max(by: {
            let lhs = $0.visibleFrame.intersection(panel.frame)
            let rhs = $1.visibleFrame.intersection(panel.frame)
            return lhs.width * lhs.height < rhs.width * rhs.height
        }) else { return }
        let visible = screen.visibleFrame
        let overlap = visible.intersection(panel.frame)
        if overlap.width < 100 || overlap.height < 48 {
            center(panel)
            return
        }
        var frame = panel.frame
        frame.size.width = min(frame.width, visible.width)
        frame.size.height = min(frame.height, visible.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    private func center(_ panel: NSPanel, on preferredScreen: NSScreen? = nil) {
        let mouse = NSEvent.mouseLocation
        let screen = preferredScreen ?? NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = NSSize(width: min(panel.frame.width, visible.width),
                          height: min(panel.frame.height, visible.height))
        panel.setFrame(NSRect(x: visible.midX - size.width / 2,
                              y: visible.minY + (visible.height - size.height) * 0.6,
                              width: size.width, height: size.height), display: true)
    }


}

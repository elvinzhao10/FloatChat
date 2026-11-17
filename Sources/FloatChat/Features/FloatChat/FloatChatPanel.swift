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
    private struct Provider: Codable {
        var name: String
        var url: URL
        var sessionID: String? = nil
        var conversationURL: URL? = nil
        var topic: String? = nil
        var pinned: Bool? = nil
        var manualTopic: String? = nil
        var key: String { sessionID ?? url.absoluteString }
        var isPinned: Bool { pinned == true }
    }
    private static let doubaoURL = URL(string: "https://www.doubao.com/chat/")!
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
    private let preferences: UserDefaults
    private var customProviders: [Provider] = []
    private var savedSessions: [Provider] = []
    private var pageURLObservation: NSKeyValueObservation?
    private var pageTitleObservation: NSKeyValueObservation?
    private weak var pinButton: NSButton?
    private var deletedURLs: Set<String> = []
    private var providerOrder: [String] = []

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        super.init()
        if let data = preferences.data(forKey: "customProviders"),
           let stored = try? JSONDecoder().decode([Provider].self, from: data) {
            var seen = Set(Self.builtIns.filter { $0.url != Self.doubaoURL }.map { $0.url.absoluteString })
            customProviders = stored.compactMap { provider in
                guard let url = ProviderAddress.parse(provider.key), seen.insert(url.absoluteString).inserted else { return nil }
                return Provider(name: provider.name, url: url)
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
    }
    private var providers: [Provider] {
        let available = (Self.builtIns.filter { builtIn in !customProviders.contains { $0.url == builtIn.url } } + customProviders + savedSessions).filter { !deletedURLs.contains($0.key) }
        return available.enumerated().sorted { lhs, rhs in
            let a = providerOrder.firstIndex(of: lhs.element.key) ?? (providerOrder.count + lhs.offset)
            let b = providerOrder.firstIndex(of: rhs.element.key) ?? (providerOrder.count + rhs.offset)
            return a < b
        }.map(\.element)
    }

    private var disabledURLs: Set<String> = []
    private var pinnedFirst: Bool { preferences.bool(forKey: "pinnedFirst") }
    private var language: String { preferences.string(forKey: "appLanguage") ?? "en" }
    private var settingsWindow: NSWindow?
    private var clearingWebsiteData = false
    private var panelTranslucency: Double {
        let legacyValue = preferences.bool(forKey: "glassEnabled") ? 16.0 : 0.0
        let value = preferences.object(forKey: "panelTranslucency") as? Double ?? legacyValue
        return min(40, max(0, value))
    }

    private func setPanelTranslucency(_ value: Double) {
        let wasTranslucent = panelTranslucency > 0
        preferences.set(value, forKey: "panelTranslucency")
        settingsFields.panelTranslucency = panelTranslucency
        applySurfaceAppearance()
        if wasTranslucent != (panelTranslucency > 0), let webView { matchPageEdge(webView) }
    }

    private func applySurfaceAppearance() {
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
    private var hideOnClickAway: Bool { preferences.bool(forKey: "hideOnClickAway") }
    private var zoomKeysEnabled: Bool { preferences.object(forKey: "zoomKeysEnabled") as? Bool ?? true }

    private func setPanelPreference(_ enabled: Bool, for key: String) {
        preferences.set(enabled, forKey: key)
        if key == "centerOnOpen" {
            panel?.remembersFrame = !enabled
        } else if key == "zoomKeysEnabled" {
            panel?.zoomKeysEnabled = enabled
        }
        updateSettings()
    }
    private var refreshingIcons: Set<URL> = []
    private let settingsFields = ChatSettingsFields()

    var configureShortcut: (() -> Void)?
    var shortcutControls: (() -> [ChatSettingsView.ShortcutControl])?

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
            NSWorkspace.shared.open(URL(string: "https://github.com/elvinzhao10/FloatChat/releases/latest")!)
        }
        updates.image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)
        return [open, switchChat, .separator(), settings, updates]
    }
    private func reorderProviders(_ offsets: IndexSet, to destination: Int) {
        let selected = providers[selectedIndex].key
        var ordered = providers.map(\.key)
        ordered.move(fromOffsets: offsets, toOffset: destination)
        providerOrder = ordered
        preferences.set(ordered, forKey: "providerOrder")
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        refreshPicker(); updateSettings()
    }
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
    private func deleteProvider(_ index: Int) {
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
        if provider.sessionID == nil { customProviders.removeAll { $0.url == provider.url && $0.sessionID == nil } }
        savedSessions.removeAll { $0.key == key }
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
    private func toggleProvider(_ index: Int) {
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
                ChatSettingsView.Row(id: provider.key, index: index, name: displayName(provider), url: provider.url, pinned: provider.isPinned, custom: provider.sessionID == nil && customProviders.contains(where: { $0.url == provider.url }), refreshingIcon: refreshingIcons.contains(provider.url), enabled: !disabledURLs.contains(provider.key))
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
    private func pageRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let tag = AppText.webTag(for: language)
        let primary = String(tag.split(separator: "-").first ?? "en")
        request.setValue("\(tag),\(primary);q=0.9", forHTTPHeaderField: "Accept-Language")
        return request
    }
    private func configureScripts(_ scripts: WKUserContentController) {
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
                  self.customProviders.contains(where: { $0.url == url }) else { return }
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
            if let png, self.customProviders.contains(where: { $0.url == url }) {
                ProviderIcon.store(png, for: url)
                self.refreshPicker()
            }
            self.updateSettings()
        }
    }

    private func addWebsite(_ name: String, address: String, fetchIcon: Bool = true) -> Bool {
        guard let url = ProviderAddress.parse(address), !providers.contains(where: { $0.sessionID == nil && $0.url == url }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let selected = providers[selectedIndex].key
        deletedURLs.remove(url.absoluteString)
        preferences.set(Array(deletedURLs), forKey: "deletedProviders")
        if !Self.builtIns.contains(where: { $0.url == url }) { customProviders.append(Provider(name: name, url: url)) }
        disabledURLs.remove(url.absoluteString)
        preferences.set(Array(disabledURLs), forKey: "disabledProviders")
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        saveCustomProviders(); refreshPicker(); updateSettings()
        if fetchIcon, customProviders.contains(where: { $0.url == url }) { refreshFavicon(url) }
        return true
    }
    @objc private func openInBrowser(_ sender: Any?) {
        let url = webView?.url ?? chatURL
        guard Self.isHTTPSPage(url) else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func dismissPanel(_ sender: Any?) { hide(restoreFocus: true) }

    private var selectedIndex = 0
    private var providerTabs: NSStackView?
    private var pinnedTabs: NSStackView?
    private weak var pinnedRow: NSStackView?
    private var enabledTabIndices: [Int] {
        let enabled = providers.indices.filter { !disabledURLs.contains(providers[$0].key) }
        let instant = enabled.filter { !providers[$0].isPinned }
        let pinned = enabled.filter { providers[$0].isPinned }
        return pinnedFirst ? pinned + instant : instant + pinned
    }
    private weak var contentStack: NSStackView?
    private weak var resizeGrip: NSView?
    private struct ParkedPage {
        let view: WKWebView
        let parkedAt: Date
        let isPinned: Bool
        var failureURL: URL? = nil
    }
    private var parkedPages: [String: ParkedPage] = [:]
    private var evictionTimer: Timer?
    private func retentionMinutes(forPinned pinned: Bool) -> Int {
        let legacy = preferences.object(forKey: "retentionMinutes") as? Int ?? 10
        let value = pinned ? preferences.object(forKey: "pinnedRetentionMinutes") as? Int ?? legacy : legacy
        return ChatSettingsView.retentionOptions.contains(value) ? value : 10
    }

    private func setRetention(_ minutes: Int, forPinned pinned: Bool) {
        if !pinned, preferences.object(forKey: "pinnedRetentionMinutes") == nil {
            preferences.set(retentionMinutes(forPinned: true), forKey: "pinnedRetentionMinutes")
        }
        preferences.set(minutes, forKey: pinned ? "pinnedRetentionMinutes" : "retentionMinutes")
        prunePages()
        updateSettings()
    }
    private func releasePage(_ view: WKWebView) {
        view.stopLoading()
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setCameraCaptureState(.none, completionHandler: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
    private func prunePages(at now: Date = .now) {
        evictionTimer?.invalidate()
        evictionTimer = nil
        let instantLifetime = Double(retentionMinutes(forPinned: false)) * 60
        let pinnedLifetime = Double(retentionMinutes(forPinned: true)) * 60
        var nextExpiry: Date?
        for (key, page) in parkedPages {
            let expiry = page.parkedAt.addingTimeInterval(page.isPinned ? pinnedLifetime : instantLifetime)
            if expiry <= now {
                releasePage(page.view)
                parkedPages.removeValue(forKey: key)
            } else {
                nextExpiry = min(nextExpiry ?? expiry, expiry)
            }
        }
        if let nextExpiry {
            evictionTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, nextExpiry.timeIntervalSince(now)),
                                                repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.prunePages() }
            }
            evictionTimer?.tolerance = 1
        }
    }

    private func takeParkedPage(for provider: Provider) -> ParkedPage? {
        guard let page = parkedPages.removeValue(forKey: provider.key) else { return nil }
        if let pinnedURL = provider.conversationURL, let currentURL = page.view.url, currentURL != pinnedURL {
            releasePage(page.view)
            return nil
        }
        return page
    }
    private func observePageColor(_ view: WKWebView) {
        pageURLObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated {
                guard let self, self.webView === view else { return }
                self.rememberPinnedPage()
                self.updateWebsiteIdentity()
                self.matchPageEdge(view)
            }
        }
        pageTitleObservation = view.observe(\.title, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { if self?.webView === view { self?.rememberPinnedPage(); self?.updateTabPreviews() } }
        }
        pageColorObservation = view.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.syncPageChrome(view) }
        }
    }

    private weak var chromeView: NSView?
    private var pageColorObservation: NSKeyValueObservation?
    private var surfaceColor = NSColor.windowBackgroundColor

    /// WebKit reports the page canvas color as it changes, including website theme switches.
    /// Match the native controls to that canvas without changing the site's layout or DOM.
    private func syncPageChrome(_ webView: WKWebView) {
        if let color = webView.underPageBackgroundColor,
           panelTranslucency == 0 || color.alphaComponent == 1 {
            setSurfaceColor(color)
        }
        matchPageEdge(webView)
    }

    private func setSurfaceColor(_ color: NSColor) {
        surfaceColor = color
        applySurfaceAppearance()
        if let rgb = color.usingColorSpace(.sRGB) {
            let brightness = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            chromeView?.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
        }
    }
    private func matchPageEdge(_ view: WKWebView) {
        guard view === webView, let url = view.url else { return }
        // Older WebKit versions have no public switch for the document's opaque base fill.
        // Gate the rendering-only setting and keep the page opaque if WebKit lacks it.
        let canClearBase = view.responds(to: NSSelectorFromString("_setDrawsBackground:"))
        let translucent = panelTranslucency > 0 && canClearBase
        if canClearBase, (view.value(forKey: "drawsBackground") as? Bool) != !translucent {
            view.setValue(!translucent, forKey: "drawsBackground")
        }

        let script = #"""
            (() => {
                const previous = globalThis.floatChatCanvas;
                previous?.stop();
                const marker = 'data-floatchat-canvas';
                const translucent = \#(translucent);
                const root = document.documentElement;
                let marked = previous?.surfaces ?? new Set();
                let watched = new Set();
                let pending = null;
                const schedule = () => {
                    if (pending !== null) return;
                    pending = setTimeout(() => {
                        pending = null;
                        update(false);
                    }, 40);
                };
                const observer = translucent ? new MutationObserver(schedule) : null;

                const update = readColor => {
                    let sheet = document.getElementById('floatchat-canvas');
                    if (readColor && sheet?.sheet) sheet.sheet.disabled = true;
                    const surfaces = new Set();
                    const roots = new Set([root]);
                    if (document.body) roots.add(document.body);
                    const geometry = new Map();
                    const colors = new Map();

                    const sample = (y, sampleColor) => [0.08, 0.5, 0.92].map(position => {
                        let sampled = null;
                        let node = document.elementFromPoint(Math.floor(innerWidth * position), y);
                        while (node) {
                            if (!geometry.has(node)) geometry.set(node, node.getBoundingClientRect());
                            const size = geometry.get(node);
                            const canvas = size.width >= innerWidth * 0.9 && size.height >= innerHeight * 0.5;
                            const fullWidth = size.left <= 2 && size.right >= innerWidth - 2;
                            const top = fullWidth && size.top <= 1 && size.bottom > 1 && size.height <= innerHeight * 0.25;
                            const bottom = fullWidth && size.top < innerHeight - 2 && size.bottom >= innerHeight - 2
                                && !node.matches('button, input, textarea, [contenteditable], [role="dialog"]');
                            if (canvas || top || bottom) {
                                surfaces.add(node);
                                if (sampleColor && !sampled) {
                                    if (!colors.has(node)) {
                                        const color = getComputedStyle(node).backgroundColor;
                                        colors.set(node, /^rgb\(/.test(color) ? color.match(/[0-9.]+/g)?.map(Number) : null);
                                    }
                                    sampled = colors.get(node);
                                }
                            }
                            node = node.parentElement;
                        }
                        return sampled;
                    });

                    const top = sample(1, readColor);
                    const middle = translucent ? sample(Math.floor(innerHeight * 0.42), readColor) : [];
                    if (translucent) {
                        sample(Math.floor(innerHeight * 0.75), false);
                        sample(innerHeight - 2, false);
                        for (const node of marked) {
                            if (!surfaces.has(node)) node.removeAttribute(marker);
                        }
                        for (const node of surfaces) {
                            if (!marked.has(node)) node.setAttribute(marker, '');
                            for (let parent = node; parent && !roots.has(parent); parent = parent.parentElement) roots.add(parent);
                        }
                        marked = surfaces;
                        if (!sheet && root) {
                            sheet = document.createElement('style');
                            sheet.id = 'floatchat-canvas';
                            sheet.textContent = 'html, body, [data-floatchat-canvas] { background-color: transparent !important; }';
                            (document.head || root).append(sheet);
                        }
                        if (sheet?.sheet) sheet.sheet.disabled = false;
                        if (roots.size !== watched.size || [...roots].some(node => !watched.has(node))) {
                            observer.disconnect();
                            for (const node of roots) {
                                if (node) observer.observe(node, { childList: true, attributes: true, attributeFilter: ['class', 'style'] });
                            }
                            watched = roots;
                        }
                    } else {
                        for (const node of marked) node.removeAttribute(marker);
                        sheet?.remove();
                    }
                    const consensus = entries => entries.find(color =>
                        color && entries.filter(other => String(other) === String(color)).length > 1);
                    return consensus(middle) ?? consensus(top) ?? null;
                };

                const color = update(true);
                if (translucent) {
                    window.addEventListener('resize', schedule);
                    globalThis.floatChatCanvas = {
                        get surfaces() { return marked; },
                        stop() {
                            observer.disconnect();
                            window.removeEventListener('resize', schedule);
                            if (pending !== null) clearTimeout(pending);
                        }
                    };
                } else {
                    delete globalThis.floatChatCanvas;
                }
                return color;
            })()
            """#
        view.evaluateJavaScript(script, in: nil, in: .defaultClient) { [weak self, weak view] result in
            guard let self, let view, self.webView === view, view.url == url,
                  case .success(let value) = result, let rgb = value as? [Double], rgb.count == 3 else { return }
            self.setSurfaceColor(NSColor(srgbRed: rgb[0] / 255, green: rgb[1] / 255, blue: rgb[2] / 255, alpha: 1))
        }
    }

    private var chatURL: URL { providers[selectedIndex].conversationURL ?? providers[selectedIndex].url }

    private func selectProvider(_ index: Int) {
        guard providers.indices.contains(index), !disabledURLs.contains(providers[index].key), index != selectedIndex else { return }
        rememberPinnedPage()
        prunePages()
        parkActivePage()
        failureURL = nil
        selectedIndex = index
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        if panel?.isVisible == true { attachSelectedPage() }
        crashReloads = []
        refreshPicker()
        prunePages()
    }

    private func parkActivePage() {
        guard let view = webView else { return }
        let provider = providers[selectedIndex]
        stopTrackingPageLoad()
        if panelTranslucency > 0 {
            view.evaluateJavaScript("globalThis.floatChatCanvas?.stop()", in: nil, in: .defaultClient, completionHandler: nil)
        }
        panel?.detachKeyboardFromPage(view)
        contentStack?.removeArrangedSubview(view)
        view.removeFromSuperview()
        view.setAllMediaPlaybackSuspended(true)
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setCameraCaptureState(.none, completionHandler: nil)
        parkedPages[provider.key] = ParkedPage(view: view, parkedAt: .now, isPinned: provider.isPinned, failureURL: failureURL)
        webView = nil
        pageColorObservation = nil
        pageURLObservation = nil
        pageTitleObservation = nil
    }

    private func attachSelectedPage() {
        guard webView == nil, let contentStack else { return }
        prunePages()
        let cached = takeParkedPage(for: providers[selectedIndex])
        let view = cached?.view ?? makeWebView()
        webView = view
        failureURL = cached?.failureURL
        view.setAllMediaPlaybackSuspended(false)
        view.pageZoom = zoom(for: providers[selectedIndex])
        contentStack.addArrangedSubview(view)
        if let resizeGrip { contentStack.addSubview(resizeGrip, positioned: .above, relativeTo: nil) }
        observePageColor(view)
        refreshPicker()
        updateWebsiteIdentity()
        updateStatus()
        if cached == nil { view.load(pageRequest(chatURL)) }
        trackPageLoad(view)
        focusSelectedPage()
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
    private func refreshPicker() {
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
        pinButton?.image = NSImage(systemSymbolName: providers[selectedIndex].isPinned ? "pin.fill" : "pin", accessibilityDescription: "Pin Conversation")
        pinButton?.isEnabled = providers[selectedIndex].isPinned || webView?.url.map { canRemember($0, provider: providers[selectedIndex]) } == true
        pinButton?.toolTip = AppText.t(providers[selectedIndex].isPinned ? "Unpin and close this chat" : "Pin this conversation")
        pinButton?.setAccessibilityLabel(pinButton?.toolTip)
        if let document = providerTabs?.superview as? NSStackView {
            document.layoutSubtreeIfNeeded()
            document.setFrameSize(NSSize(width: document.fittingSize.width, height: 28))
        }
        let selectedKey = providers[selectedIndex].key
        DispatchQueue.main.async { [weak self] in
            guard let self, self.providers[self.selectedIndex].key == selectedKey else { return }
            self.providerTabs?.superview?.layoutSubtreeIfNeeded()
            for case let button as ChatTabButton in (self.providerTabs?.arrangedSubviews ?? []) + (self.pinnedTabs?.arrangedSubviews ?? []) where button.tabKey == selectedKey {
                button.scrollToVisible(button.bounds)
            }
        }
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
    private func saveSessions() {
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
        let fields = NSStackView(views: provider.isPinned ? [name] : [name, address])
        fields.orientation = .vertical
        fields.spacing = 8
        fields.frame = NSRect(x: 0, y: 0, width: 310, height: provider.isPinned ? 26 : 58)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if provider.isPinned {
                guard let i = self.savedSessions.firstIndex(where: { $0.key == provider.key }) else { return }
                self.savedSessions[i].manualTopic = title.isEmpty ? nil : String(title.prefix(100))
                self.saveSessions()
            } else {
                guard !title.isEmpty, let url = ProviderAddress.parse(address.stringValue),
                      let i = self.customProviders.firstIndex(where: { $0.key == provider.key }),
                      !(Self.builtIns + self.customProviders).contains(where: { $0.key != provider.key && $0.url == url }) else {
                    let warning = NSAlert()
                    warning.messageText = AppText.t("Enter a name and a unique HTTPS website address.")
                    warning.beginSheetModal(for: settingsWindow)
                    return
                }
                let selected = self.providers[self.selectedIndex].key
                if url != provider.url {
                    if selected == provider.key { self.parkActivePage() }
                    if let old = self.parkedPages.removeValue(forKey: provider.key) { self.releasePage(old.view) }
                    self.providerOrder = self.providers.map { $0.key == provider.key ? url.absoluteString : $0.key }
                    self.deletedURLs.remove(url.absoluteString)
                    if self.disabledURLs.remove(provider.key) != nil { self.disabledURLs.insert(url.absoluteString) }
                    self.preferences.set(self.providerOrder, forKey: "providerOrder")
                    self.preferences.set(Array(self.deletedURLs), forKey: "deletedProviders")
                    self.preferences.set(Array(self.disabledURLs), forKey: "disabledProviders")
                }
                self.customProviders[i] = Provider(name: title, url: url)
                let key = selected == provider.key ? url.absoluteString : selected
                self.selectedIndex = self.providers.firstIndex(where: { $0.key == key }) ?? 0
                self.preferences.set(key, forKey: "selectedProvider")
                self.saveCustomProviders()
                if url != provider.url {
                    ProviderIcon.copyCustomIcon(from: provider.url, to: url)
                    self.refreshFavicon(url)
                    if self.panel?.isVisible == true { self.attachSelectedPage() }
                }
            }
            self.prunePages()
            self.refreshPicker()
            self.updateSettings()
        }
    }

    private func zoom(for provider: Provider) -> Double {
        let values = preferences.dictionary(forKey: "websiteZoom") ?? [:]
        let value = (values[provider.key] ?? values[provider.url.absoluteString]) as? Double ?? 1
        return (0.6...2).contains(value) ? value : 1
    }

    private func setZoom(_ value: Double, for key: String) {
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

    private func preview(for provider: Provider) -> String {
        let page = provider.key == providers[selectedIndex].key ? webView : parkedPages[provider.key]?.view
        if let label = provider.manualTopic { return label }
        let title = page?.title ?? provider.topic ?? provider.name
        let topic = topicOnly(title, provider: provider)
        return topic == "New chat" ? AppText.t(topic) : topic
    }
    private func displayName(_ provider: Provider) -> String {
        if let label = provider.manualTopic { return label }
        if provider.isPinned, provider.topic == "New chat" { return AppText.t("New chat") }
        return provider.topic ?? provider.name
    }
    private func topicOnly(_ title: String?, provider: Provider) -> String {
        guard var title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return "New chat" }
        if title == provider.name || title.hasPrefix(provider.name + ":") { return "New chat" }
        for suffix in [" - " + provider.name, " | " + provider.name, " | " + (provider.url.host ?? "")] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return title
    }
    private func updateTabPreviews() {
        for case let button as ChatTabButton in (providerTabs?.arrangedSubviews ?? []) + (pinnedTabs?.arrangedSubviews ?? []) {
            if let provider = providers.first(where: { $0.key == button.tabKey }) { button.toolTip = preview(for: provider) }
        }
    }
    private func canRemember(_ url: URL, provider: Provider) -> Bool {
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
    private func rememberPinnedPage() {
        let provider = providers[selectedIndex]
        guard provider.isPinned, let index = savedSessions.firstIndex(where: { $0.key == provider.key }),
              let url = webView?.url, canRemember(url, provider: provider) else { return }
        let title = String(topicOnly(webView?.title, provider: provider).prefix(100))
        if savedSessions[index].conversationURL == url, savedSessions[index].topic != title {
            savedSessions[index].topic = title
            saveSessions()
        }
    }
    private func unpinProvider(_ index: Int) {
        guard providers.indices.contains(index), providers[index].isPinned else { return }
        if index == selectedIndex { togglePin(nil) }
        else { deleteProvider(index) }
    }
    @objc private func togglePin(_ sender: Any?) {
        togglePin(url: webView?.url, title: webView?.title)
    }
    private func togglePin(url: URL?, title: String?) {
        var provider = providers[selectedIndex]
        let oldKey = provider.key
        let oldZoom = zoom(for: provider)
        if provider.isPinned {
            var destination = enabledTabIndices.first { !providers[$0].isPinned && providers[$0].url == provider.url }
                ?? enabledTabIndices.first { !providers[$0].isPinned }
            if destination == nil {
                let instantKey = provider.url.absoluteString
                if !(Self.builtIns + customProviders).contains(where: { $0.url == provider.url }) {
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
            provider.topic = String(topicOnly(title, provider: provider).prefix(100))
            savedSessions.append(provider)
            selectedIndex = providers.firstIndex(where: { $0.key == provider.key }) ?? selectedIndex
            setZoom(oldZoom, for: provider.key)
            pinFeedback()
        }
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        saveSessions(); refreshPicker(); updateSettings()
    }

    private func pinFeedback() {
        guard panel?.isVisible == true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func isProviderHost(_ host: String?, provider: Provider) -> Bool {
        ProviderAddress.matchesWebsite(host: host, baseHost: provider.url.host)
    }
    /// OpenAI's sign-in hosts (and their subdomains): where sign-in starts from a chatgpt.com page.
    private static let openAISignInHosts = ["auth.openai.com", "auth0.openai.com"]
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = Log.make("FloatChat")
    private var panel: FloatChatPanel?
    private var webView: WKWebView?
    private var previousApp: NSRunningApplication?
    /// When the panel was last shown / last lost key, and until when a Space switch may not
    /// take its focus (see `spaceDidChange()`).
    private var isHiding = false
    private var shownAt: Date?
    private var lostKeyAt: Date?
    private var keepFocusUntil: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Where each in-flight download is being written, for "reveal in Finder" when it finishes.
    private var downloads: [ObjectIdentifier: (download: WKDownload, destination: URL)] = [:]
    /// Recent automatic reloads after the web content process died, to stop a crash loop.
    private var crashReloads: [Date] = []
    private var connectivity: NWPathMonitor?
    private var offline = false
    private var slowPageTimer: Timer?
    private var slowPage = false
    private var waitingForPage = false

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

    private func trackPageLoad(_ view: WKWebView) {
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

    private func stopTrackingPageLoad() {
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

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
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
    private var failureURL: URL?
    private var recentDownload: URL?
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

    private func updateWebsiteIdentity() {
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

    private var retryURL: URL? {
        if let failureURL { return failureURL }
        return slowPage || (offline && waitingForPage) ? chatURL : nil
    }

    private func updateStatus() {
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

    private func pageFailed(_ view: WKWebView, error: Error) {
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

    private func keepPanelReachable(_ panel: NSPanel) {
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

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        configureScripts(config.userContentController)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    /// Turns off macOS autocorrect / auto-capitalization (and inline predictions) in chatgpt.com's
    /// composer. Their suggestion bubble swallows keys while it's up, ⌥Space included, so the
    /// toggle shortcut stops working. Spell-check underlines stay. Re-applied on DOM changes,
    /// since the page re-renders the composer.
    private static let noAutocorrectScript = """
    (() => {
      const selector = '#prompt-textarea, [contenteditable="true"], textarea';
      const apply = el => {
        el.setAttribute('autocorrect', 'off');
        el.setAttribute('autocapitalize', 'off');
        el.setAttribute('writingsuggestions', 'false');
      };
      const scan = node => {
        if (node.nodeType !== 1) return;
        if (node.matches(selector)) apply(node);
        node.querySelectorAll(selector).forEach(apply);
      };
      new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(scan)))
        .observe(document, { childList: true, subtree: true });
      document.querySelectorAll(selector).forEach(apply);
    })();
    """

    private func focusSelectedPage() {
        guard let panel, let webView, webView.window === panel else { return }
        panel.keyboardPage = webView
        panel.focusKeyboardPage()
        focusComposer()
    }

    private func focusComposer() {
        // Best effort: chatgpt.com's composer is a contenteditable #prompt-textarea.
        webView?.evaluateJavaScript("""
            const active = document.activeElement;
            if (!active?.isContentEditable && !active?.matches('input, textarea, select, iframe')) {
                document.querySelector('#prompt-textarea, [contenteditable="true"][role="textbox"], textarea')?.focus();
            }
            """)
    }

    private static func isHTTPSPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    /// blob: and data: URLs are page-generated files (exports, images); they're saved, never shown.
    private static func isGeneratedFile(_ url: URL?) -> Bool {
        url?.scheme == "blob" || url?.scheme == "data"
    }

    /// ~/Downloads/<name>, or "<name> 2", "<name> 3", … if that already exists (Finder-style).
    private static func uniqueDownloadURL(suggestedFilename: String, reserved: Set<URL>) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = (suggestedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "download" + name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(name)
        var n = 2
        while reserved.contains(candidate) || FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = downloads.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    /// External links from the selected website open in the browser, while recognized
    /// authentication hosts stay in WebKit. Other pages in an SSO flow may redirect in-panel.
    private func opensInBrowser(_ url: URL?, from source: URL?) -> Bool {
        guard let host = url?.host?.lowercased(), isProviderHost(source?.host, provider: providers[selectedIndex]) else { return false }
        let authHosts = Self.openAISignInHosts + ["accounts.google.com", "appleid.apple.com", "login.microsoftonline.com", "login.live.com", "auth.deepseek.com", "auth.claude.ai"]
        let isAuth = authHosts.contains { host == $0 || host.hasSuffix("." + $0) }
        return !isProviderHost(host, provider: providers[selectedIndex]) && !isAuth
    }
}

// MARK: - WebKit delegates

extension FloatChatController: WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// `window.open` / target=_blank: opens in the panel, unless `opensInBrowser` sends it to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, panel?.isVisible == true, let url = navigationAction.request.url else { return nil }
        guard Self.isHTTPSPage(url) || Self.isGeneratedFile(url) else { return nil }
        if Self.isGeneratedFile(url) {
            // window.open(blob:/data:) would otherwise replace the chat in the panel.
            webView.startDownload(using: navigationAction.request) { $0.delegate = self }
        } else if opensInBrowser(url, from: webView.url) {
            NSWorkspace.shared.open(url)
        } else {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let active = webView === self.webView
        let url = navigationAction.request.url
        if let scheme = url?.scheme?.lowercased(), !["https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel); return
        }
        // <a download>, blob:/data: links: save the file instead of navigating (checked first, as
        // download links often point at file hosts that would otherwise open in the browser).
        if navigationAction.shouldPerformDownload || (navigationAction.targetFrame?.isMainFrame == true && Self.isGeneratedFile(url)) {
            decisionHandler(active ? .download : .cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, !Self.isHTTPSPage(url) {
            decisionHandler(.cancel)
            return
        }
        if active, navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .linkActivated,
           opensInBrowser(url, from: webView.url), let url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Responses the web view can't display, or that the server marks as attachments, are saved.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, !Self.isHTTPSPage(navigationResponse.response.url) {
            pageFailed(webView, error: URLError(.unsupportedURL))
            decisionHandler(.cancel)
            return
        }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let isAttachment = disposition?.hasPrefix("attachment") == true
        decisionHandler(!navigationResponse.canShowMIMEType || isAttachment ? (webView === self.webView ? .download : .cancel) : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView { trackPageLoad(webView); updateStatus() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else {
            if let key = parkedPages.first(where: { $0.value.view === webView })?.key {
                parkedPages[key]?.failureURL = nil
            }
            return
        }
        failureURL = nil
        stopTrackingPageLoad()
        updateStatus()
        updateWebsiteIdentity()
        matchPageEdge(webView)
        if panel?.isKeyWindow == true { focusSelectedPage() }
        rememberPinnedPage()
        refreshPicker()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === self.webView {
            waitingForPage = false
            updateStatus()
            updateWebsiteIdentity()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, error: error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageFailed(webView, error: error)
    }

    /// macOS may kill the web content process (often while hidden, under memory pressure), which
    /// leaves the view blank. Discard parked pages and retry active pages up to three times.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            if let key = parkedPages.first(where: { $0.value.view === webView })?.key {
                releasePage(webView); parkedPages.removeValue(forKey: key); prunePages()
            }
            return
        }
        let now = Date()
        crashReloads.removeAll { now.timeIntervalSince($0) > 60 }
        guard crashReloads.count < 3 else {
            log.error("Web content process keeps terminating")
            stopTrackingPageLoad()
            failureURL = chatURL
            updateStatus()
            return
        }
        crashReloads.append(now)
        log.info("Web content process terminated; reloading")
        reload(webView)
    }

    private func reload(_ webView: WKWebView) {
        if webView.url != nil { webView.reload() } else { webView.load(pageRequest(chatURL)) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard webView === self.webView, let panel, panel.isVisible else { return completionHandler(nil) }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = parameters.allowsMultipleSelection
        open.canChooseDirectories = parameters.allowsDirectories
        open.beginSheetModal(for: panel) { [weak self, weak webView] response in
            guard let self, let webView, webView === self.webView, panel.isVisible else {
                return completionHandler(nil)
            }
            completionHandler(response == .OK ? open.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // Only the visible provider and its own origin can prompt for camera or microphone.
        // macOS's own TCC prompt also appears once per app (NSCamera/NSMicrophoneUsageDescription).
        let provider = providers[selectedIndex]
        let allowed = webView === self.webView && panel?.isVisible == true && origin.protocol == "https"
            && frame.isMainFrame && isProviderHost(origin.host, provider: provider)
            && webView.url?.host?.lowercased() == origin.host.lowercased()
            && (webView.url?.port ?? 443) == (origin.port == 0 ? 443 : origin.port)
        decisionHandler(allowed ? .prompt : .deny)
    }

    // MARK: Downloads (WKDownloadDelegate)

    /// Saves straight to ~/Downloads under a unique name (like Safari): no modal sheet on the
    /// floating panel, which may be hidden by the time a slow download asks for a destination.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let destination = Self.uniqueDownloadURL(suggestedFilename: suggestedFilename, reserved: Set(downloads.values.map(\.destination)))
        downloads[ObjectIdentifier(download)] = (download, destination)
        log.info("Download started")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloads.removeValue(forKey: ObjectIdentifier(download))?.destination else { return }
        guard panel?.isVisible == true else { return }
        recentDownload = destination
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard self?.recentDownload == destination else { return }
            self?.recentDownload = nil
            self?.updateStatus()
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloads.removeValue(forKey: ObjectIdentifier(download))
        log.error("Download failed with code \((error as NSError).code)")
    }
}

// MARK: - Panel

final class FloatChatPanel: NSPanel {
    static let autosaveName = "MiniChat.Panel" // pre-rename name; keeps the saved frame
    static var surfaceCornerRadius: CGFloat {
        if #available(macOS 26, *) { return 20 }
        return 12
    }
    /// Default content size (also the "reset size" target): a 3:4 portrait panel. Anything under
    /// 640 wide gets chatgpt.com's compact (mobile) layout; 420 sits between Classic's 440-wide
    /// companion chat and `minSize` (400), so the thread reads as a narrow column without the
    /// squat look of the new app's 470-wide window cut down to 560 tall.
    static let defaultSize = NSSize(width: 420, height: 560)
    var onSelectProvider: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    var onResignKey: (() -> Void)?
    /// ⌘[ / ⌘] while the panel is key: the browsers' Back and Forward.
    var onGoBack: (() -> Void)?
    var onGoForward: (() -> Void)?
    weak var keyboardPage: WKWebView?
    var zoomKeysEnabled = true
    var onPageZoom: ((Double?) -> Void)?
    var remembersFrame = true {
        didSet { setFrameAutosaveName(remembersFrame ? Self.autosaveName : "") }
    }

    private func keyboardBelongs(to page: WKWebView) -> Bool {
        (firstResponder as? NSView)?.isDescendant(of: page) == true
    }

    func detachKeyboardFromPage(_ page: WKWebView) {
        if keyboardBelongs(to: page) { makeFirstResponder(nil) }
        if keyboardPage === page { keyboardPage = nil }
    }

    func focusKeyboardPage() {
        guard let page = keyboardPage, page.window === self, !keyboardBelongs(to: page) else { return }
        makeFirstResponder(page)
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Local key combo that calls `resetSize()` while the panel is key.
    var resetSizeShortcut: Shortcut?
    /// Local key combo that calls `toggleMaximize()` while the panel is key.
    var maximizeShortcut: Shortcut? {
        didSet { updateZoomTooltip() }
    }

    /// System traffic-light buttons shown in the title bar's top-left cluster (the rest stay
    /// hidden). Red close goes through `close()` below, so it hides rather than destroys; green
    /// zoom is rerouted to `toggleMaximize()` (see `configureZoomButton()`).
    static let trafficLights: [NSWindow.ButtonType] = [.closeButton, .zoomButton]

    /// Where the green button sits when minimize is hidden: minimize's slot, so there's no gap.
    private var zoomButtonOrigin: NSPoint?

    /// The user's frame from before maximizing; non-nil while maximized. Hiding and showing
    /// keep the panel maximized; a relaunch doesn't, as the maximized frame is never autosaved.
    private var restoreFrame: NSRect?
    var isMaximized: Bool { restoreFrame != nil }
    /// Set while the panel changes its own frame, so only user moves/resizes end the maximize.
    private var isSettingFrame = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "FloatChat"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // .fullScreenAuxiliary lets the panel show over another app's full-screen Space. Don't add
        // .fullScreenNone: the full-screen behaviors are mutually exclusive and it cancels
        // .fullScreenAuxiliary (issue #7). As an auxiliary window it can't go full screen itself,
        // so the green button still only maximizes.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenDisallowsTiling]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = !Self.trafficLights.contains(button)
        }
        configureZoomButton()
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 400, height: 400)
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange),
                                                   name: name, object: self)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Points the green button at `toggleMaximize()` and, if minimize is hidden, slides it into
    /// minimize's slot next to close. AppKit re-lays out the title bar buttons (resize, key
    /// changes), so the button's frame changes are watched and the slot re-applied.
    private func configureZoomButton() {
        guard let zoom = standardWindowButton(.zoomButton), !zoom.isHidden else { return }
        zoom.target = self
        zoom.action = #selector(maximizeButtonClicked(_:))
        updateZoomTooltip()

        guard !Self.trafficLights.contains(.miniaturizeButton),
              let mini = standardWindowButton(.miniaturizeButton) else { return }
        zoomButtonOrigin = mini.frame.origin
        pinZoomButton()
        zoom.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(pinZoomButton),
                                               name: NSView.frameDidChangeNotification, object: zoom)
    }

    /// Deferred a turn: moving the button synchronously inside AppKit's title bar layout pass
    /// gets overwritten by the rest of that pass.
    @objc private func pinZoomButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let zoomButtonOrigin = self.zoomButtonOrigin,
                  let zoom = self.standardWindowButton(.zoomButton),
                  zoom.frame.origin != zoomButtonOrigin else { return }
            zoom.setFrameOrigin(zoomButtonOrigin)
        }
    }

    private func updateZoomTooltip() {
        var tip = isMaximized ? "Restore Size" : "Maximize"
        if let maximizeShortcut { tip += " (\(maximizeShortcut.displayString))" }
        standardWindowButton(.zoomButton)?.toolTip = tip
    }

    @objc private func maximizeButtonClicked(_ sender: Any?) { toggleMaximize() }

    /// Title bar double-click / Window ▸ Zoom toggle maximize too, instead of AppKit's own zoom.
    override func zoom(_ sender: Any?) {
        if let event = NSApp.currentEvent, Self.isDoubleClick(event) {
            titleBarDoubleClicked(event)
        } else {
            toggleMaximize()
        }
    }

    /// Timestamp of the last double-click acted on, so one double-click toggles only once when
    /// both AppKit (via `zoom(_:)`) and the header view report it.
    private var lastDoubleClickTimestamp: TimeInterval?

    /// A double-click on the title bar or header strip. Since macOS 27 AppKit no longer turns a
    /// double-click on a `mouseDownCanMoveWindow` view into `zoom(_:)`, so the header calls this
    /// itself. Follows the "Double-click a window's title bar to" setting; the panel can't
    /// minimize, so Minimize does nothing, like Do Nothing.
    func titleBarDoubleClicked(_ event: NSEvent) {
        guard event.timestamp != lastDoubleClickTimestamp else { return }
        lastDoubleClickTimestamp = event.timestamp
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "None", "Minimize": return
        default: toggleMaximize()
        }
    }

    private static func isDoubleClick(_ event: NSEvent) -> Bool {
        [.leftMouseDown, .leftMouseUp].contains(event.type) && event.clickCount == 2
    }

    /// Esc (when the page doesn't handle it) hides the panel.
    override func cancelOperation(_ sender: Any?) {
        guard (firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
        onCancel?()
    }

    /// Fills the screen's visible frame (menu bar and Dock stay visible), or goes back to the
    /// user's frame from before. The panel stays resizable while maximized.
    func toggleMaximize() {
        if let restoreFrame {
            setOwnFrame(restoreFrame)
            endMaximize()
        } else {
            guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
            restoreFrame = frame
            setFrameAutosaveName("") // keep the user's frame as the one restored on relaunch
            setOwnFrame(visible)
            updateZoomTooltip()
        }
    }

    /// Resizes to `defaultSize`, keeping the top-left corner put (the pre-maximize one if
    /// maximized) but staying on the visible part of the screen. The frame autosave then
    /// persists the new size.
    func resetSize() {
        let anchor = restoreFrame ?? frame
        let size = frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize)).size
        var frame = NSRect(x: anchor.minX, y: anchor.maxY - size.height,
                           width: size.width, height: size.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        setOwnFrame(frame)
        if isMaximized { endMaximize() }
    }

    /// Animated frame change that doesn't count as the user moving or resizing the panel.
    private func setOwnFrame(_ frame: NSRect) {
        isSettingFrame = true
        defer { isSettingFrame = false }
        setFrame(frame, display: true, animate: true)
    }

    /// Leaves the maximized state as is (frame-wise) and resumes autosaving the current frame.
    private func endMaximize() {
        restoreFrame = nil
        setFrameAutosaveName(remembersFrame ? Self.autosaveName : "")
        saveFrame(usingName: Self.autosaveName)
        updateZoomTooltip()
    }

    /// The user moved or resized the maximized panel: that frame becomes their own.
    @objc private func frameDidChange() {
        if isMaximized, !isSettingFrame { endMaximize() }
    }

    /// Runs the Reset Window Size or Maximize action if `event` is its shortcut. Key repeats
    /// are swallowed, so holding the shortcut doesn't toggle maximize over and over.
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard let pressed = Shortcut(event: event) else { return false }
        guard pressed == resetSizeShortcut || pressed == maximizeShortcut else { return false }
        if event.isARepeat { return true }
        if pressed == resetSizeShortcut {
            resetSize()
        } else if pressed == maximizeShortcut {
            toggleMaximize()
        } else {
            return false
        }
        return true
    }

    /// Catches the panel's local shortcuts before the web view sees them. Done here rather
    /// than in `performKeyEquivalent` so combos without ⌘ (e.g. ⌥R, F5) work too.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // A retained WebKit responder can outlive its window attachment.
            if let view = firstResponder as? NSView, view.window !== self {
                makeFirstResponder(nil)
                focusKeyboardPage()
            }
            if (firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
               handleLocalShortcut(event) { return }
        }
        super.sendEvent(event)
    }

    override func close() { onCancel?() }

    /// ⌘W hides and ⌘[ / ⌘] go back / forward; the local shortcuts are caught here too, ahead
    /// of the web view (which otherwise claims ⌘ combos). The shortcut window refuses these
    /// combos; a local shortcut saved with one before that still wins, as it's checked first.
    /// Matched by character, like menu key equivalents, so they work on any keyboard layout.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if (firstResponder as? NSTextInputClient)?.hasMarkedText() == true {
            return super.performKeyEquivalent(with: event)
        }
        if handleLocalShortcut(event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if zoomKeysEnabled, modifiers == .command || modifiers == [.command, .shift] {
            switch event.charactersIgnoringModifiers {
            case "=", "+":
                onPageZoom?(0.1); return true
            case "-" where modifiers == .command, "−" where modifiers == .command:
                onPageZoom?(-0.1); return true
            case "0" where modifiers == .command:
                onPageZoom?(nil); return true
            default: break
            }
        }
        if modifiers == .command {
            if let text = event.charactersIgnoringModifiers, let number = Int(text), (1...9).contains(number) {
                onSelectProvider?(number - 1); return true
            }
            switch event.charactersIgnoringModifiers {
            case "w": onCancel?(); return true
            case "[": onGoBack?(); return true
            case "]": onGoForward?(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Header strip that drags the window; a double-click on it acts like one on the title bar.
private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let panel = window as? FloatChatPanel {
            panel.titleBarDoubleClicked(event)
            return
        }
        window?.performDrag(with: event)
    }
}

/// Visible resize affordance for a borderless panel; keeps its top-left corner fixed.
private final class ResizeGrip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag to resize"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.4).setStroke()
        let path = NSBezierPath()
        for offset: CGFloat in [4, 8, 12] {
            path.move(to: NSPoint(x: bounds.maxX - offset, y: 3))
            path.line(to: NSPoint(x: bounds.maxX - 3, y: offset))
        }
        path.stroke()
    }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let original = window.frame
        let start = NSEvent.mouseLocation
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let point = NSEvent.mouseLocation
            let width = max(window.minSize.width, original.width + point.x - start.x)
            let height = max(window.minSize.height, original.height - point.y + start.y)
            window.setFrame(NSRect(x: original.minX, y: original.maxY - height, width: width, height: height), display: true)
        }
    }
}

#if DEBUG
extension FloatChatController {
    static func runPanelSelfTest() -> Bool {
        _ = NSApplication.shared
        let suite = "dev.quickchat.omni.panel-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let controller = FloatChatController(preferences: defaults)
        let panel = FloatChatPanel(contentRect: NSRect(origin: .zero, size: FloatChatPanel.defaultSize))
        let stack = NSStackView()
        panel.contentView = stack
        controller.panel = panel
        controller.contentStack = stack
        stack.wantsLayer = true
        defer {
            controller.tearDown()
            defaults.removePersistentDomain(forName: suite)
        }

        print("Checking marked text")
        let composer = NSTextView()
        composer.isRichText = false
        stack.addArrangedSubview(composer)
        var dismissals = 0
        panel.onCancel = { dismissals += 1 }
        guard panel.makeFirstResponder(composer) else { return false }
        composer.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        guard composer.hasMarkedText() else { return false }
        panel.cancelOperation(nil)
        guard dismissals == 0 else { return false }
        composer.unmarkText()
        panel.cancelOperation(nil)
        guard dismissals == 1 else { return false }

        print("Checking copy and paste")
        let draft = "FloatChat 测试"
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        composer.string = draft
        composer.setSelectedRange(NSRange(location: 0, length: draft.utf16.count))
        guard composer.writeSelection(to: pasteboard, types: composer.writablePasteboardTypes),
              pasteboard.string(forType: .string) == draft else {
            print("Copy did not write the selection")
            return false
        }
        composer.string = ""
        composer.setSelectedRange(NSRange(location: 0, length: 0))
        guard composer.readSelection(from: pasteboard), composer.string == draft else {
            print("Paste did not restore the selection")
            return false
        }
        stack.removeArrangedSubview(composer)
        composer.removeFromSuperview()

        print("Checking WebKit setup")
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let original = WKWebView(frame: .zero, configuration: config)
        let alternate = WKWebView(frame: .zero, configuration: config)
        defaults.set(true, forKey: "glassEnabled")
        controller.applySurfaceAppearance()
        guard let legacyAlpha = stack.layer?.backgroundColor?.alpha,
              abs(legacyAlpha - 0.84) < 0.001, stack.alphaValue == 1, original.alphaValue == 1 else { return false }
        controller.setPanelTranslucency(32)
        guard let sliderAlpha = stack.layer?.backgroundColor?.alpha, abs(sliderAlpha - 0.68) < 0.001 else { return false }
        controller.setPanelTranslucency(0)
        guard stack.layer?.backgroundColor?.alpha == 1, stack.alphaValue == 1 else { return false }
        let first = controller.selectedIndex
        let firstKey = controller.providers[first].key
        let secondKey = controller.providers[1].key
        controller.parkedPages[firstKey] = ParkedPage(view: original, parkedAt: .now, isPinned: false)
        controller.parkedPages[secondKey] = ParkedPage(view: alternate, parkedAt: .now, isPinned: false)
        panel.makeKeyAndOrderFront(nil)
        controller.attachSelectedPage()
        guard controller.webView === original, panel.isVisible else { return false }

        print("Checking fixture load")
        let fixture = "<form onsubmit='sent++; return false'><textarea id='draft'></textarea><button>Send</button></form><script>let sent = 0;</script>"
        original.loadHTMLString(fixture, baseURL: URL(string: "https://example.com/"))
        alternate.loadHTMLString(fixture, baseURL: nil)
        func evaluate(_ script: String, in page: WKWebView, world: WKContentWorld = .page) -> String? {
            var result: String?
            var done = false
            page.evaluateJavaScript(script, in: nil, in: world) { outcome in
                if case .success(let value) = outcome { result = value as? String }
                done = true
            }
            let deadline = Date.now.addingTimeInterval(5)
            while !done && Date.now < deadline { RunLoop.current.run(until: Date.now.addingTimeInterval(0.05)) }
            return result
        }
        let deadline = Date.now.addingTimeInterval(10)
        while (original.isLoading || alternate.isLoading) && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        let value = "document.querySelector('#draft').value + ':' + sent"
        func typeTestKey() -> Bool {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, characters: "q", charactersIgnoringModifiers: "q",
                isARepeat: false, keyCode: 12) else { return false }
            panel.sendEvent(event)
            return true
        }
        func waitForValue(_ expected: String, in page: WKWebView, script: String? = nil) -> Bool {
            let deadline = Date.now.addingTimeInterval(3)
            repeat {
                if evaluate(script ?? value, in: page) == expected { return true }
                RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
            } while Date.now < deadline
            return false
        }
        controller.focusSelectedPage()
        guard evaluate("document.querySelector('#draft').value = '测试草稿'", in: original) == "测试草稿" else { return false }
        controller.selectProvider(1)
        guard controller.webView === alternate,
              typeTestKey(), waitForValue("q:0", in: alternate),
              evaluate(value, in: original) == "测试草稿:0" else { return false }
        print("Checking keyboard delivery after switching back")
        controller.selectProvider(first)
        guard controller.webView === original,
              typeTestKey(), waitForValue("测试草稿q:0", in: original),
              evaluate(value, in: alternate) == "q:0" else { return false }

        print("Checking translucency after a client-side conversation layout change")
        if original.responds(to: NSSelectorFromString("_setDrawsBackground:")) {
            controller.setPanelTranslucency(32)
            let layout = """
                <main id="canvas" style="position:fixed;inset:0;background-color:rgb(20,30,40)">
                  <h1>New chat</h1><section><p id="stream"></p></section>
                </main>
                <footer id="foot" style="position:fixed;inset:auto 0 0;height:105px;background-color:rgb(45,50,55)">
                  <textarea id="composer" style="display:block;margin:6px auto;width:90%;background-color:rgb(60,65,70)">Sample</textarea>
                </footer>
                """
            let encodedLayout = String(decoding: try! JSONEncoder().encode(layout), as: UTF8.self)
            let background = """
                ['#canvas', '#foot', '#composer'].map(selector => getComputedStyle(document.querySelector(selector)).backgroundColor)
                    .concat(getComputedStyle(document.querySelector('#composer')).opacity).join(':')
                """
            let translucent = "rgba(0, 0, 0, 0):rgba(0, 0, 0, 0):rgb(60, 65, 70):1"
            guard evaluate("document.body.insertAdjacentHTML('beforeend', \(encodedLayout)); 'done'", in: original) == "done",
                  waitForValue(translucent, in: original, script: background) else { return false }

            let replacement = """
                document.querySelector('#canvas').remove();
                document.querySelector('#foot').remove();
                document.body.insertAdjacentHTML('beforeend', \(encodedLayout));
                'done'
                """
            guard evaluate(replacement, in: original) == "done",
                  waitForValue(translucent, in: original, script: background) else { return false }

            print("Checking that streaming text does not resample the page surfaces")
            let instrument = """
                globalThis.fixtureSurfaceReads = 0;
                const actualHitTest = document.elementFromPoint.bind(document);
                document.elementFromPoint = (...args) => {
                    globalThis.fixtureSurfaceReads++;
                    return actualHitTest(...args);
                };
                'ready'
                """
            guard evaluate(instrument, in: original, world: .defaultClient) == "ready",
                  evaluate("for (let i = 0; i < 100; i++) document.querySelector('#stream').append('x'); 'done'", in: original) == "done"
                  else { return false }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.2))
            guard evaluate("String(globalThis.fixtureSurfaceReads)", in: original, world: .defaultClient) == "0" else { return false }

            controller.setPanelTranslucency(0)
            guard waitForValue("rgb(20, 30, 40):rgb(45, 50, 55):rgb(60, 65, 70):1", in: original, script: background)
                  else { return false }
        }

        print("Checking independent Settings and chat windows")
        defaults.set(true, forKey: "hideOnClickAway")
        controller.showSettings()
        guard let settings = controller.settingsWindow, settings.isVisible, panel.isVisible,
              controller.webView === original else { return false }
        controller.show()
        guard settings.isVisible, panel.isVisible else { return false }
        settings.close()
        guard panel.isVisible else { return false }

        print("Checking hide and retain")
        controller.hide(restoreFocus: false)
        guard controller.webView == nil, !panel.isVisible,
              controller.parkedPages[firstKey]?.view === original else { return false }
        controller.selectProvider(1)
        guard controller.webView == nil else { return false }
        print("Checking parked failure")
        let failed = controller.providers[1].url.appendingPathComponent("retry")
        controller.pageFailed(alternate, error: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSURLErrorFailingURLErrorKey: failed]))
        panel.orderFrontRegardless()
        controller.attachSelectedPage()
        guard controller.webView === alternate, controller.failureURL == failed else { return false }
        controller.offline = true
        guard controller.retryURL == failed else { return false }
        controller.offline = false
        controller.failureURL = nil
        guard controller.retryURL == nil else { return false }
        print("Checking immediate release")
        controller.setRetention(0, forPinned: false)
        controller.hide(restoreFocus: false)
        guard controller.webView == nil, controller.parkedPages.isEmpty,
              controller.evictionTimer == nil else { return false }

        print("Checking that a pin restores its saved conversation")
        guard let fixtureURL = original.url else { return false }
        var pin = Provider(name: "Fixture", url: fixtureURL)
        pin.sessionID = "pinned-test"
        pin.pinned = true
        pin.conversationURL = fixtureURL
        controller.parkedPages[pin.key] = ParkedPage(view: original, parkedAt: .now, isPinned: true)
        guard controller.takeParkedPage(for: pin)?.view === original else { return false }
        pin.conversationURL = fixtureURL.appendingPathComponent("saved-conversation")
        controller.parkedPages[pin.key] = ParkedPage(view: original, parkedAt: .now, isPinned: true)
        guard controller.takeParkedPage(for: pin) == nil else { return false }

        print("Checking frame recovery")
        panel.setFrameOrigin(NSPoint(x: 60_000, y: 60_000))
        controller.keepPanelReachable(panel)
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) else { return false }
        print("Panel checks passed: marked text, copy and paste, WebKit draft retention, switching, hide and expiry, parked failure, off-screen recovery")
        return true
    }

    static func runCacheSelfTest() -> Bool {
        _ = NSApplication.shared
        guard ProviderAddress.matchesWebsite(host: "perplexity.ai", baseHost: "www.perplexity.ai"),
              !ProviderAddress.matchesWebsite(host: "chatgpt.com.evil.example", baseHost: "chatgpt.com"),
              !ProviderAddress.matchesWebsite(host: "notchatgpt.com", baseHost: "chatgpt.com") else { return false }
        let suite = "dev.quickchat.omni.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = FloatChatController(preferences: defaults)
        let selected = controller.chatURL
        defaults.set("zh-Hans", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "zh-CN,zh;q=0.9" else { return false }
        defaults.set("en", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9" else { return false }
        controller.reorderProviders(IndexSet(integer: 0), to: 3)
        guard controller.chatURL == selected, controller.providers[2].url == selected else { return false }
        let restored = FloatChatController(preferences: defaults)
        guard restored.providers[2].url == selected else { return false }
        guard controller.addWebsite("Example", address: "EXAMPLE.com", fetchIcon: false),
              !controller.addWebsite("Duplicate", address: "https://example.com:443/"),
              !controller.addWebsite("Unsafe", address: "http://example.net/"),
              !controller.addWebsite("Credentials", address: "https://user:secret@example.net/") else { return false }
        guard ProviderAddress.parse(" https://EXAMPLE.com:443 ")?.absoluteString == "https://example.com/" else { return false }
        let custom = controller.providers.firstIndex(where: { $0.url.host == "example.com" })!
        controller.deleteProvider(custom)
        guard !controller.providers.contains(where: { $0.url.host == "example.com" }), controller.chatURL == selected else { return false }
        let before = controller.providers.count
        controller.deleteProvider(controller.selectedIndex)
        guard controller.providers.count == before - 1, controller.chatURL != selected else { return false }
        guard controller.addWebsite("ChatGPT", address: selected.absoluteString, fetchIcon: false) else { return false }
        let first = controller.providers.firstIndex(where: { $0.url == selected })!
        controller.toggleProvider(first)
        guard controller.chatURL != selected else { return false }
        controller.toggleProvider(first)
        let sample = controller.providers[controller.selectedIndex]
        guard !controller.canRemember(sample.url.appendingPathComponent("sign_in"), provider: sample),
              !controller.canRemember(URL(string: sample.url.absoluteString + "?access_token=test")!, provider: sample) else { return false }
        let instantKey = controller.providers[controller.selectedIndex].key
        let sessionURL = controller.providers[controller.selectedIndex].url.appendingPathComponent("c/test-conversation")
        controller.togglePin(url: sessionURL, title: "A pinned test conversation")
        guard controller.savedSessions.count == 1 else { return false }
        let pinnedKey = controller.providers[controller.selectedIndex].key
        guard pinnedKey != instantKey else { return false }
        let pinProvider = controller.providers[controller.selectedIndex]
        controller.setZoom(1.5, for: pinnedKey)
        controller.setZoom(1.1, for: instantKey)
        guard controller.zoom(for: pinProvider) == 1.5,
              controller.zoom(for: sample) == 1.1,
              !controller.canRemember(URL(string: sample.url.absoluteString + "#access_token=test")!, provider: sample),
              controller.providers.contains(where: { $0.url == Self.doubaoURL }) else { return false }
        let persisted = FloatChatController(preferences: defaults)
        guard persisted.providers.contains(where: { $0.key == pinnedKey && $0.conversationURL == sessionURL }) else { return false }
        var secondPin = controller.savedSessions[0]
        secondPin.sessionID = UUID().uuidString
        secondPin.topic = "Second pinned conversation"
        controller.savedSessions.append(secondPin)
        controller.saveSessions()
        defaults.set(true, forKey: "pinnedFirst")
        let secondIndex = controller.providers.firstIndex(where: { $0.key == secondPin.key })!
        let firstIndex = controller.providers.firstIndex(where: { $0.key == pinnedKey })!
        controller.reorderProviders(IndexSet(integer: secondIndex), to: firstIndex)
        guard controller.providers[controller.enabledTabIndices[0]].key == secondPin.key,
              controller.providers[controller.selectedIndex].key == pinnedKey else { return false }
        let restoredGroups = FloatChatController(preferences: defaults)
        guard restoredGroups.pinnedFirst, restoredGroups.providers[restoredGroups.enabledTabIndices[0]].key == secondPin.key else { return false }
        controller.deleteProvider(controller.providers.firstIndex(where: { $0.key == secondPin.key })!)
        defaults.set(false, forKey: "pinnedFirst")
        guard !controller.providers[controller.enabledTabIndices[0]].isPinned else { return false }
        controller.parkedPages[instantKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast, isPinned: false)
        controller.parkedPages[pinnedKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast, isPinned: true)
        controller.prunePages()
        guard controller.chatURL == sessionURL else { return false }
        let hiddenPin = controller.providers.firstIndex(where: { $0.key == pinnedKey })!
        controller.toggleProvider(hiddenPin)
        let beforeUnpin = controller.providers[controller.selectedIndex].key
        controller.unpinProvider(hiddenPin)
        guard controller.savedSessions.isEmpty, controller.providers[controller.selectedIndex].key == beforeUnpin else { return false }
        let now = Date()
        defaults.set(5, forKey: "retentionMinutes")
        guard controller.retentionMinutes(forPinned: true) == 5 else { return false }
        controller.setRetention(1, forPinned: false)
        guard controller.retentionMinutes(forPinned: false) == 1,
              controller.retentionMinutes(forPinned: true) == 5 else { return false }
        for index in 0..<6 {
            controller.parkedPages[String(index)] = ParkedPage(view: WKWebView(), parkedAt: now, isPinned: index == 5)
        }
        controller.prunePages(at: now.addingTimeInterval(59))
        guard controller.parkedPages.count == 6 else { return false }
        controller.prunePages(at: now.addingTimeInterval(60))
        guard Set(controller.parkedPages.keys) == Set(["5"]) else { return false }
        controller.prunePages(at: now.addingTimeInterval(300))
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.setRetention(0, forPinned: true)
        controller.parkedPages["immediate"] = ParkedPage(view: WKWebView(), parkedAt: now, isPinned: true)
        controller.prunePages(at: now)
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.tearDown()
        print("Checks passed: provider ordering and persistence, URL validation, duplicate rejection, active-provider fallback, deletion and re-adding, independent sessions, pinned URL persistence, group ordering, language headers, unpinning, independent timed retention without a count limit, and immediate release")
        return true
    }
}
#endif

#if DEBUG
extension FloatChatController {
    @MainActor
    private final class LanguageScriptProbe: NSObject, WKNavigationDelegate {
        let controller: FloatChatController
        let defaults: UserDefaults
        let view: WKWebView
        var step = 0
        var finished = false
        var passed = true
        init(controller: FloatChatController, defaults: UserDefaults) {
            self.controller = controller
            self.defaults = defaults
            let config = WKWebViewConfiguration()
            config.websiteDataStore = .nonPersistent()
            controller.configureScripts(config.userContentController)
            view = WKWebView(frame: .zero, configuration: config)
            super.init()
            view.navigationDelegate = self
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("navigator.language") { [weak self] value, error in
                guard let self else { return }
                let expected = self.step == 0 ? "en-US" : "zh-CN"
                guard error == nil, value as? String == expected else {
                    self.passed = false; self.finished = true; return
                }
                if self.step == 0 {
                    self.step = 1
                    self.defaults.set("zh-Hans", forKey: "appLanguage")
                    self.controller.configureScripts(webView.configuration.userContentController)
                    webView.loadHTMLString("<p>Locale check two</p>", baseURL: nil)
                } else { self.finished = true }
            }
        }
    }
    static func runLanguageSelfTest() -> Bool {
        _ = NSApplication.shared
        let suite = "dev.quickchat.omni.locale-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "appLanguage")
        let controller = FloatChatController(preferences: defaults)
        let probe = LanguageScriptProbe(controller: controller, defaults: defaults)
        probe.view.loadHTMLString("<p>Locale check one</p>", baseURL: nil)
        let deadline = Date.now.addingTimeInterval(15)
        while !probe.finished && Date.now < deadline {
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.05))
        }
        probe.view.stopLoading()
        print("WebKit language checks: English and Chinese = \(probe.finished && probe.passed)")
        return probe.finished && probe.passed
    }
}
#endif

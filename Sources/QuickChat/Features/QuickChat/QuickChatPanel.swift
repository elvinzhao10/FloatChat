import AppKit
import WebKit
import SwiftUI

/// Floating Quick Chat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class QuickChatController: NSObject, NSWindowDelegate {
    private struct Provider: Codable {
        var name: String
        var url: URL
        var sessionID: String? = nil
        var conversationURL: URL? = nil
        var topic: String? = nil
        var pinned: Bool? = nil
        var key: String { sessionID ?? url.absoluteString }
        var isPinned: Bool { pinned == true }
    }
    private static let builtIns = [
        Provider(name: "ChatGPT", url: URL(string: "https://chatgpt.com/")!),
        Provider(name: "Claude", url: URL(string: "https://claude.ai/")!),
        Provider(name: "DeepSeek", url: URL(string: "https://chat.deepseek.com/")!),
        Provider(name: "Kimi", url: URL(string: "https://www.kimi.com/")!),
        Provider(name: "Gemini", url: URL(string: "https://gemini.google.com/")!),
        Provider(name: "Perplexity", url: URL(string: "https://www.perplexity.ai/")!),
        Provider(name: "Copilot", url: URL(string: "https://copilot.microsoft.com/")!),
        Provider(name: "Grok", url: URL(string: "https://grok.com/")!),
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
            var seen = Set(Self.builtIns.map { $0.url.absoluteString })
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
        if let saved = preferences.string(forKey: "selectedProvider"), let index = providers.firstIndex(where: { $0.key == saved }) { selectedIndex = index }
    }
    private var providers: [Provider] {
        let available = (Self.builtIns + customProviders + savedSessions).filter { !deletedURLs.contains($0.key) }
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
    private let settingsFields = ChatSettingsFields()

    var configureShortcut: (() -> Void)?
    var shortcutControls: (() -> [ChatSettingsView.ShortcutControl])?

    func quickMenuItems() -> [NSMenuItem] {
        let open = ActionMenuItem(AppText.t("Open Chat")) { [weak self] in self?.show() }
        let switchChat = NSMenuItem(title: AppText.t("Switch Chat"), action: nil, keyEquivalent: "")
        let chats = NSMenu()
        switchChat.submenu = chats
        for pinned in pinnedFirst ? [true, false] : [false, true] {
            let group = enabledTabIndices.filter { providers[$0].isPinned == pinned }
            guard !group.isEmpty else { continue }
            let heading = NSMenuItem(title: AppText.t(pinned ? "Pinned Conversations" : "Instant Chats"), action: nil, keyEquivalent: "")
            heading.isEnabled = false
            chats.addItem(heading)
            for index in group {
                let provider = providers[index]
                let item = ActionMenuItem(displayName(provider)) { [weak self] in self?.selectProvider(index); self?.show() }
                item.image = ProviderIcon.image(for: provider.url, size: 16)
                item.state = index == selectedIndex ? .on : .off
                chats.addItem(item)
            }
        }
        let settings = ActionMenuItem(AppText.t("Settings…")) { [weak self] in self?.showSettings() }
        return [open, switchChat, .separator(), settings]
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
        visitedURLs.removeValue(forKey: key)
        if provider.sessionID == nil { customProviders.removeAll { $0.url == provider.url && $0.sessionID == nil } }
        savedSessions.removeAll { $0.key == key }
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
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        updateSettings()
        hide(restoreFocus: false)
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === settingsWindow {
            DispatchQueue.main.async { [weak self] in self?.show() }
        }
    }
    func updateSettings() {
        guard let settingsWindow else { return }
        let view = ChatSettingsView(
            fields: settingsFields,
            pinnedFirst: pinnedFirst,
            setPinnedFirst: { [weak self] first in
                self?.preferences.set(first, forKey: "pinnedFirst"); self?.refreshPicker(); self?.updateSettings()
            },
            language: language,
            setLanguage: { [weak self] code in self?.setLanguage(code) },
            clearWebsiteData: { [weak self] in self?.confirmClearWebsiteData() },
            clearingWebsiteData: clearingWebsiteData,
            reloadPages: { [weak self] in self?.reloadForLanguage() },
            retention: retentionMinutes,
            setRetention: { [weak self] minutes in self?.retentionMinutes = minutes; self?.prunePages(); self?.updateSettings() },
            shortcutControls: shortcutControls?() ?? [],
            shortcuts: { [weak self] in self?.configureShortcut?() },
            reorder: { [weak self] offsets, destination in self?.reorderProviders(offsets, to: destination) },
            remove: { [weak self] index in self?.removeProvider(index) },
            unpin: { [weak self] index in self?.unpinProvider(index) },
            providers: providers.enumerated().map { index, provider in
                ChatSettingsView.Row(id: provider.key, index: index, name: displayName(provider), url: provider.url, pinned: provider.isPinned, enabled: !disabledURLs.contains(provider.key))
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
        alert.informativeText = AppText.t("This signs out every website in Omni and discards open drafts. Your website list and pinned links are kept.")
        alert.addButton(withTitle: AppText.t("Cancel"))
        alert.addButton(withTitle: AppText.t("Clear Website Data")).hasDestructiveAction = true
        alert.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.clearingWebsiteData = true
            self.tearDown()
            self.visitedURLs.removeAll()
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
        parkedPages.removeAll(); visitedURLs.removeAll(); prunePages()
        if let webView { webView.load(pageRequest(webView.url ?? chatURL)) }
    }
    private func addWebsite(_ name: String, address: String) -> Bool {
        guard let url = ProviderAddress.parse(address), !providers.contains(where: { $0.sessionID == nil && $0.url == url }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        let selected = providers[selectedIndex].key
        deletedURLs.remove(url.absoluteString)
        preferences.set(Array(deletedURLs), forKey: "deletedProviders")
        if !Self.builtIns.contains(where: { $0.url == url }) { customProviders.append(Provider(name: name, url: url)) }
        disabledURLs.remove(url.absoluteString)
        preferences.set(Array(disabledURLs), forKey: "disabledProviders")
        selectedIndex = providers.firstIndex(where: { $0.key == selected }) ?? 0
        saveCustomProviders(); refreshPicker(); updateSettings()
        return true
    }
    @objc private func openInBrowser(_ sender: Any?) {
        let url = webView?.url ?? chatURL
        guard url.scheme == "https" else { return }
        NSWorkspace.shared.open(url)
    }
    @objc private func dismissPanel(_ sender: Any?) { hide(restoreFocus: true) }

    private var selectedIndex = 0
    private var visitedURLs: [String: URL] = [:]
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
    }
    private var parkedPages: [String: ParkedPage] = [:]
    private var evictionTimer: Timer?
    private var retentionMinutes: Int {
        get {
            let value = preferences.object(forKey: "retentionMinutes") as? Int ?? 10
            return [0, 1, 5, 10, 30].contains(value) ? value : 10
        }
        set { preferences.set(newValue, forKey: "retentionMinutes") }
    }
    private func releasePage(_ view: WKWebView) {
        view.stopLoading()
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setCameraCaptureState(.none, completionHandler: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
    private func prunePages(at now: Date = .now, minutes: Int? = nil) {
        let lifetime = Double(minutes ?? retentionMinutes) * 60
        evictionTimer?.invalidate()
        evictionTimer = nil
        let cutoff = now.addingTimeInterval(-lifetime)
        for (key, page) in parkedPages where page.parkedAt <= cutoff {
            releasePage(page.view)
            forgetExpiredInstant(key)
            parkedPages.removeValue(forKey: key)
        }
        while parkedPages.count > 3, let oldest = parkedPages.min(by: { $0.value.parkedAt < $1.value.parkedAt }) {
            releasePage(oldest.value.view)
            forgetExpiredInstant(oldest.key)
            parkedPages.removeValue(forKey: oldest.key)
        }
        if let oldest = parkedPages.values.map(\.parkedAt).min() {
            let delay = max(0.1, oldest.addingTimeInterval(lifetime).timeIntervalSinceNow)
            evictionTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.prunePages() }
            }
            evictionTimer?.tolerance = 1
        }
    }
    private func observePageColor(_ view: WKWebView) {
        pageURLObservation = view.observe(\.url, options: [.new]) { [weak self] view, _ in
            MainActor.assumeIsolated { if self?.webView === view { self?.rememberPinnedPage() } }
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

    /// WebKit reports the page canvas color as it changes, including website theme switches.
    /// Match the native controls to that canvas without changing the site's layout or DOM.
    private func syncPageChrome(_ webView: WKWebView) {
        let color = webView.underPageBackgroundColor ?? .windowBackgroundColor
        chromeView?.layer?.backgroundColor = color.cgColor
        if let rgb = color.usingColorSpace(.sRGB) {
            let brightness = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
            chromeView?.appearance = NSAppearance(named: brightness < 0.5 ? .darkAqua : .aqua)
        }
    }
    private var chatURL: URL { providers[selectedIndex].conversationURL ?? providers[selectedIndex].url }

    private func selectProvider(_ index: Int) {
        guard providers.indices.contains(index), !disabledURLs.contains(providers[index].key), index != selectedIndex else { return }
        rememberPinnedPage()
        prunePages()
        let oldKey = providers[selectedIndex].key
        if let old = webView {
            if let url = old.url, isProviderHost(url.host, provider: providers[selectedIndex]) { visitedURLs[oldKey] = url }
            contentStack?.removeArrangedSubview(old)
            old.removeFromSuperview()
            old.setAllMediaPlaybackSuspended(true)
            old.setMicrophoneCaptureState(.none, completionHandler: nil)
            old.setCameraCaptureState(.none, completionHandler: nil)
            parkedPages[oldKey] = ParkedPage(view: old, parkedAt: .now)
        }
        selectedIndex = index
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        if contentStack != nil {
            let cached = parkedPages.removeValue(forKey: providers[selectedIndex].key)
            let next = cached?.view ?? makeWebView()
            webView = next
            next.setAllMediaPlaybackSuspended(false)
            contentStack?.addArrangedSubview(next)
            if let resizeGrip { contentStack?.addSubview(resizeGrip, positioned: .above, relativeTo: nil) }
            observePageColor(next)
            if cached == nil { next.load(pageRequest(visitedURLs[providers[selectedIndex].key] ?? chatURL)) }
            panel?.makeFirstResponder(next)
        }
        crashReloads = []
        reloadOnShow = false
        refreshPicker()
        prunePages()
    }

    @objc private func providerChanged(_ sender: NSButton) {
        if sender.tag == selectedIndex { sender.state = .on; sender.needsDisplay = true; return }
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
            button.toolTip = preview(for: provider)
            row.addArrangedSubview(button)
        }
    }
    private func saveSessions() {
        if let data = try? JSONEncoder().encode(savedSessions) { preferences.set(data, forKey: "pinnedSessions") }
    }
    private func preview(for provider: Provider) -> String {
        let page = provider.key == providers[selectedIndex].key ? webView : parkedPages[provider.key]?.view
        let title = page?.title ?? provider.topic ?? provider.name
        let topic = topicOnly(title, provider: provider)
        return topic == "New chat" ? AppText.t(topic) : topic
    }
    private func displayName(_ provider: Provider) -> String {
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
        return parts.isDisjoint(with: ["login", "signin", "sign-in", "sign_in", "signup", "sign-up", "sign_up", "auth", "oauth", "oauth2", "logout"])
            && sensitiveQuery.isDisjoint(with: ["code", "token", "access_token", "refresh_token", "id_token", "password", "credential", "assertion", "session_token"])
    }
    private func forgetExpiredInstant(_ key: String) {
        if providers.first(where: { $0.key == key })?.isPinned != true { visitedURLs.removeValue(forKey: key) }
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
                contentStack?.removeArrangedSubview(view)
                view.removeFromSuperview()
                releasePage(view)
                webView = nil
            }
            if let destination { selectProvider(destination) }
            if let closing = providers.firstIndex(where: { $0.key == oldKey }) { deleteProvider(closing) }
            return
        } else {
            guard let url, canRemember(url, provider: provider) else { NSSound.beep(); return }
            provider.sessionID = UUID().uuidString
            provider.pinned = true
            provider.conversationURL = url
            provider.topic = String(topicOnly(title, provider: provider).prefix(100))
            savedSessions.append(provider)
            visitedURLs.removeValue(forKey: oldKey)
            selectedIndex = providers.firstIndex(where: { $0.key == provider.key }) ?? selectedIndex
        }
        preferences.set(providers[selectedIndex].key, forKey: "selectedProvider")
        saveSessions(); refreshPicker(); updateSettings()
    }

    private func isProviderHost(_ host: String?, provider: Provider) -> Bool {
        ProviderAddress.matchesWebsite(host: host, baseHost: provider.url.host)
    }
    /// OpenAI's sign-in hosts (and their subdomains): where sign-in starts from a chatgpt.com page.
    private static let openAISignInHosts = ["auth.openai.com", "auth0.openai.com"]
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = Log.make("QuickChat")
    private var panel: QuickChatPanel?
    private var webView: WKWebView?
    private var previousApp: NSRunningApplication?
    /// When the panel was last shown / last lost key, and until when a Space switch may not
    /// take its focus (see `spaceDidChange()`).
    private var shownAt: Date?
    private var lostKeyAt: Date?
    private var keepFocusUntil: Date?
    /// When the panel was last hidden.
    private var hiddenAt: Date?
    private var workspaceObservers: [NSObjectProtocol] = []
    /// Where each in-flight download is being written, for "reveal in Finder" when it finishes.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Recent automatic reloads after the web content process died, to stop a crash loop.
    private var crashReloads: [Date] = []
    /// Set when crash reloads were given up; the page reloads the next time the panel shows.
    private var reloadOnShow = false

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
            hide(restoreFocus: panel.isKeyWindow && NSApp.isActive)
        } else {
            show()
        }
    }

    func show() {
        guard !clearingWebsiteData else { return }
        settingsWindow?.orderOut(nil)
        let panel = self.panel ?? makePanel()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if let webView {
            if reloadOnShow {
                reload(webView)
                reloadOnShow = false
                crashReloads = []
            }
        }
        hiddenAt = nil
        webView?.setAllMediaPlaybackSuspended(false)
        // Don't activate the app: activation is only a request since macOS 14, and after a
        // Space switch macOS hands focus on to another app (Finder, the full-screen app) and the
        // panel loses the keyboard. A non-activating panel takes key without it, like Spotlight.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        focusComposer()
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
                    self?.reclaimFocusIfKept()
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
        previousApp = app
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
              let panel, panel.isVisible, panel.isOnActiveSpace else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible, !panel.isKeyWindow else { return }
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(self.webView)
        }
    }

    /// `restoreFocus`: give focus back to the app that was frontmost before showing.
    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        rememberPinnedPage()
        keepFocusUntil = nil
        panel.orderOut(nil)
        webView?.setMicrophoneCaptureState(.none, completionHandler: nil)
        webView?.setCameraCaptureState(.none, completionHandler: nil)
        webView?.setAllMediaPlaybackSuspended(true)
        hiddenAt = .now
        if restoreFocus { previousApp?.activate() }
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
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
        reloadOnShow = false
    }

    // MARK: Building

    private func makePanel() -> QuickChatPanel {
        let panel = QuickChatPanel(contentRect: NSRect(origin: .zero, size: QuickChatPanel.defaultSize))
        panel.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        panel.onGoBack = { [weak self] in self?.webView?.goBack() }
        panel.onGoForward = { [weak self] in self?.webView?.goForward() }
        panel.onResignKey = { [weak self] in
            self?.lostKeyAt = .now
            self?.reclaimFocusIfKept()
        }
        observeSpaceChanges()
        panel.resetSizeShortcut = resetSizeShortcut
        panel.maximizeShortcut = maximizeShortcut

        if let saved = preferences.string(forKey: "selectedProvider"),
           let index = providers.firstIndex(where: { $0.key == saved }) { selectedIndex = index }
        if disabledURLs.contains(providers[selectedIndex].key), let next = providers.firstIndex(where: { !disabledURLs.contains($0.key) }) { selectedIndex = next }
        let header = DraggableView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
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
        let webView = makeWebView()
        let stack = NSStackView(views: [header, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets()
        header.heightAnchor.constraint(equalToConstant: 40).isActive = true
        stack.wantsLayer = true
        stack.layer?.cornerRadius = 16
        stack.layer?.masksToBounds = true
        contentStack = stack
        panel.contentView = stack
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


        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            center(panel)
        }
        panel.setFrameAutosaveName(QuickChatPanel.autosaveName)

        self.panel = panel
        self.webView = webView
        refreshPicker()
        webView.load(pageRequest(chatURL))
        return panel
    }

    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + (visible.height - size.height) * 0.6))
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
        observePageColor(webView)
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

    private func focusComposer() {
        // Best effort: chatgpt.com's composer is a contenteditable #prompt-textarea.
        webView?.evaluateJavaScript("document.querySelector('#prompt-textarea')?.focus()")
    }

    /// blob: and data: URLs are page-generated files (exports, images); they're saved, never shown.
    private static func isGeneratedFile(_ url: URL?) -> Bool {
        url?.scheme == "blob" || url?.scheme == "data"
    }

    /// ~/Downloads/<name>, or "<name> 2", "<name> 3", … if that already exists (Finder-style).
    private static func uniqueDownloadURL(suggestedFilename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = (suggestedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "download" + name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
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

extension QuickChatController: WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// `window.open` / target=_blank: opens in the panel, unless `opensInBrowser` sends it to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard webView === self.webView, panel?.isVisible == true, let url = navigationAction.request.url else { return nil }
        guard url.scheme == "https" || Self.isGeneratedFile(url) else { return nil }
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
        guard webView === self.webView else { decisionHandler(.cancel); return }
        let url = navigationAction.request.url
        if let scheme = url?.scheme?.lowercased(), !["https", "about", "blob", "data"].contains(scheme) {
            decisionHandler(.cancel); return
        }
        // <a download>, blob:/data: links: save the file instead of navigating (checked first, as
        // download links often point at file hosts that would otherwise open in the browser).
        if navigationAction.shouldPerformDownload || (navigationAction.targetFrame?.isMainFrame == true && Self.isGeneratedFile(url)) {
            decisionHandler(.download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .linkActivated,
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
        guard webView === self.webView else { decisionHandler(.cancel); return }
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let isAttachment = disposition?.hasPrefix("attachment") == true
        decisionHandler(!navigationResponse.canShowMIMEType || isAttachment ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView { focusComposer(); rememberPinnedPage(); refreshPicker() }
    }

    /// macOS may kill the web content process (often while hidden, under memory pressure), which
    /// leaves the view blank; reload right away so it's ready before the panel is shown again.
    /// A page that keeps crashing it (3 times in a minute) is left until the panel is next shown.
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
            log.error("Web content process keeps terminating; reloading when the panel is next shown")
            reloadOnShow = true
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
        open.beginSheetModal(for: panel) { response in
            completionHandler(response == .OK ? open.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // Camera and microphone alike: WebKit asks the user (per page load) on chatgpt.com only.
        // macOS's own TCC prompt also appears once per app (NSCamera/NSMicrophoneUsageDescription).
        decisionHandler(webView === self.webView && panel?.isVisible == true && origin.protocol == "https" && isProviderHost(origin.host, provider: providers[selectedIndex]) ? .prompt : .deny)
    }

    // MARK: Downloads (WKDownloadDelegate)

    /// Saves straight to ~/Downloads under a unique name (like Safari): no modal sheet on the
    /// floating panel, which may be hidden by the time a slow download asks for a destination.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let destination = Self.uniqueDownloadURL(suggestedFilename: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        log.info("Downloading to \(destination.path, privacy: .public)")
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
    }
}

// MARK: - Panel

final class QuickChatPanel: NSPanel {
    static let autosaveName = "MiniChat.Panel" // pre-rename name; keeps the saved frame
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

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Local key combo that calls `resetSize()` while the panel is key (default ⌘O).
    var resetSizeShortcut: Shortcut? = .commandO
    /// Local key combo that calls `toggleMaximize()` while the panel is key (default ⌘F).
    var maximizeShortcut: Shortcut? = .commandF {
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
        title = "Quick Chat Omni"
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
    override func cancelOperation(_ sender: Any?) { onCancel?() }

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
        setFrameAutosaveName(Self.autosaveName)
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
        if event.type == .keyDown, handleLocalShortcut(event) { return }
        super.sendEvent(event)
    }

    override func close() { onCancel?() }

    /// ⌘W hides and ⌘[ / ⌘] go back / forward; the local shortcuts are caught here too, ahead
    /// of the web view (which otherwise claims ⌘ combos). The shortcut window refuses these
    /// combos; a local shortcut saved with one before that still wins, as it's checked first.
    /// Matched by character, like menu key equivalents, so they work on any keyboard layout.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleLocalShortcut(event) { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
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
        if event.clickCount == 2, let panel = window as? QuickChatPanel {
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
extension QuickChatController {
    static func runCacheSelfTest() -> Bool {
        _ = NSApplication.shared
        guard ProviderAddress.matchesWebsite(host: "perplexity.ai", baseHost: "www.perplexity.ai"),
              !ProviderAddress.matchesWebsite(host: "chatgpt.com.evil.example", baseHost: "chatgpt.com"),
              !ProviderAddress.matchesWebsite(host: "notchatgpt.com", baseHost: "chatgpt.com") else { return false }
        let suite = "dev.quickchat.omni.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = QuickChatController(preferences: defaults)
        let selected = controller.chatURL
        defaults.set("zh-Hans", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "zh-CN,zh;q=0.9" else { return false }
        defaults.set("en", forKey: "appLanguage")
        guard controller.pageRequest(selected).value(forHTTPHeaderField: "Accept-Language") == "en-US,en;q=0.9" else { return false }
        controller.reorderProviders(IndexSet(integer: 0), to: 3)
        guard controller.chatURL == selected, controller.providers[2].url == selected else { return false }
        let restored = QuickChatController(preferences: defaults)
        guard restored.providers[2].url == selected else { return false }
        guard controller.addWebsite("Example", address: "EXAMPLE.com"),
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
        guard controller.addWebsite("ChatGPT", address: selected.absoluteString) else { return false }
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
        let persisted = QuickChatController(preferences: defaults)
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
        let restoredGroups = QuickChatController(preferences: defaults)
        guard restoredGroups.pinnedFirst, restoredGroups.providers[restoredGroups.enabledTabIndices[0]].key == secondPin.key else { return false }
        controller.deleteProvider(controller.providers.firstIndex(where: { $0.key == secondPin.key })!)
        defaults.set(false, forKey: "pinnedFirst")
        guard !controller.providers[controller.enabledTabIndices[0]].isPinned else { return false }
        controller.visitedURLs[instantKey] = sessionURL
        controller.visitedURLs[pinnedKey] = sessionURL
        controller.parkedPages[instantKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast)
        controller.parkedPages[pinnedKey] = ParkedPage(view: WKWebView(), parkedAt: .distantPast)
        controller.prunePages(minutes: 0)
        guard controller.visitedURLs[instantKey] == nil, controller.savedSessions.first?.conversationURL == sessionURL else { return false }
        let hiddenPin = controller.providers.firstIndex(where: { $0.key == pinnedKey })!
        controller.toggleProvider(hiddenPin)
        let beforeUnpin = controller.providers[controller.selectedIndex].key
        controller.unpinProvider(hiddenPin)
        guard controller.savedSessions.isEmpty, controller.providers[controller.selectedIndex].key == beforeUnpin else { return false }
        let now = Date()
        for index in 0..<5 {
            controller.parkedPages[String(index)] = ParkedPage(view: WKWebView(), parkedAt: now.addingTimeInterval(-Double(index)))
        }
        controller.prunePages(at: now, minutes: 10)
        guard Set(controller.parkedPages.keys) == Set(["0", "1", "2"]) else { return false }
        controller.prunePages(at: now.addingTimeInterval(601), minutes: 10)
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.parkedPages["immediate"] = ParkedPage(view: WKWebView(), parkedAt: now)
        controller.prunePages(at: now, minutes: 0)
        guard controller.parkedPages.isEmpty, controller.evictionTimer == nil else { return false }
        controller.tearDown()
        print("Checks passed: provider ordering and persistence, URL validation, duplicate rejection, active-provider fallback, deletion and re-adding, independent sessions, pinned URL persistence, group ordering, language headers, unpinning, cache capacity, expiry and immediate release")
        return true
    }
}
#endif

#if DEBUG
extension QuickChatController {
    @MainActor
    private final class LanguageScriptProbe: NSObject, WKNavigationDelegate {
        let controller: QuickChatController
        let defaults: UserDefaults
        let view: WKWebView
        var step = 0
        var finished = false
        var passed = true
        init(controller: QuickChatController, defaults: UserDefaults) {
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
        let controller = QuickChatController(preferences: defaults)
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

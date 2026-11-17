import AppKit
import WebKit
import SwiftUI

/// Floating Quick Chat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class QuickChatController: NSObject {
    private struct Provider: Codable {
        var name: String
        var url: URL
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
    private var customProviders: [Provider] = {
        guard let data = UserDefaults.standard.data(forKey: "customProviders"),
              let providers = try? JSONDecoder().decode([Provider].self, from: data) else { return [] }
        return providers.filter { $0.url.scheme?.lowercased() == "https" && $0.url.host != nil }
    }()
    private var providers: [Provider] { Self.builtIns + customProviders }
    private var disabledURLs: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "disabledProviders") ?? [])
    private var settingsWindow: NSWindow?
    private let settingsFields = ChatSettingsFields()

    func providerMenuItems() -> [NSMenuItem] {
        providers.enumerated().map { index, provider in
            let item = ActionMenuItem(provider.name) { [weak self] in self?.toggleProvider(index) }
            item.state = disabledURLs.contains(provider.url.absoluteString) ? .off : .on
            return item
        }
    }
    private func toggleProvider(_ index: Int) {
        let key = providers[index].url.absoluteString
        if disabledURLs.contains(key) { disabledURLs.remove(key) }
        else {
            guard providers.filter({ !disabledURLs.contains($0.url.absoluteString) }).count > 1 else { NSSound.beep(); return }
            disabledURLs.insert(key)
        }
        UserDefaults.standard.set(Array(disabledURLs), forKey: "disabledProviders")
        if disabledURLs.contains(chatURL.absoluteString), let next = providers.firstIndex(where: { !disabledURLs.contains($0.url.absoluteString) }) { selectProvider(next) }
        if disabledURLs.contains(key), let page = parkedPages.removeValue(forKey: key) { releasePage(page.view) }
        prunePages()
        refreshPicker()
        updateSettings()
    }
    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Quick Chat Omni Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        updateSettings()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func updateSettings() {
        settingsWindow?.contentView = NSHostingView(rootView: ChatSettingsView(
            fields: settingsFields, retention: retentionMinutes,
            setRetention: { [weak self] minutes in
                self?.retentionMinutes = minutes; self?.prunePages(); self?.updateSettings()
            },
            providers: providers.enumerated().map { index, provider in
                ChatSettingsView.Row(id: index, name: provider.name, host: provider.url.host ?? "", enabled: !disabledURLs.contains(provider.url.absoluteString))
            }, toggle: { [weak self] in self?.toggleProvider($0) },
            add: { [weak self] name, address in
                guard let self, let url = URL(string: address), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, !self.providers.contains(where: { $0.url == url }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                self.customProviders.append(Provider(name: name, url: url))
                self.saveCustomProviders(); self.refreshPicker(); self.updateSettings()
                return true
            }))
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
            let value = UserDefaults.standard.object(forKey: "retentionMinutes") as? Int ?? 10
            return [0, 1, 5, 10, 30].contains(value) ? value : 10
        }
        set { UserDefaults.standard.set(newValue, forKey: "retentionMinutes") }
    }
    private func releasePage(_ view: WKWebView) {
        view.stopLoading()
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
            parkedPages.removeValue(forKey: key)
        }
        while parkedPages.count > 3, let oldest = parkedPages.min(by: { $0.value.parkedAt < $1.value.parkedAt }) {
            releasePage(oldest.value.view)
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
    private var chatURL: URL { providers[selectedIndex].url }

    private func selectProvider(_ index: Int) {
        guard providers.indices.contains(index), !disabledURLs.contains(providers[index].url.absoluteString), index != selectedIndex else { return }
        prunePages()
        let oldKey = chatURL.absoluteString
        if let old = webView {
            if let url = old.url, isProviderHost(url.host, provider: providers[selectedIndex]) { visitedURLs[oldKey] = url }
            contentStack?.removeArrangedSubview(old)
            old.removeFromSuperview()
            parkedPages[oldKey] = ParkedPage(view: old, parkedAt: .now)
        }
        selectedIndex = index
        UserDefaults.standard.set(chatURL.absoluteString, forKey: "selectedProvider")
        if contentStack != nil {
            let cached = parkedPages.removeValue(forKey: chatURL.absoluteString)
            let next = cached?.view ?? makeWebView()
            webView = next
            contentStack?.addArrangedSubview(next)
            if let resizeGrip { contentStack?.addSubview(resizeGrip, positioned: .above, relativeTo: nil) }
            observePageColor(next)
            if cached == nil { next.load(URLRequest(url: visitedURLs[chatURL.absoluteString] ?? chatURL)) }
            panel?.makeFirstResponder(next)
        }
        crashReloads = []
        reloadOnShow = false
        refreshPicker()
        prunePages()
    }

    @objc private func providerChanged(_ sender: NSButton) { selectProvider(sender.tag) }
    @objc private func goBack(_ sender: Any?) { webView?.goBack() }
    @objc private func goForward(_ sender: Any?) { webView?.goForward() }
    @objc private func reloadPage(_ sender: Any?) { webView?.reload() }

    private func toolbarButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    private func saveCustomProviders() {
        if let data = try? JSONEncoder().encode(customProviders) { UserDefaults.standard.set(data, forKey: "customProviders") }
    }
    private func refreshPicker() {
        guard let tabs = providerTabs else { return }
        for view in tabs.arrangedSubviews { tabs.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, provider) in providers.enumerated() where !disabledURLs.contains(provider.url.absoluteString) {
            let button = NSButton(title: provider.name, target: self, action: #selector(providerChanged(_:)))
            button.tag = index
            button.bezelStyle = .recessed
            button.setButtonType(.pushOnPushOff)
            button.state = index == selectedIndex ? .on : .off
            button.font = .systemFont(ofSize: 12, weight: index == selectedIndex ? .semibold : .regular)
            button.toolTip = provider.url.host
            tabs.addArrangedSubview(button)
            if index == selectedIndex { button.scrollToVisible(button.bounds) }
        }
    }

    private func isProviderHost(_ host: String?, provider: Provider) -> Bool {
        guard let host = host?.lowercased(), let base = provider.url.host?.lowercased() else { return false }
        return host == base || host.hasSuffix("." + base)
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
        keepFocusUntil = nil
        panel.orderOut(nil)
        hiddenAt = .now
        if restoreFocus { previousApp?.activate() }
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
        panel?.orderOut(nil)
        webView?.stopLoading()
        panel?.contentView = nil
        panel = nil
        webView = nil
        providerTabs = nil
        contentStack = nil
        evictionTimer?.invalidate()
        evictionTimer = nil
        for page in parkedPages.values { releasePage(page.view) }
        parkedPages.removeAll()
        chromeView = nil
        pageColorObservation = nil
        crashReloads = []
        reloadOnShow = false
    }

    /// Signs out by clearing the panel's website data (cookies, storage).
    func signOut() {
        let alert = NSAlert()
        alert.messageText = "Clear all provider website data?"
        alert.informativeText = "This signs you out of every provider in Quick Chat Omni and removes their local website data."
        alert.addButton(withTitle: "Clear Data")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.log.info("Cleared Quick Chat website data")
                for page in self.parkedPages.values { self.releasePage(page.view) }
                self.parkedPages.removeAll()
                self.prunePages()
                self.visitedURLs.removeAll()
                self.webView?.load(URLRequest(url: self.chatURL))
            }
        }
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

        if let saved = UserDefaults.standard.string(forKey: "selectedProvider"),
           let index = providers.firstIndex(where: { $0.url.absoluteString == saved }) { selectedIndex = index }
        if disabledURLs.contains(chatURL.absoluteString), let next = providers.firstIndex(where: { !disabledURLs.contains($0.url.absoluteString) }) { selectedIndex = next }
        let header = DraggableView()
        header.wantsLayer = true
        header.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        chromeView = header
        header.toolTip = "Drag to move · Double-click to expand"
        let tabs = NSStackView()
        tabs.orientation = .horizontal
        tabs.spacing = 4
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.documentView = tabs
        scroll.translatesAutoresizingMaskIntoConstraints = false
        tabs.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(scroll)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            tabs.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            tabs.heightAnchor.constraint(equalTo: scroll.contentView.heightAnchor)
        ])
        let close = toolbarButton("xmark", label: "Hide Chat", action: #selector(dismissPanel(_:)))
        header.addSubview(close)
        let browser = toolbarButton("arrow.up.right.square", label: "Continue in Default Browser", action: #selector(openInBrowser(_:)))
        let settings = toolbarButton("slider.horizontal.3", label: "Settings", action: #selector(showSettings))
        let controls = NSStackView(views: [browser, settings])
        controls.spacing = 12
        controls.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(controls)
        NSLayoutConstraint.activate([
            close.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: close.trailingAnchor, constant: 12),
            scroll.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 28),
            scroll.trailingAnchor.constraint(equalTo: controls.leadingAnchor, constant: -16),
            controls.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -16),
            controls.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        providerTabs = tabs
        refreshPicker()
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
            let enabled = self.providers.indices.filter { !self.disabledURLs.contains(self.providers[$0].url.absoluteString) }
            if enabled.indices.contains(offset) { self.selectProvider(enabled[offset]) }
        }

        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            center(panel)
        }
        panel.setFrameAutosaveName(QuickChatPanel.autosaveName)

        self.panel = panel
        self.webView = webView
        webView.load(URLRequest(url: chatURL))
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
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(
            source: Self.noAutocorrectScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
      const apply = () => document.querySelectorAll('#prompt-textarea, [contenteditable="true"], textarea')
        .forEach(el => {
          if (el.getAttribute('autocorrect') === 'off') return;
          el.setAttribute('autocorrect', 'off');
          el.setAttribute('autocapitalize', 'off');
          el.setAttribute('writingsuggestions', 'false');
        });
      new MutationObserver(apply).observe(document, { childList: true, subtree: true });
      apply();
    })();
    """

    private func focusComposer() {
        // Best effort: chatgpt.com's composer is a contenteditable #prompt-textarea.
        webView?.evaluateJavaScript("document.querySelector('#prompt-textarea')?.focus()")
    }

    /// chatgpt.com or a subdomain of it (not e.g. "notchatgpt.com").
    private static func isChatGPTHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
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

    /// Whether a link to `url`, clicked on the page `source`, opens in the browser. Decided by
    /// where the link was clicked, not by a list of destinations: answers only appear on
    /// chatgpt.com, so a link from there that leaves ChatGPT (and isn't its sign-in) goes to the
    /// browser. Any other page in the panel is part of a sign-in flow (Google, Apple, Microsoft,
    /// SSO), whose links stay in the panel whatever host they use.
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
        guard webView === self.webView, let url = navigationAction.request.url else { return nil }
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
        if webView === self.webView { focusComposer() }
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
        if webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: chatURL)) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard webView === self.webView, let panel else { return completionHandler(nil) }
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
        decisionHandler(webView === self.webView && origin.protocol == "https" && isProviderHost(origin.host, provider: providers[selectedIndex]) ? .prompt : .deny)
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
        let controller = QuickChatController()
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
        print("Page cache tests passed: oldest-first capacity, expiry and immediate release")
        return true
    }
}
#endif

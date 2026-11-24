import AppKit
import WebKit

extension FloatChatController {
    func retentionMinutes(forPinned pinned: Bool) -> Int {
        let legacy = preferences.object(forKey: "retentionMinutes") as? Int ?? 10
        let value = pinned ? preferences.object(forKey: "pinnedRetentionMinutes") as? Int ?? legacy : legacy
        return ChatSettingsView.retentionOptions.contains(value) ? value : 10
    }

    func setRetention(_ minutes: Int, forPinned pinned: Bool) {
        if !pinned, preferences.object(forKey: "pinnedRetentionMinutes") == nil {
            preferences.set(retentionMinutes(forPinned: true), forKey: "pinnedRetentionMinutes")
        }
        preferences.set(minutes, forKey: pinned ? "pinnedRetentionMinutes" : "retentionMinutes")
        prunePages()
        updateSettings()
    }
    func releasePage(_ view: WKWebView) {
        dictationPreview.clear(in: view)
        websiteAudioRelay.stop(in: view)
        invalidateRecordingPage(view)
        generationIndicator.stopWatching(view)
        view.stopLoading()
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setCameraCaptureState(.none, completionHandler: nil)
        view.navigationDelegate = nil
        view.uiDelegate = nil
    }
    func prunePages(at now: Date = .now) {
        evictionTimer?.invalidate()
        evictionTimer = nil
        let instantLifetime = Double(retentionMinutes(forPinned: false)) * 60
        let pinnedLifetime = Double(retentionMinutes(forPinned: true)) * 60
        var nextExpiry: Date?
        for (key, page) in parkedPages where !generationIndicator.isWatching(page.view) && !isRecordingPage(page.view) {
            let normalExpiry = page.parkedAt.addingTimeInterval(page.isPinned ? pinnedLifetime : instantLifetime)
            let recordingGrace = if let recording = recordingChat, recording.view === page.view {
                if recording.pendingAttachment {
                    recording.savedAt?.addingTimeInterval(MeetingRecorder.stagingLifetime)
                } else if recording.didHandOff {
                    // The audio is an unsent draft. Start its review window at the handoff,
                    // even if the chat's ordinary retention expired during the recording.
                    recording.savedAt?.addingTimeInterval(5 * 60)
                } else {
                    nil as Date?
                }
            } else {
                nil as Date?
            }
            let expiry = max(normalExpiry, recordingGrace ?? .distantPast)
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
        syncReplyIndicators()
    }

    func takeParkedPage(for provider: Provider) -> ParkedPage? {
        guard let page = parkedPages.removeValue(forKey: provider.key) else { return nil }
        if !isRecordingPage(page.view), let pinnedURL = provider.conversationURL,
           let currentURL = page.view.url, currentURL != pinnedURL {
            releasePage(page.view)
            return nil
        }
        return page
    }
    func websiteCaptureInProgress(_ state: WKMediaCaptureState) -> Bool {
        state == .active || state == .muted
    }

    func clearHiddenWebsiteCapture() {
        dictationPreview.pause()
        hiddenMicrophoneGrace?.cancel()
        hiddenMicrophoneGrace = nil
        hiddenMicrophonePage = nil
    }

    func websiteIsCapturing(_ view: WKWebView?) -> Bool {
        guard let view else { return false }
        return websiteAudioRelay.isCapturing(view) || websiteCaptureInProgress(view.microphoneCaptureState)
    }

    func websiteCaptureChanged(in view: WKWebView) {
        guard view === webView else { return }
        updateRecordingButton()
        updateStatus()
        guard hiddenMicrophonePage === view, panel?.isVisible == false else { return }
        if websiteIsCapturing(view) {
            hiddenMicrophoneGrace?.cancel()
            hiddenMicrophoneGrace = nil
        } else if hiddenMicrophoneGrace == nil {
            // Leave time for the site to return dictated text after it releases the microphone.
            hiddenMicrophoneGrace = Task { [weak self, weak view] in
                try? await Task.sleep(for: DictationPreview.resultLifetime)
                guard !Task.isCancelled, let self, let view, self.hiddenMicrophonePage === view,
                      self.webView === view, self.panel?.isVisible == false else { return }
                self.parkActivePage()
                self.prunePages()
            }
        }
    }

    func parkActivePage() {
        guard let view = webView else { return }
        clearHiddenWebsiteCapture()
        dictationPreview.clear(in: view)
        microphoneObservation = nil
        websiteAudioRelay.stop(in: view)
        let provider = providers[selectedIndex]
        let key = provider.key
        var parked = ParkedPage(view: view, parkedAt: .now, isPinned: provider.isPinned, failureURL: failureURL)
        if let url = provider.conversationURL {
            pinnedDrafts.capture(view, key: key, url: url)
            parked.titleObservation = view.observe(\.title, options: [.new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.rememberPinnedTitle(view.title, at: view.url, for: key) }
            }
        }
        if preferences.bool(forKey: "showGenerationIndicator"), failureURL == nil {
            generationIndicator.watch(view, key: key)
        }
        cancelPageAppearance()
        stopTrackingPageLoad()
        if effectivePanelTranslucency > 0 {
            view.evaluateJavaScript("globalThis.floatChatCanvas?.stop()", in: nil, in: .defaultClient, completionHandler: nil)
        }
        panel?.detachKeyboardFromPage(view)
        contentStack?.removeArrangedSubview(view)
        view.removeFromSuperview()
        view.setAllMediaPlaybackSuspended(true)
        view.setMicrophoneCaptureState(.none, completionHandler: nil)
        view.setCameraCaptureState(.none, completionHandler: nil)
        parkedPages[key] = parked
        webView = nil
        pageColorObservation = nil
        pageURLObservation = nil
        pageTitleObservation = nil
        updateRecordingButton()
        updateStatus()
    }

    func attachSelectedPage() {
        guard webView == nil, let contentStack else { return }
        prunePages()
        let cached = takeParkedPage(for: providers[selectedIndex])
        let view = cached?.view ?? makeWebView()
        webView = view
        generationIndicator.stopWatching(view)
        failureURL = cached?.failureURL
        view.setAllMediaPlaybackSuspended(false)
        view.pageZoom = zoom(for: providers[selectedIndex])
        contentStack.addArrangedSubview(view)
        if let resizeGrip { contentStack.addSubview(resizeGrip, positioned: .above, relativeTo: nil) }
        observePageColor(view)
        microphoneObservation = view.observe(\.microphoneCaptureState, options: [.initial, .new]) { [weak self] view, _ in
            MainActor.assumeIsolated { self?.websiteCaptureChanged(in: view) }
        }
        updateTabSelection()
        updateWebsiteIdentity()
        updateStatus()
        if cached == nil { view.load(pageRequest(chatURL)) }
        trackPageLoad(view)
        focusSelectedPage()
        attachPendingRecording()
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.userContentController.addScriptMessageHandler(websiteAudioRelay, contentWorld: .page,
                                                              name: WebsiteAudioRelay.handler)
        configureScripts(config.userContentController)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        setWebBackground(webView)
        return webView
    }

    /// Disable native writing suggestions when an editable field gains focus.
    /// The suggestion bubble can intercept the panel shortcut. Spell-check underlines stay.
    static let noAutocorrectScript = """
    (() => {
      const selector = '#prompt-textarea, [contenteditable="true"], textarea';
      const apply = target => {
        const field = target instanceof Element ? target.closest(selector) : null;
        if (!field) return;
        field.setAttribute('autocorrect', 'off');
        field.setAttribute('autocapitalize', 'off');
        field.setAttribute('writingsuggestions', 'false');
      };
      document.addEventListener('focusin', event => apply(event.target), true);
      document.addEventListener('DOMContentLoaded', () => apply(document.activeElement), { once: true });
    })();
    """

    func focusSelectedPage() {
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

    static func isHTTPSPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
    }

    /// blob: and data: URLs are page-generated files (exports, images); they're saved, never shown.
    private static func isGeneratedFile(_ url: URL?) -> Bool {
        url?.scheme == "blob" || url?.scheme == "data"
    }

    /// ~/Downloads/<name>, or "<name> 2", "<name> 3", … if that already exists (Finder-style).
    static func uniqueDownloadURL(suggestedFilename: String, reserved: Set<URL>, in downloads: URL = .downloadsDirectory) -> URL {
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
        if navigationAction.targetFrame?.isMainFrame == true, isRecordingPage(webView),
           !navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            return
        }
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
        dictationPreview.clear(in: webView)
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
        requestPageAppearance(for: webView)
        if panel?.isKeyWindow == true { focusSelectedPage() }
        let provider = providers[selectedIndex]
        if let url = provider.conversationURL {
            pinnedDrafts.restore(webView, key: provider.key, url: url)
        }
        rememberPinnedPage()
        updateTabPreviews()
        attachPendingRecording()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        websiteAudioRelay.stop(in: webView)
        invalidateRecordingPage(webView)
        if webView === self.webView {
            waitingForPage = false
            updateStatus()
            updateWebsiteIdentity()
            requestPageAppearance(for: webView)
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
        websiteAudioRelay.stop(in: webView)
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
        if isRecordingPage(webView) {
            stopTrackingPageLoad()
            failureURL = chatURL
            updateStatus()
            return
        }
        crashReloads.append(now)
        log.info("Web content process terminated; reloading")
        reload(webView)
    }

    func reload(_ webView: WKWebView) {
        guard !isRecordingPage(webView) else { return }
        if webView.url != nil { webView.reload() } else { webView.load(pageRequest(chatURL)) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        if let file = takeRecordingAttachment(in: webView, frame: frame) {
            completionHandler([file])
            return
        }
        guard webView === self.webView, let panel, panel.isVisible else { return completionHandler(nil) }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = parameters.allowsMultipleSelection
        open.canChooseDirectories = parameters.allowsDirectories
        let requestedURL = webView.url
        if frame.isMainFrame, requestedURL?.scheme == "https",
           FileManager.default.fileExists(atPath: MeetingRecorder.folder.path) {
            open.accessoryView = RecordingPickerShortcut(picker: open)
            open.isAccessoryViewDisclosed = true
        }
        open.beginSheetModal(for: panel) { [weak self, weak webView] response in
            guard let self, let webView, webView === self.webView, panel.isVisible, webView.url == requestedURL else {
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
        // Websites receive audio exclusively through the consented Core Audio relay.
        // Never open a hardware microphone on a webpage's behalf, including in subframes.
        decisionHandler(Self.nativeWebsiteCaptureDecision(type, fromTrustedPage: allowed))
    }

    static func nativeWebsiteCaptureDecision(_ type: WKMediaCaptureType, fromTrustedPage trusted: Bool) -> WKPermissionDecision {
        trusted && type == .camera ? .prompt : .deny
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

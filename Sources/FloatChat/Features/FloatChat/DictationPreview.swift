import AppKit
import WebKit

/// Shows a short excerpt from the site's composer during an approved audio session.
@MainActor
final class DictationPreview {
    static let resultLifetime: Duration = .seconds(30)
    private weak var page: WKWebView?
    private var address: URL?
    private var session: String?
    private var captureEnd: ContinuousClock.Instant?
    private var observation: Task<Void, Never>?
    struct Presentation: Equatable {
        let text: String
        let isExcerpt: Bool
    }

    private var expanded = false
    private var latestExcerpt = ""
    private var localCaption = ""
    private var localCaptionsUnavailable = false
    private var onChange: (() -> Void)?
    private(set) var presentation: Presentation?

    static let readScript = #"""
        if (location.href !== new URL(address).href) return null;
        if (start) globalThis.floatChatDictationDraft = { session, text: null };
        const field = composer(start);
        if (!field) return null;
        const text = read(field).trim();
        if (text.length > 32000) return null;
        const baseline = globalThis.floatChatDictationDraft;
        if (baseline?.session !== session) return null;
        if (start) {
            baseline.text = text;
            return null;
        }
        // A provider can temporarily unmount the editor. Wait for a known empty
        // editor in that case so an existing draft never becomes a preview.
        if (baseline.text === null) {
            if (text === '') baseline.text = '';
            return null;
        }
        const previous = baseline.text;
        if (text.length <= previous.length) return null;
        // Dictation can insert at the caret, including in the middle of a draft.
        let prefix = 0;
        while (prefix < previous.length && previous[prefix] === text[prefix]) prefix++;
        if (!text.endsWith(previous.slice(prefix))) return null;
        return text.slice(prefix, prefix + text.length - previous.length).trim().replace(/\s+/g, ' ').slice(-220);
        """#

    func captureStarted(in view: WKWebView) {
        clear()
        guard let url = view.url else { return }
        let token = UUID().uuidString
        page = view
        address = url
        session = token
        view.callAsyncJavaScript(PinnedDrafts.composer + Self.readScript,
                                 arguments: ["address": url.absoluteString, "session": token, "start": true],
                                 in: nil, in: .defaultClient, completionHandler: nil)
    }

    func captureEnded(in view: WKWebView) {
        guard page === view else { return }
        captureEnd = .now
        refresh()
    }

    func updateCaption(_ text: String) {
        guard session != nil else { return }
        localCaption = text
        refresh()
    }

    func captionsUnavailable() {
        localCaptionsUnavailable = true
        refresh()
    }

    func canWatch(_ view: WKWebView) -> Bool {
        page === view && view.url == address
            && (captureEnd.map { ContinuousClock.now - $0 < Self.resultLifetime } ?? true)
    }

    func checkAddress(in view: WKWebView) {
        if page === view, view.url != address { clear(in: view) }
    }

    func pause() {
        observation?.cancel()
        observation = nil
        expanded = false
        latestExcerpt = ""
        let notify = onChange
        onChange = nil
        if presentation != nil {
            presentation = nil
            notify?()
        }
    }

    func clear(in view: WKWebView? = nil) {
        guard view == nil || page === view else { return }
        pause()
        if let page, let session {
            page.callAsyncJavaScript("""
                if (globalThis.floatChatDictationDraft?.session === session) {
                    delete globalThis.floatChatDictationDraft;
                }
                """, arguments: ["session": session], in: nil, in: .defaultClient, completionHandler: nil)
        }
        page = nil
        address = nil
        session = nil
        captureEnd = nil
        localCaption = ""
        localCaptionsUnavailable = false
    }

    func toggle(in view: WKWebView) -> Bool {
        guard canWatch(view), observation != nil else { return false }
        expanded.toggle()
        refresh()
        return true
    }

    func startWhileHidden(_ view: WKWebView, onChange: @escaping () -> Void) {
        guard observation == nil, canWatch(view), let address, let session else { return }
        self.onChange = onChange
        observation = Task { [weak self, weak view] in
            while !Task.isCancelled, let self, let view, self.canWatch(view) {
                let result = try? await view.callAsyncJavaScript(PinnedDrafts.composer + Self.readScript,
                                                                arguments: ["address": address.absoluteString, "session": session, "start": false],
                                                                in: nil, contentWorld: .defaultClient)
                guard !Task.isCancelled, view.url == address, self.session == session else { break }
                self.latestExcerpt = result as? String ?? ""
                self.refresh()
                try? await Task.sleep(for: .milliseconds(650), tolerance: .milliseconds(100))
            }
            if !Task.isCancelled { self?.clear() }
        }
    }

    private func refresh() {
        let next: Presentation?
        if !expanded {
            next = nil
        } else if !latestExcerpt.isEmpty, captureEnd != nil {
            next = Presentation(text: String(latestExcerpt.suffix(112)), isExcerpt: true)
        } else if !localCaption.isEmpty {
            next = Presentation(text: localCaption, isExcerpt: true)
        } else if !latestExcerpt.isEmpty {
            next = Presentation(text: String(latestExcerpt.suffix(112)), isExcerpt: true)
        } else {
            let status = if captureEnd != nil { "Waiting for transcript…" }
                         else if localCaptionsUnavailable { "Live captions unavailable" }
                         else { "Listening for speech…" }
            next = Presentation(text: AppText.t(status), isExcerpt: false)
        }
        guard next != presentation else { return }
        presentation = next
        onChange?()
    }
}

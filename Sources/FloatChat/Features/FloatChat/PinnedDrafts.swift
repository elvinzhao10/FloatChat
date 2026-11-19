import WebKit

/// In-memory text recovery for the exact conversation pinned by the user.
@MainActor
final class PinnedDrafts {
    private var text: [String: String] = [:]
    private var pending: [String: UUID] = [:]

    func forget(_ key: String) {
        text.removeValue(forKey: key)
        pending.removeValue(forKey: key)
    }

    func clear() {
        text.removeAll()
        pending.removeAll()
    }

    private static let composer = #"""
        const composer = () => {
            const host = location.hostname.replace(/^www\./, '');
            const selector = host === 'chatgpt.com'
                ? '#prompt-textarea:is([contenteditable="true"], textarea)'
                : host === 'claude.ai' ? '.ProseMirror[contenteditable="true"]' : null;
            if (!selector) return null;
            const fields = [...document.querySelectorAll(selector)].filter(field => field.getClientRects().length);
            return fields.length === 1 ? fields[0] : null;
        };
        const read = field => 'value' in field ? field.value : field.innerText;
        """#

    func capture(_ view: WKWebView, key: String, url: URL) {
        guard view.url == url else { return }
        let capture = UUID()
        pending[key] = capture
        view.callAsyncJavaScript(Self.composer + """
            globalThis.floatChatRestoreDraft = null;
            if (location.href !== new URL(address).href) return null;
            const field = composer();
            return field ? read(field).slice(0, 32000) : null;
            """, arguments: ["address": url.absoluteString], in: nil, in: .defaultClient) { [weak self] result in
                guard let self, self.pending[key] == capture else { return }
                self.pending.removeValue(forKey: key)
                guard case .success(let value) = result, let draft = value as? String else { return }
                self.text[key] = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : draft
            }
    }

    func restore(_ view: WKWebView, key: String, url: URL) {
        guard view.url == url, let draft = text[key] else { return }
        view.callAsyncJavaScript(Self.composer + """
            const token = {};
            globalThis.floatChatRestoreDraft = token;
            for (let attempt = 0; attempt < 20; attempt++) {
                if (globalThis.floatChatRestoreDraft !== token || location.href !== new URL(address).href) return;
                const field = composer();
                if (field) {
                    if (read(field).trim() !== '') return;
                    const focused = document.activeElement;
                    if (focused !== field && focused !== document.body && focused !== document.documentElement) return;
                    field.focus();
                    document.execCommand('insertText', false, draft);
                    return;
                }
                await new Promise(resolve => setTimeout(resolve, 150));
            }
            """, arguments: ["address": url.absoluteString, "draft": draft], in: nil, in: .defaultClient, completionHandler: nil)
    }
}

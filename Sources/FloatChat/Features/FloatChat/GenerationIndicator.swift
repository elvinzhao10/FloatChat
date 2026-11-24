import AppKit
import QuartzCore
import WebKit

/// Checks parked chats on a shared timer. Idle or unrecognized pages leave the queue quickly.
@MainActor
final class GenerationIndicator {
    private final class Session {
        weak var page: WKWebView?
        let key: String
        let started = Date.now
        let deadline = Date.now.addingTimeInterval(300)
        var misses = 0
        var checking = false
        var generating = false

        init(page: WKWebView, key: String) {
            self.page = page
            self.key = key
        }
    }

    private var sessions: [ObjectIdentifier: Session] = [:]
    private var timer: Timer?
    private var window: NSPanel?
    private var pendingHide: Task<Void, Never>?
    private var position: NSPoint?
    var onChange: (() -> Void)?

    var generatingKeys: Set<String> { Set(sessions.values.filter(\.generating).map(\.key)) }
    var mostRecentKey: String? {
        sessions.values.filter(\.generating).max { $0.started < $1.started }?.key
    }

    func isWatching(_ page: WKWebView) -> Bool { sessions[ObjectIdentifier(page)] != nil }

    func watch(_ page: WKWebView, key: String) {
        guard page.url?.scheme == "https", !isWatching(page) else { return }
        let id = ObjectIdentifier(page)
        let session = Session(page: page, key: key)
        sessions[id] = session
        if timer == nil {
            let timer = Timer(timeInterval: 0.65, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.12
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        probe(id, session: session)
    }

    private func poll() {
        for (id, session) in sessions { probe(id, session: session) }
    }

    private func probe(_ id: ObjectIdentifier, session: Session) {
        let now = Date.now
        // A turn can take several seconds to mount its stop control after the page is parked.
        let startupDeadline = session.started.addingTimeInterval(6)
        guard let page = session.page, now < (session.generating ? session.deadline : startupDeadline) else {
            remove(id, notify: true)
            return
        }
        guard !session.checking else { return }
        session.checking = true
        page.evaluateJavaScript(Self.generating, in: nil, in: .defaultClient) { [weak self, weak session] result in
            guard let self, let session, self.sessions[id] === session else { return }
            session.checking = false
            if case .success(let value) = result, value as? Bool == true {
                session.misses = 0
                if !session.generating {
                    session.generating = true
                    self.onChange?()
                }
            } else {
                session.misses += 1
                if session.generating && session.misses >= 2 { self.remove(id, notify: true) }
            }
        }
    }

    func stopWatching(_ page: WKWebView) { remove(ObjectIdentifier(page), notify: false) }

    private func remove(_ id: ObjectIdentifier, notify: Bool) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        if sessions.isEmpty {
            timer?.invalidate()
            timer = nil
        }
        if notify { onChange?() }
    }

    func stop() {
        sessions.removeAll()
        timer?.invalidate()
        timer = nil
        hide()
    }

    static let generating = #"""
        (() => {
            if (location.protocol !== 'https:') return false;
            const ids = ['stop-button', 'stop-generating-button', 'stop-generation-button', 'stop-response-button', 'chat-stop-button'];
            const labels = ['Stop generating', 'Stop generating response', 'Stop generating a response', 'Stop generation',
                'Stop response', 'Stop reply', 'Stop streaming', 'Stop generating the response', '停止生成', '停止回复', '停止回答', '停止响应', '停止產生', '停止回覆'];
            const selector = [
                ...ids.map(id => '[data-testid="' + id + '"]:is(button, [role="button"])'),
                '[data-testid="composer"] button[aria-label="Stop" i]',
                'form:has(#prompt-textarea, .ProseMirror) button[aria-label="Stop" i]',
                ...labels.flatMap(label => ['button[aria-label="' + label + '" i]',
                    'button[title="' + label + '" i]', '[role="button"][aria-label="' + label + '" i]'])
            ].join(',');
            for (const control of document.querySelectorAll(selector)) {
                if (control.matches(':disabled, [aria-disabled="true"]') || control.closest('[hidden], [inert], [aria-hidden="true"]')) continue;
                // A detached WKWebView may have no measurable layout. Check CSS visibility independently.
                if (getComputedStyle(control).visibility !== 'visible') continue;
                let suppressed = false;
                for (let node = control; node; node = node.parentElement) {
                    if (getComputedStyle(node).display === 'none') {
                        suppressed = true;
                        break;
                    }
                }
                if (!suppressed) return true;
            }
            return false;
        })()
        """#

    func hide() {
        guard let panel = window, pendingHide == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.orderOut(nil)
            window = nil
            return
        }
        fade(panel, to: 0, duration: 0.09)
        pendingHide = Task { [weak self, weak panel] in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled, let self, let panel, self.window === panel else { return }
            panel.orderOut(nil)
            self.window = nil
            self.pendingHide = nil
        }
    }

    private func fade(_ panel: NSPanel, to target: Float, duration: TimeInterval) {
        guard let layer = panel.contentView?.layer else { return }
        let from = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.opacity = target
        CATransaction.commit()
        guard duration > 0 else {
            layer.removeAnimation(forKey: "visibility")
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = target
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(animation, forKey: "visibility")
    }

    func show(near frame: NSRect, reopen: @escaping @MainActor @Sendable () -> Void) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let panel = window {
            if pendingHide != nil {
                pendingHide?.cancel()
                pendingHide = nil
                fade(panel, to: 1, duration: reduceMotion ? 0 : 0.11)
            }
            return
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: frame.midX, y: frame.midY)) })
                ?? NSScreen.main else { return }
        let area = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let size: CGFloat = 34
        let origin = NSPoint(x: frame.midX < area.midX ? area.minX : area.maxX - size,
                             y: frame.midY < area.midY ? area.minY : area.maxY - size)
        let remembered = position.flatMap { value in NSScreen.screens.contains { $0.visibleFrame.contains(value) } ? value : nil }
        let panel = NSPanel(contentRect: NSRect(origin: remembered ?? origin, size: NSSize(width: size, height: size)),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let button = ActivityBall(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.onPress = reopen
        button.moved = { [weak self] in self?.position = $0 }
        panel.contentView = button
        window = panel
        if !reduceMotion { fade(panel, to: 0, duration: 0) }
        panel.orderFrontRegardless()
        if !reduceMotion { fade(panel, to: 1, duration: 0.11) }
    }
}

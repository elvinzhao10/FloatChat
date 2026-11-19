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
        let button = GenerationBall(frame: NSRect(x: 0, y: 0, width: size, height: size))
        button.reopen = reopen
        button.moved = { [weak self] in self?.position = $0 }
        panel.contentView = button
        window = panel
        if !reduceMotion { fade(panel, to: 0, duration: 0) }
        panel.orderFrontRegardless()
        if !reduceMotion { fade(panel, to: 1, duration: 0.11) }
    }
}

@MainActor
private final class GenerationBall: NSView {
    var reopen: (() -> Void)?
    var moved: ((NSPoint) -> Void)?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let puck = CALayer()
        puck.frame = bounds.insetBy(dx: 6, dy: 6)
        puck.cornerRadius = puck.bounds.width / 2
        puck.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        puck.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        puck.borderWidth = 1
        layer?.addSublayer(puck)
        let center = CALayer()
        center.frame = puck.bounds.insetBy(dx: 7, dy: 7)
        center.cornerRadius = center.bounds.width / 2
        center.backgroundColor = NSColor.white.withAlphaComponent(0.78).cgColor
        puck.addSublayer(center)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "transform.scale")
            pulse.fromValue = 0.86
            pulse.toValue = 1.07
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            puck.add(pulse, forKey: "pulse")
        }
        toolTip = AppText.t("Chat is generating. Click to reopen or drag to move.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        reopen?()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        start = NSEvent.mouseLocation
        origin = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start, let origin, let window else { return }
        let pointer = NSEvent.mouseLocation
        let dx = pointer.x - start.x
        let dy = pointer.y - start.y
        guard dragging || abs(dx) + abs(dy) >= 4 else { return }
        dragging = true
        guard let area = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame else { return }
        window.setFrameOrigin(NSPoint(x: min(max(origin.x + dx, area.minX), area.maxX - bounds.width),
                                      y: min(max(origin.y + dy, area.minY), area.maxY - bounds.height)))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging, let origin = window?.frame.origin { moved?(origin) }
        else { reopen?() }
        start = nil
        origin = nil
    }
}

import AppKit
import WebKit

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
final class DraggableView: NSView {
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
final class ResizeGrip: NSView {
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

import AppKit
import QuartzCore

/// Flat native control with a selection underline and local drag reordering.
final class ChatTabButton: NSButton, NSDraggingSource {
    private static let dragType = NSPasteboard.PasteboardType("dev.quickchat.omni.chat-tab")
    private var hoverTracking: NSTrackingArea?
    private var hovered = false
    private var dragging = false
    private var insertionDirection: CGFloat = 0
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    var tabKey = ""
    var pinned = false
    var generating = false {
        didSet {
            guard generating != oldValue else { return }
            setAccessibilityValue(generating ? AppText.t("Generating reply") : nil)
            needsDisplay = true
        }
    }
    var onReorder: ((String, String) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([Self.dragType])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([Self.dragType]) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && !dragging {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 7, yRadius: 7).fill()
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: bounds.midX, yBy: bounds.midY)
            transform.scale(by: 1.05)
            transform.translateX(by: -bounds.midX, yBy: -bounds.midY)
            transform.concat()
            super.draw(dirtyRect)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            super.draw(dirtyRect)
        }
        if state == .on {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 1, width: bounds.width - 18, height: 2), xRadius: 1, yRadius: 1).fill()
        }
        if generating {
            NSColor.labelColor.withAlphaComponent(0.72).setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 3.5, y: bounds.maxY - 7.5, width: 4, height: 4))
            ring.lineWidth = 1
            ring.stroke()
        }
        if pinned {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.maxX - 6, y: bounds.maxY - 6, width: 3, height: 3)).fill()
        }
    }
    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { performClick(nil); return }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                let payload = NSPasteboardItem()
                payload.setString(tabKey, forType: Self.dragType)
                let item = NSDraggingItem(pasteboardWriter: payload)
                let preview = NSImage(size: bounds.size, flipped: false) { [icon = image] rect in
                    let shadow = NSShadow()
                    shadow.shadowOffset = NSSize(width: 0, height: -2)
                    shadow.shadowBlurRadius = 4
                    shadow.shadowColor = .black.withAlphaComponent(0.24)
                    shadow.set()
                    NSColor.controlBackgroundColor.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 3), xRadius: 7, yRadius: 7).fill()
                    NSShadow().set()
                    icon?.draw(in: NSRect(x: rect.midX - 10, y: rect.midY - 10, width: 20, height: 20))
                    return true
                }
                item.setDraggingFrame(bounds.offsetBy(dx: 0, dy: 2), contents: preview)
                dragging = true
                alphaValue = 0.3
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        alphaValue = 1
        hovered = false
        needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? ChatTabButton, source !== self,
              source.pinned == pinned, source.superview === superview else { return [] }
        insertionDirection = source.frame.minX < frame.minX ? -1 : 1
        previewInsertion(insertionDirection)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { previewInsertion(0) }

    private func previewInsertion(_ direction: CGFloat) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let tabs = (superview as? NSStackView)?.arrangedSubviews ?? []
        let peer = tabs.firstIndex(of: self).flatMap { index in
            let adjacent = index + Int(insertionDirection)
            return tabs.indices.contains(adjacent) ? tabs[adjacent] : nil
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.14)
        layer?.setAffineTransform(CGAffineTransform(translationX: direction * 4, y: 0))
        if peer !== self { peer?.layer?.setAffineTransform(CGAffineTransform(translationX: direction * 2, y: 0)) }
        CATransaction.commit()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? ChatTabButton, source !== self,
              source.pinned == pinned, source.superview === superview else { return false }
        previewInsertion(0)
        onReorder?(source.tabKey, tabKey)
        return true
    }
}

/// Both trackpad swipes and a mouse wheel move the strip, with no visible scroll chrome.
final class ChatTabScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        let limit = max(0, (documentView?.bounds.width ?? 0) - contentView.bounds.width)
        let x = min(limit, max(0, contentView.bounds.origin.x - delta * scale))
        contentView.scroll(to: NSPoint(x: x, y: 0))
        reflectScrolledClipView(contentView)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, let panel = window as? FloatChatPanel { panel.titleBarDoubleClicked(event) }
        else { window?.performDrag(with: event) }
    }
}

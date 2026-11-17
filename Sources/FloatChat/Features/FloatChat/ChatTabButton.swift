import AppKit

/// Flat native control with a selection underline and local drag reordering.
final class ChatTabButton: NSButton, NSDraggingSource {
    private static let dragType = NSPasteboard.PasteboardType("dev.quickchat.omni.chat-tab")
    var contextMenu: (() -> NSMenu?)?
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?() }
    var tabKey = ""
    var pinned = false
    var onReorder: ((String, String) -> Void)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([Self.dragType])
    }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([Self.dragType]) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if state == .on {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(roundedRect: NSRect(x: 9, y: 1, width: bounds.width - 18, height: 2), xRadius: 1, yRadius: 1).fill()
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
                item.setDraggingFrame(bounds, contents: image)
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let source = sender.draggingSource as? ChatTabButton, source !== self, source.pinned == pinned else { return [] }
        return .move
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? ChatTabButton, source !== self, source.pinned == pinned else { return false }
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

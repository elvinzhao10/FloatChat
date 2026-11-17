import AppKit

/// The app's speech-ring mark as a monochrome macOS status item.
enum MenuBarIcon {
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let ring = NSBezierPath()
            ring.appendArc(withCenter: NSPoint(x: 8.7, y: 9.2), radius: 5.9,
                           startAngle: -23, endAngle: 303)
            ring.line(to: NSPoint(x: 14.7, y: 2.6))
            ring.line(to: NSPoint(x: 14.1, y: 6.9))
            ring.close()
            ring.lineWidth = 1.6
            ring.lineJoinStyle = .round
            ring.stroke()
            NSBezierPath(ovalIn: NSRect(x: 7.65, y: 8.15, width: 2.1, height: 2.1)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Quick Chat Omni"
        return image
    }
}

import AppKit
import QuartzCore

@MainActor
final class ActivityBall: NSView {
    static let recordingSize: CGFloat = 40
    var onPress: (() -> Void)?
    var moved: ((NSPoint) -> Void)?
    private var start: NSPoint?
    private var origin: NSPoint?
    private var dragging = false
    private let puck = CALayer()
    private let signal = CALayer()
    private let halo = CALayer()
    private var displayedLevel: Float = 0
    private var renderedLevel: Float = 0
    private var reducedMotion = false

    init(frame: NSRect, recording: Bool = false) {
        super.init(frame: frame)
        wantsLayer = true
        let inset: CGFloat = recording ? 4 : 5
        puck.frame = bounds.insetBy(dx: inset, dy: inset)
        puck.cornerRadius = puck.bounds.width / 2
        puck.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        puck.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        puck.borderWidth = recording ? 0 : 0.5
        puck.shadowColor = NSColor.black.cgColor
        puck.shadowOpacity = 0.28
        puck.shadowRadius = 4
        puck.shadowOffset = CGSize(width: 0, height: -1)
        puck.shadowPath = CGPath(ellipseIn: puck.bounds, transform: nil)
        layer?.addSublayer(puck)
        if recording {
            halo.frame = puck.bounds.insetBy(dx: 4, dy: 4)
            halo.contents = Self.recordingGlow
            halo.opacity = 0.24
            puck.addSublayer(halo)
        }
        let radius: CGFloat = recording ? 6 : 4
        signal.frame = NSRect(x: puck.bounds.midX - radius, y: puck.bounds.midY - radius,
                              width: 2 * radius, height: 2 * radius)
        signal.cornerRadius = radius
        signal.backgroundColor = (recording ? NSColor.systemRed : NSColor.white).cgColor
        puck.addSublayer(signal)
        if !recording, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.38
            pulse.toValue = 0.9
            pulse.duration = 1.05
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            signal.add(pulse, forKey: "pulse")
        }
        toolTip = AppText.t(recording ? "Recording microphone. Click to stop, or drag to move."
                                     : "Chat is generating. Click to reopen or drag to move.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    // Rasterize the falloff once. Core Animation only scales and fades the cached texture.
    private static let recordingGlow: CGImage? = {
        let size = 128
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let red = NSColor.systemRed
        let colors = [red.cgColor, red.withAlphaComponent(0.45).cgColor, red.withAlphaComponent(0).cgColor]
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray,
                                        locations: [0, 0.5, 1]) else { return nil }
        let radius = CGFloat(size) / 2
        let center = CGPoint(x: radius, y: radius)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                   endCenter: center, endRadius: radius, options: [])
        return context.makeImage()
    }()

    func updateAudioLevel(_ amplitude: Float) {
        let decibels = 20 * log10(max(amplitude, 0.0001))
        let level = min(1, max(0, (decibels + 48) / 36))
        let rising = level > displayedLevel
        displayedLevel += (level - displayedLevel) * (rising ? 0.8 : 0.32)
        if displayedLevel < 0.02 { displayedLevel = 0 }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard abs(renderedLevel - displayedLevel) >= 0.025 || reduceMotion != reducedMotion
                || (displayedLevel == 0 && renderedLevel != 0) else { return }
        renderedLevel = displayedLevel
        reducedMotion = reduceMotion
        let scale = reduceMotion ? 1 : CGFloat(1 + 0.48 * displayedLevel)
        let fromTransform = halo.presentation()?.transform ?? halo.transform
        let fromOpacity = halo.presentation()?.opacity ?? halo.opacity
        let opacity = 0.24 + 0.52 * displayedLevel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.transform = CATransform3DMakeScale(scale, scale, 1)
        halo.opacity = opacity
        if reduceMotion {
            halo.removeAllAnimations()
        } else {
            let size = CABasicAnimation(keyPath: "transform")
            size.fromValue = NSValue(caTransform3D: fromTransform)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fromOpacity
            for animation in [size, fade] {
                animation.duration = rising ? 0.10 : 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                halo.add(animation, forKey: animation.keyPath)
            }
        }
        CATransaction.commit()
    }

    func setRecordingActive(_ active: Bool) {
        halo.isHidden = !active
        signal.backgroundColor = (active ? NSColor.systemRed : NSColor.white).cgColor
    }

    func setEmbedded(_ embedded: Bool) {
        puck.backgroundColor = (embedded ? NSColor.clear : NSColor.black.withAlphaComponent(0.9)).cgColor
        puck.shadowOpacity = embedded ? 0 : 0.28
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
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
        window.setFrameOrigin(NSPoint(x: min(max(origin.x + dx, area.minX), area.maxX - window.frame.width),
                                      y: min(max(origin.y + dy, area.minY), area.maxY - window.frame.height)))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging, let origin = window?.frame.origin { moved?(origin) }
        else { onPress?() }
        start = nil
        origin = nil
    }
}

import AppKit

/// An expandable recording control. The dot keeps its screen position when the pill opens.
@MainActor
final class RecordingIndicatorContent: NSView {
    let ball: ActivityBall
    var onOpenChat: (() -> Void)?
    private var presentation: DictationPreview.Presentation?
    private let backdrop = NSVisualEffectView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton()

    init(size: CGFloat) {
        let frame = NSRect(x: 0, y: 0, width: size, height: size)
        ball = ActivityBall(frame: frame, recording: true)
        super.init(frame: frame)
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerCurve = .continuous
        backdrop.layer?.cornerRadius = 20
        backdrop.layer?.masksToBounds = true
        backdrop.isHidden = true
        addSubview(backdrop)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingHead
        label.isHidden = true
        addSubview(label)
        button.isBordered = false
        button.isTransparent = true
        button.target = self
        button.action = #selector(openChat)
        button.toolTip = AppText.t("Open Chat")
        button.setAccessibilityLabel(button.toolTip)
        button.isHidden = true
        addSubview(button)
        addSubview(ball)
    }

    required init?(coder: NSCoder) { nil }

    var dotFrame: NSRect? { window?.convertToScreen(ball.convert(ball.bounds, to: nil)) }

    func present(_ preview: DictationPreview.Presentation?) {
        guard preview != presentation, let window, let dot = dotFrame else { return }
        presentation = preview
        let area = (window.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 4, dy: 4) ?? dot
        let leftSpace = dot.minX - area.minX
        let rightSpace = area.maxX - dot.maxX
        let left = leftSpace >= rightSpace
        let extra = preview == nil ? 0 : min(238, max(leftSpace, rightSpace))
        let expanded = extra >= 90
        let height = dot.height
        let size = NSSize(width: dot.width + (expanded ? extra : 0), height: height)
        let origin = NSPoint(x: expanded && left ? dot.minX - extra : dot.minX, y: dot.minY)
        window.setFrame(NSRect(origin: origin, size: size), display: false)
        backdrop.frame = bounds.insetBy(dx: 2, dy: 1)
        ball.frame.origin = NSPoint(x: expanded && left ? extra : 0, y: 0)
        ball.setEmbedded(expanded)
        backdrop.isHidden = !expanded
        label.isHidden = !expanded
        button.isHidden = !expanded
        window.hasShadow = expanded
        if expanded, let preview {
            let textX = left ? CGFloat.zero : dot.width
            label.stringValue = preview.text
            label.textColor = preview.isExcerpt ? .labelColor : .secondaryLabelColor
            let textBounds = NSRect(x: 0, y: 0, width: extra - 12, height: height - 4)
            let textHeight = min(textBounds.height, ceil(label.cell?.cellSize(forBounds: textBounds).height ?? height))
            label.frame = NSRect(x: textX + (left ? 12 : 0), y: (height - textHeight) / 2,
                                 width: textBounds.width, height: textHeight)
            button.frame = NSRect(x: textX, y: 0, width: extra, height: height)
        } else {
            label.stringValue = ""
        }
        window.displayIfNeeded()
        window.invalidateShadow()
    }

    @objc private func openChat() { onOpenChat?() }
}

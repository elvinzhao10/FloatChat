import AppKit

/// A floating control above the chat. It stays out of the page's layout.
@MainActor
final class RecordingOverlay: NSVisualEffectView {
    private let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)!)
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "", target: nil, action: nil)

    init(target: AnyObject, action: Selector) {
        super.init(frame: .zero)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true

        dot.symbolConfiguration = .init(pointSize: 7, weight: .regular)
        dot.contentTintColor = .systemRed
        label.font = .systemFont(ofSize: 12, weight: .medium)
        button.bezelStyle = .inline
        button.controlSize = .small
        button.target = target
        button.action = action
        let row = NSStackView(views: [dot, label, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 7
        row.detachesHiddenViews = true
        row.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    func display(_ title: String?, recording: Bool = false, action: String? = nil, help: String? = nil) {
        guard let title else { isHidden = true; return }
        dot.isHidden = !recording
        label.stringValue = AppText.t(title)
        let label = action.map(AppText.t)
        button.isHidden = label == nil
        button.title = label ?? ""
        button.setAccessibilityLabel(label)
        toolTip = help.map(AppText.t)
        isHidden = false
    }
}

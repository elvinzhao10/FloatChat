import SwiftUI
import AppKit

/// A separate hit target so a Form's toggle or picker does not consume the help hover.
struct SettingsHelpButton: NSViewRepresentable {
    let explanation: String

    func makeNSView(context: Context) -> HelpButton { HelpButton() }

    func updateNSView(_ button: HelpButton, context: Context) {
        button.explanation = explanation
        button.setAccessibilityHelp(explanation)
    }

    final class HelpButton: NSButton {
        var explanation = ""
        private var tracking: NSTrackingArea?
        private var helpPopover: NSPopover?

        init() {
            super.init(frame: .zero)
            image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
            imagePosition = .imageOnly
            contentTintColor = .secondaryLabelColor
            isBordered = false
            target = self
            action = #selector(showHelp)
            setAccessibilityLabel(AppText.t("Help"))
        }

        required init?(coder: NSCoder) { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) { showHelp() }

        override func mouseExited(with event: NSEvent) { helpPopover?.performClose(nil) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { helpPopover?.close() }
            super.viewWillMove(toWindow: newWindow)
        }

        @objc private func showHelp() {
            guard window != nil, helpPopover?.isShown != true, !explanation.isEmpty else { return }
            let content = NSHostingController(rootView: Text(explanation)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(12))
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = false
            popover.contentViewController = content
            helpPopover = popover
            popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        }
    }
}

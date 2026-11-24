import SwiftUI
import AppKit

/// Gives form labels a native tooltip anchored to the help icon.
struct SettingsHelpButton: NSViewRepresentable {
    let explanation: String

    func makeNSView(context: Context) -> NSImageView {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        icon.imageScaling = .scaleNone
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityElement(true)
        icon.setAccessibilityLabel(AppText.t("Help"))
        return icon
    }

    func updateNSView(_ icon: NSImageView, context: Context) {
        icon.toolTip = explanation
        icon.setAccessibilityHelp(explanation)
    }
}

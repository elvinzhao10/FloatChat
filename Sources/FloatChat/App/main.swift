import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    if ProcessInfo.processInfo.environment["FLOATCHAT_SELFTEST"] == "language" {
        exit(FloatChatController.runLanguageSelfTest() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["FLOATCHAT_SELFTEST"] == "shortcuts" {
        exit(GlobalHotKey.runAvailabilitySelfTest() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["FLOATCHAT_SELFTEST"] == "panel" {
        exit(FloatChatController.runPanelSelfTest() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["FLOATCHAT_SELFTEST"] == "pages" {
        exit(FloatChatController.runCacheSelfTest() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["FLOATCHAT_SELFTEST"] == "keymap" {
        exit(KeymapSelfTest.run() ? 0 : 1)
    }
    // Opens FloatChat panel without enabling any feature (no keymap changes).
    if ProcessInfo.processInfo.environment["FLOATCHAT_DEBUG"] == "panel" {
        _ = NSApplication.shared
        AppText.applyOwnLanguage()
        EditMenu.install()
        let chat = FloatChatController()
        let previewRecorder = ShortcutRecorderWindow()
        chat.configureShortcut = { [weak chat] in
            guard let chat else { return }
            if previewRecorder.isOpen { previewRecorder.bringToFront(); return }
            previewRecorder.show(current: Shortcut.load(), resetSize: chat.resetSizeShortcut, maximize: chat.maximizeShortcut, miniShortcut: nil,
                onChange: { $0.save() },
                onResetSizeChange: { [weak chat] value in chat?.resetSizeShortcut = value; Shortcut.saveResetSize(value) },
                onMaximizeChange: { [weak chat] value in chat?.maximizeShortcut = value; Shortcut.saveMaximize(value) }, onClose: {})
        }
        DispatchQueue.main.async { chat.show() }
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(chat) { NSApplication.shared.run() }
    }
    #endif

    AppText.applyOwnLanguage()
    LegacyCleanup.run()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only (LSUIElement is also set in Info.plist)
    EditMenu.install()
    withExtendedLifetime(delegate) { app.run() }
}

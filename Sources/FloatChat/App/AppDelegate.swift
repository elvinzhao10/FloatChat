import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = FeatureManager()
    private var statusItem: NSStatusItem?
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("FloatChat launched")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.make()
        }
        let controller = MenuController(manager: manager)
        item.menu = controller.menu
        statusItem = item
        menuController = controller

        manager.start()
        (manager.features.first as? FloatChatFeature)?.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        (manager.features.first as? FloatChatFeature)?.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("FloatChat terminating; restoring ChatGPT state")
        manager.disableAll()
    }
}

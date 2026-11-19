import AppKit
#if FLOATCHAT_SPARKLE
import Sparkle
#endif

@MainActor
enum AppUpdates {
    #if FLOATCHAT_SPARKLE
    private static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    static func start() {
        #if FLOATCHAT_SPARKLE
        _ = controller
        #endif
    }

    static func check() {
        #if FLOATCHAT_SPARKLE
        controller.checkForUpdates(nil)
        #else
        NSWorkspace.shared.open(URL(string: "https://github.com/elvinzhao10/FloatChat/releases/latest")!)
        #endif
    }
}

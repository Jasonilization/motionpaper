import SwiftUI
import MotionpaperKit

@main
struct MotionpaperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Motionpaper") {
            RootView()
                .environment(appDelegate.store)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("Motionpaper launched")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Clicking the Dock icon always brings the library back up.
        if !hasVisibleWindows {
            for window in NSApp.windows where window.identifier?.rawValue == "main" {
                window.makeKeyAndOrderFront(self)
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.library.saveNow()
    }
}

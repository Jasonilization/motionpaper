import MotionpaperKit
import SwiftUI

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

        Settings {
            SettingsView()
                .environment(appDelegate.store)
                .preferredColorScheme(.dark)
        }
    }
}

/// Deliberately minimal on macOS 27.0 betas: Swift 6 injects
/// _checkExpectedExecutor into every @objc method on @MainActor classes,
/// and that check segfaults in the broken concurrency runtime on this build.
/// ALL app initialization work lives in RootView's .task modifier (SwiftUI
/// guarantees main-actor there without the broken executor check), and
/// reopen/terminate handling is left to SwiftUI's defaults + the launchd
/// keepalive agent.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()

    /// Closing the library window never quits the app — wallpapers keep running.
    /// nonisolated: no executor check injected; just returns a constant.
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

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
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Backup startup: if RootView's .task doesn't fire (happens on this
    /// macOS beta), this ensures the wallpaper engine starts. Swift 5 mode =
    /// no executor check injected = safe @objc method.
    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            // Only start if the engine truly hasn't started (displays empty
            // AND no wallpaper windows). The .task in RootView normally handles
            // this; we only intervene if it truly failed.
            let engineStarted = !self.store.engine.displays.isEmpty
            if !engineStarted {
                WallpaperEngine.appendOverlayLog("AppDelegate: .task failed — starting engine as backup")
                self.store.startEngine()
            } else {
                WallpaperEngine.appendOverlayLog("AppDelegate: engine already started via .task — skipping")
            }
        }
    }
}

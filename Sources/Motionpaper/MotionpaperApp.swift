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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppLog.app.info("Motionpaper launched")
        ClickCrashFix.install()
        // Patch the SwiftUI contentView's hitTest after the window exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            ClickCrashFix.patchContentViewHitTest()
            self?.store.startEngine()
        }
        store.menuBar.attach(store: store)
        ensureMainWindow()
    }

    /// Closing the library window never quits the app — wallpapers must keep running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The main library window if it currently exists (hidden or visible).
    private var mainLibraryWindow: NSWindow? {
        NSApp.windows.first { $0.title == "Motionpaper" && $0.canBecomeMain }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock click always brings the library back up — including restoring
        // it from the Dock (deminiaturize) and re-showing ordered-out windows.
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainLibraryWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(self)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.library.saveNow()
        store.settings.saveNow()
        // Fresh marker = clean quit; the keep-alive watchdog only relaunches
        // when this is absent (i.e., the process died from a crash).
        let marker = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Motionpaper/.clean-quit")
        FileManager.default.createFile(atPath: marker.path, contents: Data("quit\n".utf8))
    }

    // MARK: - Deterministic window recovery

    /// On some macOS beta builds, SwiftUI's WindowGroup occasionally creates its
    /// window but never presents it (born hidden), or doesn't create it at all
    /// (observed nondeterministically on macOS 27.0). This watchdog guarantees
    /// a usable library window: it force-presents a hidden one, and creates a
    /// hosted fallback window if none exists. "Start in background" suppresses
    /// the force-presentation (existence is still enforced).
    private func ensureMainWindow() {
        Task { [weak self] in
            let wantsBackgroundStart = self?.store.settings.values.startInBackground ?? false
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard let window = self.mainLibraryWindow else { continue }
                if window.isVisible && !window.isMiniaturized { return }
                if !wantsBackgroundStart {
                    AppLog.app.warning("Main window exists but hidden — forcing presentation")
                    if window.isMiniaturized {
                        window.deminiaturize(nil)
                    }
                    window.orderFrontRegardless()
                    window.makeKeyAndOrderFront(self)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            guard let self else { return }
            if self.mainLibraryWindow == nil {
                AppLog.app.warning("SwiftUI window missing after 12s — creating recovery window")
                self.presentRecoveryWindow()
            }
        }
    }

    private var recoveryWindow: NSWindow?

    private func presentRecoveryWindow() {
        guard recoveryWindow == nil else {
            recoveryWindow?.makeKeyAndOrderFront(self)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Motionpaper"
        window.identifier = NSUserInterfaceItemIdentifier("recovery-main")
        window.center()
        window.setFrameAutosaveName("MotionpaperLibraryWindow")

        let root = RootView()
            .environment(store)
            .preferredColorScheme(.dark)
        window.contentViewController = NSHostingController(rootView: root)
        window.makeKeyAndOrderFront(self)
        recoveryWindow = window
        AppLog.app.info("Recovery window presented")
    }
}

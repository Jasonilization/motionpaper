import AppKit
import Foundation
import MotionpaperKit

/// App-wide container wiring the library, importer, thumbnail pipeline,
/// wallpaper engine, power management, and the menu bar.
@MainActor @Observable
final class AppStore {
    var isCreatingCollectionFromCard = false
    let paths: AppPaths
    let library: LibraryStore
    let settings: SettingsStore
    let engine: WallpaperEngine
    let importer = ImportManager()
    let thumbnails: ThumbnailStore
    let power = PowerMonitor()
    let resource = ResourceController()
    let menuBar = MenuBarController()

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.thumbnails = ThumbnailStore(directory: paths.thumbnails)
        self.library = LibraryStore(paths: paths)
        self.settings = SettingsStore(fileURL: paths.settingsFile)
        self.engine = WallpaperEngine(library: library, settings: settings)
        self.library.revalidate()
    }

    /// Installs a user-level launchd agent that relaunches Motionpaper
    /// whenever it exits unsuccessfully (a crash) — the proper macOS watchdog
    /// mechanism. Clean quits exit 0 and are never restarted.
    private func updateKeepAliveAgent() {
        let label = "com.jasonilization.motionpaper.keepalive"
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let agentsDir = plist.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        guard settings.values.restartAfterCrashes else {
            // Off: unload + remove
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["unload", plist.path]
            try? unload.run(); unload.waitUntilExit()
            try? FileManager.default.removeItem(at: plist)
            return
        }

        let appBinary = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/Motionpaper")
        guard FileManager.default.fileExists(atPath: appBinary.path) else { return }
        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>\(appBinary.path)</string></array>
            <key>KeepAlive</key>
            <dict><key>SuccessfulExit</key><false/></dict>
            <key>RunAtLoad</key><false/>
            <key>ThrottleInterval</key><integer>3</integer>
        </dict>
        </plist>
        """
        do {
            try plistContent.write(to: plist, atomically: true, encoding: .utf8)
            let load = Process()
            load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            load.arguments = ["unload", plist.path]
            try? load.run(); load.waitUntilExit()
            let load2 = Process()
            load2.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            load2.arguments = ["load", plist.path]
            try load2.run(); load2.waitUntilExit()
        } catch {
            AppLog.app.warning("Keep-alive agent install failed: \(error.localizedDescription)")
        }
    }

    /// Starts wallpaper playback and power policy. Called from
    /// applicationDidFinishLaunching — after the (optional) background-start
    /// window hiding, so wallpaper windows are never hidden accidentally.
    func startEngine() {
        engine.start()
        resource.attach(engine: engine, settings: settings, power: power)
        engine.prepareLockScreenOverlayIfEnabled()
        power.onLockChange = { [weak self] locked in
            self?.engine.setOverlayWanted(locked)
            Self.toggleLibraryWindowAcrossLock(locked)
        }
        updateKeepAliveAgent()
    }

    /// Resolves the playable file URL for a wallpaper, if its backing file exists.
    func playableURL(for wallpaper: Wallpaper) -> URL? {
        guard library.fileExists(for: wallpaper) else { return nil }
        return library.fileURL(for: wallpaper)
    }

    /// macOS-beta workaround: system frameworks (SwiftUI responders,
    /// menu-bar client) perform synchronous MainActor executor checks that
    /// crash when a lock transition races them. Removing the library window's
    /// responder surface while locked eliminates the entire crash class;
    /// it's invisible to the user (they're looking at the Lock Screen).
    @MainActor private static var stashedContentViews: [Int: NSView] = [:]

    @MainActor private static func toggleLibraryWindowAcrossLock(_ locked: Bool) {
        for window in NSApp.windows where window.title == "Motionpaper" && window.canBecomeMain {
            let windowID = window.windowNumber
            if locked {
                // Detach the responder tree entirely: ordered-out windows keep
                // their NSView responders alive, and system hit-testing still
                // walks them at the lock instant (the beta's executor-check
                // crash). With no content view there is nothing to walk.
                if let content = window.contentView, stashedContentViews[windowID] == nil {
                    stashedContentViews[windowID] = content
                    window.contentView = nil
                }
                window.orderOut(nil)
            } else {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                if let content = stashedContentViews.removeValue(forKey: windowID) {
                    window.contentView = content
                }
            }
        }
    }

    // MARK: - Lock Screen bridging (Settings UI calls these)

    func matchLockScreenNow() {
        engine.matchLockScreenNow()
    }

    /// One-time setup: re-export the current frame to the stable Pictures file
    /// and open System Settings → Wallpaper for the single manual pick.
    func exportStableLockFrame() {
        engine.exportStableLockFrame()
    }

    func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: NSHomeDirectory() + "/Pictures")
    }

    func setLoginWindowPicture() async throws {
        try await engine.setLoginWindowPicture()
    }

    /// Advanced → Reset application data. Clears the managed library and all
    /// assignments. User preferences (settings.json) are kept. Original files
    /// that were imported from are never touched.
    func resetAllData() {
        for display in engine.displays {
            engine.clear(displayKey: display.id)
        }
        engine.clearAllAssignments()

        let fm = FileManager.default
        for dir in [paths.videos, paths.thumbnails] {
            if let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }
        try? fm.removeItem(at: paths.libraryFile)
        library.reset()
        AppLog.app.info("Application data reset")
    }
}

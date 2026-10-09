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

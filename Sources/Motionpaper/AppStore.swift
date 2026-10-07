import Foundation
import MotionpaperKit

/// App-wide container wiring the library, importer, thumbnail pipeline,
/// wallpaper engine, power management, and the menu bar.
@MainActor @Observable
final class AppStore {
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
    }

    /// Resolves the playable file URL for a wallpaper, if its backing file exists.
    func playableURL(for wallpaper: Wallpaper) -> URL? {
        guard library.fileExists(for: wallpaper) else { return nil }
        return library.fileURL(for: wallpaper)
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

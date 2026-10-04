import Foundation
import MotionpaperKit

/// App-wide container wiring the library, importer, thumbnail pipeline, and
/// the wallpaper engine.
@MainActor @Observable
final class AppStore {
    let paths: AppPaths
    let library: LibraryStore
    let settings: SettingsStore
    let engine: WallpaperEngine
    let importer = ImportManager()
    let thumbnails: ThumbnailStore

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.thumbnails = ThumbnailStore(directory: paths.thumbnails)
        self.library = LibraryStore(paths: paths)
        self.settings = SettingsStore(fileURL: paths.settingsFile)
        self.engine = WallpaperEngine(library: library, settings: settings)
        self.library.revalidate()
        self.engine.start()
    }

    /// Resolves the playable file URL for a wallpaper, if its backing file exists.
    func playableURL(for wallpaper: Wallpaper) -> URL? {
        guard library.fileExists(for: wallpaper) else { return nil }
        return library.fileURL(for: wallpaper)
    }
}

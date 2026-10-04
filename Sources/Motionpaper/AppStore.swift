import Foundation
import MotionpaperKit

/// App-wide container wiring the library, importer, and thumbnail pipeline.
@MainActor @Observable
final class AppStore {
    let paths: AppPaths
    let library: LibraryStore
    let importer = ImportManager()
    let thumbnails: ThumbnailStore

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        self.thumbnails = ThumbnailStore(directory: paths.thumbnails)
        self.library = LibraryStore(paths: paths)
        self.library.revalidate()
    }

    /// Resolves the playable file URL for a wallpaper, if its backing file exists.
    func playableURL(for wallpaper: Wallpaper) -> URL? {
        guard library.fileExists(for: wallpaper) else { return nil }
        return library.fileURL(for: wallpaper)
    }
}

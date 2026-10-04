import Foundation

/// Filesystem layout for Motionpaper's application-managed data.
///
/// Everything the app manages lives under one Application Support directory:
///
///     ~/Library/Application Support/Motionpaper/
///     ├── Videos/          managed (copied) wallpaper originals
///     ├── Thumbnails/      generated JPEG thumbnail cache
///     ├── Logs/            exported diagnostic logs
///     ├── library.json     wallpapers, collections, playlists, assignments
///     └── settings.json    user preferences
public struct AppPaths: Sendable {
    public let appSupport: URL

    public init(appSupport: URL) {
        self.appSupport = appSupport
        try? Self.ensureDirectory(appSupport)
        try? Self.ensureDirectory(self.videos)
        try? Self.ensureDirectory(self.thumbnails)
        try? Self.ensureDirectory(self.logs)
    }

    /// The default location: `~/Library/Application Support/Motionpaper`.
    public static func standard() -> AppPaths {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return AppPaths(appSupport: base.appendingPathComponent("Motionpaper", isDirectory: true))
    }

    public var videos: URL { appSupport.appendingPathComponent("Videos", isDirectory: true) }
    public var thumbnails: URL { appSupport.appendingPathComponent("Thumbnails", isDirectory: true) }
    public var logs: URL { appSupport.appendingPathComponent("Logs", isDirectory: true) }
    public var libraryFile: URL { appSupport.appendingPathComponent("library.json") }
    public var settingsFile: URL { appSupport.appendingPathComponent("settings.json") }

    public func videoURL(for fileName: String) -> URL {
        videos.appendingPathComponent(fileName, isDirectory: false)
    }

    public func thumbnailURL(for id: UUID) -> URL {
        thumbnails.appendingPathComponent("\(id.uuidString).jpg", isDirectory: false)
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

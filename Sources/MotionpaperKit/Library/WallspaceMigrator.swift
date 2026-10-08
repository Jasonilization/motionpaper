import AppKit
import Foundation

/// Discovers and imports wallpapers from a locally installed Wallspace app —
/// without touching Wallspace's own files.
///
/// Where Wallspace keeps its data (all read-only from Motionpaper's side):
/// - Videos:   `~/Library/Caches/Wallspace/Wallpapers/{numericKey}.mp4`
/// - Posters:  `~/Library/Caches/Wallspace/images/posters/{numericKey}.webp`
/// - Metadata: `~/Library/Preferences/wallspace.app.plist`
///   (`likedWallpapersModels`, `recentsWallpapersModels`, `savedWallpaperKey`,
///    `savedPerMonitorWallpapers` — plist-encoded JSON blobs keyed by
///    Wallspace's numeric wallpaper keys)
///
/// Migration copies the video files into Motionpaper's managed library,
/// reuses Wallspace's poster as the first thumbnail, and carries over titles,
/// categories (as tags), favorites, and recently-used state. Wallspace's own
/// installation is never modified.
public final class WallspaceMigrator {
    // MARK: - Discovery models

    /// A subset of Wallspace's own wallpaper model (tolerant decoding).
    public struct WallspaceModel: Codable, Sendable {
        public var key: Int64?
        public var title: String?
        public var category: String?
        public var resolution: String?
        public var duration: String?
        public var likes: Int?
        public var isFavorite: Bool?

        enum CodingKeys: String, CodingKey {
            case key, title, category, resolution, duration, likes
            case isFavorite = "liked"
        }

        public init(key: Int64? = nil, title: String? = nil, category: String? = nil,
                    resolution: String? = nil, duration: String? = nil,
                    likes: Int? = nil, isFavorite: Bool? = nil) {
            self.key = key
            self.title = title
            self.category = category
            self.resolution = resolution
            self.duration = duration
            self.likes = likes
            self.isFavorite = isFavorite
        }
    }

    /// One discovered item and what migration will do with it.
    public struct DiscoveredItem: Identifiable, Sendable, Equatable {
        public let id = UUID()
        public let fileURL: URL
        public let wallspaceKey: Int64
        public let title: String?
        public let category: String?
        public var isFavorite: Bool
        public var wasRecentlyUsed: Bool
        /// nil until import decides; UI reads it after scanning.
        public var status: ImportStatus = .new

        public enum ImportStatus: Sendable, Equatable {
            case new
            case alreadyImported
            case imported
            case unsupported(String)
        }
    }

    public struct ScanReport: Sendable, Equatable {
        public var items: [DiscoveredItem]
        public var missingMetadataCount: Int

        public var newCount: Int { items.filter { $0.status == .new }.count }
        public var alreadyImportedCount: Int { items.filter { $0.status == .alreadyImported }.count }
        public var unsupportedCount: Int { items.filter { if case .unsupported = $0.status { return true }; return false }.count }
    }

    // MARK: - Locations

    /// Paths are injectable for tests; `default()` probes the real locations
    /// discovered on this machine. Nothing is assumed to exist.
    public let videosDirectory: URL?
    public let postersDirectory: URL?
    public let likedModels: [WallspaceModel]
    public let recentModels: [WallspaceModel]

    /// Catalog titles recovered from Wallspace's cached API responses
    /// (api_cache.json) — used as a fallback when the preferences plist is gone.
    public let catalogTitles: [Int64: String]

    public init(videosDirectory: URL?, postersDirectory: URL?,
                likedModels: [WallspaceModel], recentModels: [WallspaceModel],
                catalogTitles: [Int64: String] = [:]) {
        self.videosDirectory = videosDirectory
        self.postersDirectory = postersDirectory
        self.likedModels = likedModels
        self.recentModels = recentModels
        self.catalogTitles = catalogTitles
    }

    /// The real Wallspace data on this machine, if present.
    public static func defaultMigrator() -> WallspaceMigrator {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let caches = home.appendingPathComponent("Library/Caches/Wallspace", isDirectory: true)
        let posters = caches.appendingPathComponent("images/posters", isDirectory: true)
        let videos = caches.appendingPathComponent("Wallpapers", isDirectory: true)

        let (liked, recent) = readWallspacePreferences()
        let hasData = FileManager.default.fileExists(atPath: videos.path)
            || FileManager.default.fileExists(atPath: caches.path)
        let catalog = readCatalogTitles(
            at: caches.appendingPathComponent("api_cache.json", isDirectory: false)
        )
        return WallspaceMigrator(
            videosDirectory: hasData ? videos : nil,
            postersDirectory: hasData ? posters : nil,
            likedModels: liked,
            recentModels: recent,
            catalogTitles: catalog
        )
    }

    /// Wallspace caches its API responses (base64-encoded JSON) in
    /// api_cache.json. Walk them for {key, title} catalog entries — a metadata
    /// fallback when the preferences plist is missing. Read-only, offline.
    static func readCatalogTitles(at url: URL) -> [Int64: String] {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var titles: [Int64: String] = [:]
        for (_, value) in cache {
            guard let entry = value as? [String: Any],
                  let payload = entry["data"] as? String,
                  let decoded = Data(base64Encoded: payload),
                  let json = try? JSONSerialization.jsonObject(with: decoded) else {
                continue
            }
            walkForTitles(json, into: &titles)
        }
        return titles
    }

    private static func walkForTitles(_ node: Any, into titles: inout [Int64: String]) {
        if let dict = node as? [String: Any] {
            if let key = dict["key"] as? Int64, let title = dict["title"] as? String {
                titles[key] = title
            } else if let key = dict["key"] as? Int, let title = dict["title"] as? String {
                titles[Int64(key)] = title
            }
            for value in dict.values {
                walkForTitles(value, into: &titles)
            }
        } else if let array = node as? [Any] {
            for item in array {
                walkForTitles(item, into: &titles)
            }
        }
    }

    /// Reads Wallspace's preference JSON blobs (read-only; never written back).
    static func readWallspacePreferences() -> (liked: [WallspaceModel], recent: [WallspaceModel]) {
        let plistPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/wallspace.app.plist")
        guard let data = try? Data(contentsOf: plistPath),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return ([], [])
        }

        func decode(_ key: String) -> [WallspaceModel] {
            guard let blob = plist[key] as? Data,
                  let models = try? JSONDecoder().decode([WallspaceModel].self, from: blob) else {
                return []
            }
            return models
        }
        return (decode("likedWallpapersModels"), decode("recentsWallpapersModels"))
    }

    // MARK: - Scanning

    /// Scans the discovered storage and matches videos against Wallspace's
    /// metadata + Motionpaper's existing library. Probes each new file so the
    /// reported "unsupported" count is accurate before anything is imported.
    @MainActor
    public func scan(library: LibraryStore) async -> ScanReport {
        guard let videosDirectory,
              FileManager.default.fileExists(atPath: videosDirectory.path) else {
            return ScanReport(items: [], missingMetadataCount: 0)
        }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: videosDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { MetadataExtractor.isLikelyVideoFile(url: $0) } ?? []

        let likedByKey = Dictionary(uniqueKeysWithValues: likedModels.compactMap { model in
            model.key.map { ($0, model) }
        })
        let recentKeys = Set(recentModels.compactMap(\.key))

        var items: [DiscoveredItem] = []
        var missingMetadata = 0

        for file in files {
            let key = Int64(file.deletingPathExtension().lastPathComponent) ?? -1
            guard key > 0 else { continue }
            let model = likedByKey[key] ?? recentModels.first { $0.key == key }
            if model == nil && catalogTitles[key] == nil { missingMetadata += 1 }

            var item = DiscoveredItem(
                fileURL: file,
                wallspaceKey: key,
                title: model?.title,
                category: model?.category,
                isFavorite: model != nil && likedByKey[key] != nil,
                wasRecentlyUsed: recentKeys.contains(key)
            )

            // Duplicate detection: hash-based.
            if let hash = try? FileHasher.sha256(url: file) {
                if library.wallpapers.contains(where: { $0.contentHash == hash }) {
                    item.status = .alreadyImported
                }
            }

            // Probe new files so unsupported ones are reported up front.
            if item.status == .new {
                do {
                    _ = try await MetadataExtractor.probe(url: file)
                } catch let error as MetadataExtractor.ProbeError {
                    item.status = .unsupported(error.description)
                } catch {
                    item.status = .unsupported(error.localizedDescription)
                }
            }
            items.append(item)
        }

        items.sort { $0.wallspaceKey < $1.wallspaceKey }
        return ScanReport(items: items, missingMetadataCount: missingMetadata)
    }

    // MARK: - Import

    /// Imports all `.new` items. Existing items are left alone; Wallspace's
    /// files are only ever read. Returns (imported, skipped) counts.
    @MainActor
    public func importItems(_ items: [DiscoveredItem], into library: LibraryStore,
                             importer: ImportManager) async -> (imported: Int, skipped: Int) {
        var imported = 0
        var skipped = 0
        for item in items where item.status == .new || item.status == .imported {
            guard item.status == .new else { skipped += 1; continue }
            do {
                let wallpaper = try await importOne(item, into: library)
                imported += 1
                _ = wallpaper
            } catch {
                skipped += 1
                AppLog.migration.warning("Skipped \(item.fileURL.lastPathComponent, privacy: .public): \(error)")
            }
        }
        // Batch imports flush to disk immediately — no debounce.
        library.saveNow()
        AppLog.migration.info("Wallspace migration: \(imported) imported, \(skipped) skipped")
        return (imported, skipped)
    }

    @MainActor
    private func importOne(_ item: DiscoveredItem, into library: LibraryStore) async throws -> Wallpaper {
        // Content hash + duplicate guard.
        let hash = try FileHasher.sha256(url: item.fileURL)
        if library.wallpapers.contains(where: { $0.contentHash == hash }) {
            throw CocoaError(.fileWriteFileExists)
        }

        // Probe with AVFoundation (authoritative format/codec check).
        let metadata: VideoMetadata
        do {
            metadata = try await MetadataExtractor.probe(url: item.fileURL)
        } catch let error as MetadataExtractor.ProbeError {
            throw error
        }

        let id = UUID()
        let fileName = "\(id.uuidString).mp4"
        let destination = library.storagePaths.videoURL(for: fileName)
        try FileManager.default.copyItem(at: item.fileURL, to: destination)

        let fallbackName = "Wallspace \(item.wallspaceKey)"
        let wallpaper = Wallpaper(
            id: id,
            name: item.title ?? catalogTitles[item.wallspaceKey] ?? fallbackName,
            fileName: fileName,
            isManaged: true,
            origin: .wallspaceMigration,
            isFavorite: item.isFavorite,
            tags: item.category.map { [$0] } ?? [],
            metadata: metadata,
            contentHash: hash,
            originalLocation: item.fileURL.path
        )
        library.add(wallpaper)
        if item.wasRecentlyUsed {
            library.markUsed(id: id)
        }

        // Reuse Wallspace's poster as the first thumbnail when available.
        if let postersDirectory {
            let posterURL = postersDirectory.appendingPathComponent("\(item.wallspaceKey).webp")
            if FileManager.default.fileExists(atPath: posterURL.path),
               let image = NSImage(contentsOf: posterURL),
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                try? jpeg.write(to: library.storagePaths.thumbnailURL(for: id), options: .atomic)
            }
        }
        return wallpaper
    }
}


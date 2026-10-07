import Foundation
import Observation

/// Main-actor state + persistence for the wallpaper library.
///
/// All UI-facing state lives on the main actor; disk I/O is dispatched off it.
/// `library.json` writes are debounced and atomic (tmp file + rename), and a
/// corrupt store file is backed up rather than crashing the app.
@MainActor @Observable
public final class LibraryStore {
    public private(set) var wallpapers: [Wallpaper] = []
    public private(set) var collections: [WallpaperCollection] = []
    public private(set) var playlists: [Playlist] = []
    public private(set) var assignments: [DisplayAssignment] = []
    public private(set) var recents: [UUID] = []

    @ObservationIgnored private let paths: AppPaths
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored public let isLoadedFromCorruptFile: Bool

    public init(paths: AppPaths) {
        let (snapshot, corrupt) = Self.loadFromDisk(paths.libraryFile)
        self.paths = paths
        self.isLoadedFromCorruptFile = corrupt
        if let snapshot {
            apply(snapshot: snapshot)
        }
        AppLog.library.info("Library loaded: \(self.wallpapers.count) wallpapers")
    }

    nonisolated private static func loadFromDisk(_ url: URL) -> (snapshot: LibrarySnapshot?, corrupt: Bool) {
        do {
            return (try loadSnapshot(from: url), false)
        } catch CocoaError.fileReadNoSuchFile {
            // First launch: nothing to load.
            return (nil, false)
        } catch {
            AppLog.library.error("library.json unreadable (\(error)): starting fresh, backing up the old file")
            backupCorruptFile(at: url)
            return (nil, true)
        }
    }

    // MARK: - Lookup helpers

    public func wallpaper(id: UUID) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    public func wallpapers(ids: [UUID]) -> [Wallpaper] {
        let set = Set(ids)
        return wallpapers.filter { set.contains($0.id) }
    }

    public func wallpaper(named name: String) -> Wallpaper? {
        wallpapers.first { $0.name == name }
    }

    public func collection(id: UUID) -> WallpaperCollection? {
        collections.first { $0.id == id }
    }

    public func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    public func assignment(displayKey: String) -> DisplayAssignment? {
        assignments.first { $0.displayKey == displayKey }
    }

    /// File URL the player should open — managed files resolve inside `Videos/`,
    /// referenced ones to their original location.
    public func fileURL(for wallpaper: Wallpaper) -> URL? {
        if wallpaper.isManaged, let fileName = wallpaper.fileName {
            return paths.videoURL(for: fileName)
        }
        if let path = wallpaper.referencedPath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public func fileExists(for wallpaper: Wallpaper) -> Bool {
        guard let url = fileURL(for: wallpaper) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public var recentWallpapers: [Wallpaper] {
        recents.compactMap { id in wallpapers.first { $0.id == id } }
    }

    public var favoriteWallpapers: [Wallpaper] {
        wallpapers.filter(\.isFavorite)
    }

    public var importedWallpapers: [Wallpaper] {
        wallpapers.filter { $0.origin == .imported || $0.origin == .folderImport }
    }

    // MARK: - Mutations

    public func add(_ wallpaper: Wallpaper) {
        wallpapers.append(wallpaper)
        scheduleSave()
    }

    public func add(_ wallpapersToAdd: [Wallpaper]) {
        wallpapers.append(contentsOf: wallpapersToAdd)
        scheduleSave()
    }

    public func update(_ wallpaper: Wallpaper) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == wallpaper.id }) else { return }
        wallpapers[idx] = wallpaper
        scheduleSave()
    }

    public func toggleFavorite(id: UUID) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[idx].isFavorite.toggle()
        scheduleSave()
    }

    public func rename(id: UUID, to name: String) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        wallpapers[idx].name = trimmed
        scheduleSave()
    }

    public func setTags(id: UUID, tags: [String]) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        wallpapers[idx].tags = tags
        scheduleSave()
    }

    public func markUsed(id: UUID) {
        if let idx = wallpapers.firstIndex(where: { $0.id == id }) {
            wallpapers[idx].lastUsedAt = Date()
        }
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        if recents.count > 20 {
            recents.removeLast(recents.count - 20)
        }
        scheduleSave()
    }

    public func setStatus(id: UUID, status: Wallpaper.Status) {
        guard let idx = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        guard wallpapers[idx].status != status else { return }
        wallpapers[idx].status = status
        scheduleSave()
    }

    /// Removes an item from the library. Managed files and thumbnails are deleted;
    /// referenced originals are always left untouched.
    public func remove(id: UUID, deleteManagedFile: Bool) {
        let wallpaper = wallpapers.first { $0.id == id }
        wallpapers.removeAll { $0.id == id }
        recents.removeAll { $0 == id }
        collections = collections.map {
            var c = $0
            c.wallpaperIDs.removeAll { $0 == id }
            return c
        }
        playlists = playlists.map {
            var p = $0
            p.wallpaperIDs.removeAll { $0 == id }
            return p
        }
        for idx in assignments.indices where assignments[idx].wallpaperID == id {
            assignments[idx].wallpaperID = nil
        }
        scheduleSave()

        guard let wallpaper else { return }
        if deleteManagedFile, wallpaper.isManaged, let fileName = wallpaper.fileName {
            let url = paths.videoURL(for: fileName)
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.removeItem(at: paths.thumbnailURL(for: wallpaper.id))
    }

    // MARK: - Collections / playlists / assignments

    public func createCollection(name: String) -> WallpaperCollection {
        let collection = WallpaperCollection(name: name)
        collections.append(collection)
        scheduleSave()
        return collection
    }

    public func renameCollection(id: UUID, to name: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = name
        scheduleSave()
    }

    public func deleteCollection(id: UUID) {
        collections.removeAll { $0.id == id }
        scheduleSave()
    }

    public func addToCollection(wallpaperID: UUID, collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        if !collections[idx].wallpaperIDs.contains(wallpaperID) {
            collections[idx].wallpaperIDs.append(wallpaperID)
            scheduleSave()
        }
    }

    public func removeFromCollection(wallpaperID: UUID, collectionID: UUID) {
        guard let idx = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[idx].wallpaperIDs.removeAll { $0 == wallpaperID }
        scheduleSave()
    }

    public func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        scheduleSave()
        return playlist
    }

    public func update(_ playlist: Playlist) {
        guard let idx = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[idx] = playlist
        scheduleSave()
    }

    public func deletePlaylist(id: UUID) {
        playlists.removeAll { $0.id == id }
        for idx in assignments.indices where assignments[idx].playlistID == id {
            assignments[idx].playlistID = nil
        }
        scheduleSave()
    }

    public func setAssignment(_ assignment: DisplayAssignment) {
        if let idx = assignments.firstIndex(where: { $0.displayKey == assignment.displayKey }) {
            assignments[idx] = assignment
        } else {
            assignments.append(assignment)
        }
        scheduleSave()
    }

    public func clearAssignments() {
        assignments.removeAll()
        scheduleSave()
    }

    // MARK: - Revalidation (launch indexing)

    /// Rechecks every item's backing file. Missing/corrupt items are flagged
    /// instead of crashing; statuses are persisted.
    public func revalidate() {
        var changed = false
        for idx in wallpapers.indices {
            let item = wallpapers[idx]
            guard item.status != .unsupported else { continue }
            let newStatus: Wallpaper.Status
            if !fileExists(for: item) {
                newStatus = .missing
            } else {
                newStatus = .ok
            }
            if newStatus != item.status {
                wallpapers[idx].status = newStatus
                changed = true
                if newStatus == .missing {
                    AppLog.library.warning("Wallpaper file missing: \(item.name, privacy: .public)")
                }
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Storage

    public var storagePaths: AppPaths { paths }

    private func snapshot() -> LibrarySnapshot {
        LibrarySnapshot(
            wallpapers: wallpapers,
            collections: collections,
            playlists: playlists,
            assignments: assignments,
            recents: recents
        )
    }

    /// Debounced: coalesces bursts of mutations into one disk write.
    public func scheduleSave() {
        saveTask?.cancel()
        let snapshot = snapshot()
        let url = paths.libraryFile
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            Self.write(snapshot: snapshot, to: url)
        }
    }

    /// Writes immediately (e.g. on quit). Cancels any pending debounced save.
    /// The JSON payload is small, so a synchronous write here is fine.
    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        Self.write(snapshot: snapshot(), to: paths.libraryFile)
    }

    // MARK: - Static I/O helpers (nonisolated so they run off the main actor)

    nonisolated static func loadSnapshot(from url: URL) throws -> LibrarySnapshot {
        let data = try Data(contentsOf: url)
        return try Self.decoder().decode(LibrarySnapshot.self, from: data)
    }

    nonisolated static func write(snapshot: LibrarySnapshot, to url: URL) {
        do {
            let data = try Self.encoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            AppLog.library.error("Failed to write library.json: \(error)")
        }
    }

    nonisolated static func backupCorruptFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("library.corrupt-\(stamp).json")
        try? FileManager.default.moveItem(at: url, to: backup)
    }

    nonisolated static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    nonisolated static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    internal func apply(snapshot: LibrarySnapshot) {
        wallpapers = snapshot.wallpapers
        collections = snapshot.collections
        playlists = snapshot.playlists
        assignments = snapshot.assignments
        recents = snapshot.recents
    }

    /// Clears every library entry and writes an empty store (advanced reset).
    public func reset() {
        apply(snapshot: LibrarySnapshot())
        saveNow()
    }
}

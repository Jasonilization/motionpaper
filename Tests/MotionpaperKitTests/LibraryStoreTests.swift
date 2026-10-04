import Foundation
import Testing
@testable import MotionpaperKit

@MainActor
struct LibraryStoreTests {
    @Test func saveLoadRoundtrip() async throws {
        let paths = AppPaths(appSupport: TestVideoFactory.tempDirectory())
        let store = LibraryStore(paths: paths)

        var wallpaper = Wallpaper(
            name: "Test",
            fileName: "x.mp4",
            isManaged: true,
            origin: .imported,
            metadata: VideoMetadata(width: 1920, height: 1080, duration: 12, fps: 30, fileSizeBytes: 1000, codec: "H.264", container: "MP4")
        )
        wallpaper.contentHash = "abc"
        store.add(wallpaper)
        store.toggleFavorite(id: wallpaper.id)
        store.markUsed(id: wallpaper.id)
        let playlist = store.createPlaylist(name: "Night")
        store.update(Playlist(id: playlist.id, name: "Night", wallpaperIDs: [wallpaper.id], order: .random, changeInterval: 300, isEnabled: true))
        store.setAssignment(DisplayAssignment(displayKey: "Built-in_2560x1664", wallpaperID: wallpaper.id))
        store.saveNow()
        try await Task.sleep(for: .milliseconds(100))

        // A second store instance sees the same data.
        let reloaded = LibraryStore(paths: paths)
        #expect(reloaded.wallpapers.count == 1)
        #expect(reloaded.wallpapers.first?.name == "Test")
        #expect(reloaded.wallpapers.first?.isFavorite == true)
        #expect(reloaded.recents == [wallpaper.id])
        #expect(reloaded.playlists.first?.wallpaperIDs == [wallpaper.id])
        #expect(reloaded.assignments.first?.wallpaperID == wallpaper.id)
        #expect(reloaded.wallpapers.first?.metadata.width == 1920)
    }

    @Test func removalDeletesManagedFileAndThumbnail() throws {
        let paths = AppPaths(appSupport: TestVideoFactory.tempDirectory())
        let store = LibraryStore(paths: paths)

        let videoURL = try TestVideoFactory.makeVideo(at: paths.videos.appendingPathComponent("managed.mp4"))
        let wallpaper = Wallpaper(name: "Managed", fileName: videoURL.lastPathComponent, isManaged: true, origin: .imported, metadata: VideoMetadata())
        store.add(wallpaper)

        let thumbnailFile = paths.thumbnailURL(for: wallpaper.id)
        try Data([0xFF]).write(to: thumbnailFile)

        store.remove(id: wallpaper.id, deleteManagedFile: true)

        #expect(store.wallpapers.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: videoURL.path))
        #expect(!FileManager.default.fileExists(atPath: thumbnailFile.path))
    }

    @Test func corruptLibraryFileIsBackedUp() throws {
        let dir = TestVideoFactory.tempDirectory()
        let paths = AppPaths(appSupport: dir)
        try Data("this is not json".utf8).write(to: paths.libraryFile)

        let store = LibraryStore(paths: paths)
        #expect(store.isLoadedFromCorruptFile)
        #expect(store.wallpapers.isEmpty)

        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("library.corrupt-") }
        #expect(backups.count == 1)
    }

    @Test func revalidateFlagsMissingFiles() throws {
        let dir = TestVideoFactory.tempDirectory()
        let paths = AppPaths(appSupport: dir)
        let store = LibraryStore(paths: paths)

        let existing = Wallpaper(name: "Exists", fileName: "exists.mp4", isManaged: true, origin: .imported, metadata: VideoMetadata())
        let missing = Wallpaper(name: "Gone", fileName: "gone.mp4", isManaged: true, origin: .imported, metadata: VideoMetadata())
        try TestVideoFactory.makeVideo(at: paths.videoURL(for: existing.fileName ?? ""))
        store.add([existing, missing])

        store.revalidate()

        #expect(store.wallpaper(id: existing.id)?.status == .ok)
        #expect(store.wallpaper(id: missing.id)?.status == .missing)
    }
}

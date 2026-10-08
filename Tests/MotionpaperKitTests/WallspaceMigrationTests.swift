import Foundation
import Testing
@testable import MotionpaperKit

@MainActor
struct WallspaceMigrationTests {
    /// Builds a synthetic Wallspace store in a temp directory and verifies the
    /// full scan → import → rescan cycle, including favorites/tags carry-over
    /// and skipped unsupported files.
    @Test func scanImportRescan() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let videosDir = dir.appendingPathComponent("Wallpapers", isDirectory: true)
        let postersDir = dir.appendingPathComponent("posters", isDirectory: true)
        try FileManager.default.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: postersDir, withIntermediateDirectories: true)

        // Two real videos + one junk file.
        try TestVideoFactory.makeVideo(at: videosDir.appendingPathComponent("111.mp4"), duration: 1)
        try TestVideoFactory.makeVideo(at: videosDir.appendingPathComponent("222.mp4"), duration: 1)
        try Data(repeating: 0x00, count: 2048).write(to: videosDir.appendingPathComponent("333.mp4"))

        let liked = [
            WallspaceMigrator.WallspaceModel(key: 111, title: "Mystery Shack", category: "Nature", isFavorite: true),
        ]
        let recents = [
            WallspaceMigrator.WallspaceModel(key: 111, title: "Mystery Shack", category: "Nature"),
        ]

        let migrator = WallspaceMigrator(
            videosDirectory: videosDir,
            postersDirectory: postersDir,
            likedModels: liked,
            recentModels: recents
        )
        let store = LibraryStore(paths: AppPaths(appSupport: dir.appendingPathComponent("support")))

        // Scan: 3 files found; junk probed unsupported; 2 playable new.
        let report = await migrator.scan(library: store)
        #expect(report.items.count == 3)
        #expect(report.newCount == 2)
        #expect(report.unsupportedCount == 1)
        #expect(report.items.first { $0.wallspaceKey == 111 }?.isFavorite == true)

        // Import: both playable files succeed. The unsupported file was already
        // reported by the scan and is never attempted.
        let outcome = await migrator.importItems(report.items, into: store, importer: ImportManager())
        #expect(outcome.imported == 2)
        #expect(outcome.skipped == 0)

        // Titles, favorites, tags, and recents carried over.
        let migrated = store.wallpapers.first { $0.name == "Mystery Shack" }
        #expect(migrated != nil)
        #expect(migrated?.isFavorite == true)
        #expect(migrated?.tags == ["Nature"])
        #expect(migrated?.origin == .wallspaceMigration)
        #expect(store.recents.contains(migrated!.id))
        #expect(migrated?.metadata.codec == "H.264")

        // Managed copy exists in our library.
        #expect(FileManager.default.fileExists(atPath: store.storagePaths.videoURL(for: migrated!.fileName ?? "").path))

        // Wallspace's originals untouched.
        #expect(FileManager.default.fileExists(atPath: videosDir.appendingPathComponent("111.mp4").path))

        // Re-scan: nothing new (the unsupported file stays reported as unsupported).
        let report2 = await migrator.scan(library: store)
        #expect(report2.newCount == 0)
        #expect(report2.alreadyImportedCount == 2)
    }

    /// No Wallspace data → empty report, never a crash.
    @Test func missingStoreYieldsEmptyReport() async {
        let migrator = WallspaceMigrator(
            videosDirectory: nil,
            postersDirectory: nil,
            likedModels: [],
            recentModels: []
        )
        let store = LibraryStore(paths: AppPaths(appSupport: TestVideoFactory.tempDirectory()))
        let report = await migrator.scan(library: store)
        #expect(report.items.isEmpty)
    }
}

import Foundation
import Testing
@testable import MotionpaperKit

@MainActor
struct ImportManagerTests {
    @Test func importCopyDedupesAndReferences() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let source = try TestVideoFactory.makeVideo(at: dir.appendingPathComponent("source.mp4"), duration: 1)
        let paths = AppPaths(appSupport: dir.appendingPathComponent("support"))
        let store = LibraryStore(paths: paths)
        let manager = ImportManager()

        // Copy import.
        await manager.importFiles([source], into: store, mode: .copy)
        #expect(manager.outcomes.count == 1)
        guard case .imported = manager.outcomes[0].result else {
            Issue.record("expected imported, got \(manager.outcomes)")
            return
        }
        #expect(store.wallpapers.count == 1)
        let imported = try #require(store.wallpapers.first)
        #expect(imported.isManaged)
        #expect(imported.contentHash?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: paths.videoURL(for: imported.fileName ?? "").path))
        #expect(imported.metadata.codec == "H.264")

        // Same file again → duplicate outcome, no new entry.
        await manager.importFiles([source], into: store, mode: .copy)
        #expect(store.wallpapers.count == 1)
        guard case .duplicate = manager.outcomes.last?.result else {
            Issue.record("expected duplicate, got \(manager.outcomes)")
            return
        }

        // A distinct file imported in reference mode keeps its path.
        let source2 = try TestVideoFactory.makeVideo(at: dir.appendingPathComponent("source2.mp4"), duration: 1)
        await manager.importFiles([source2], into: store, mode: .reference)
        #expect(store.wallpapers.count == 2)
        let referenced = try #require(store.wallpapers.last)
        #expect(!referenced.isManaged)
        #expect(referenced.referencedPath == source2.path)
    }

    @Test func importUnsupportedFileReportsReason() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let fake = dir.appendingPathComponent("fake.mp4")
        try Data(repeating: 0x00, count: 4096).write(to: fake)
        let paths = AppPaths(appSupport: dir.appendingPathComponent("support"))
        let store = LibraryStore(paths: paths)
        let manager = ImportManager()

        await manager.importFiles([fake], into: store, mode: .copy)
        #expect(store.wallpapers.isEmpty)
        guard case .unsupported = manager.outcomes.first?.result else {
            Issue.record("expected unsupported, got \(manager.outcomes)")
            return
        }
    }

    @Test func importNonVideoExtension() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let text = dir.appendingPathComponent("readme.txt")
        try Data("hello".utf8).write(to: text)
        let paths = AppPaths(appSupport: dir.appendingPathComponent("support"))
        let store = LibraryStore(paths: paths)
        let manager = ImportManager()

        await manager.importFiles([text], into: store, mode: .copy)
        #expect(store.wallpapers.isEmpty)
        guard case .unsupported = manager.outcomes.first?.result else {
            Issue.record("expected unsupported, got \(manager.outcomes)")
            return
        }
    }

    @Test func folderDiscoveryFindsNestedVideos() throws {
        let dir = TestVideoFactory.tempDirectory()
        let nested = dir.appendingPathComponent("nested/deeper", isDirectory: true)
        try TestVideoFactory.makeVideo(at: nested.appendingPathComponent("a.mp4"), duration: 1)
        try TestVideoFactory.makeVideo(at: nested.appendingPathComponent("b.MOV"), duration: 1)
        try Data("x".utf8).write(to: nested.appendingPathComponent("ignore.txt"))
        try Data("x".utf8).write(to: nested.appendingPathComponent("ignore.jpg"))

        let found = ImportManager.discoverVideos(in: dir)
        #expect(found.count == 2)
        #expect(found.allSatisfy { MetadataExtractor.isLikelyVideoFile(url: $0) })
    }
}

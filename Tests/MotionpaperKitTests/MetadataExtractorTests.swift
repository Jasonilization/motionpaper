import Foundation
import Testing
@testable import MotionpaperKit

struct MetadataExtractorTests {
    @Test func probeGeneratedVideo() async throws {
        let url = try TestVideoFactory.makeVideo(at: TestVideoFactory.tempDirectory().appendingPathComponent("probe.mp4"), duration: 2)
        let metadata = try await MetadataExtractor.probe(url: url)

        #expect(metadata.width == 320)
        #expect(metadata.height == 240)
        #expect((metadata.duration ?? 0) > 1.5)
        #expect((metadata.duration ?? 99) < 3)
        #expect((metadata.fps ?? 0) > 20)
        #expect(metadata.codec == "H.264")
        #expect(metadata.container == "MP4")
        #expect((metadata.fileSizeBytes ?? 0) > 0)
    }

    @Test func probeRejectsNonVideo() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let url = dir.appendingPathComponent("fake.mp4")
        try Data(repeating: 0x41, count: 1024).write(to: url)
        await #expect(throws: MetadataExtractor.ProbeError.self) {
            _ = try await MetadataExtractor.probe(url: url)
        }
    }

    @Test func likelyVideoFileDetection() {
        #expect(MetadataExtractor.isLikelyVideoFile(url: URL(fileURLWithPath: "/tmp/a/movie.mp4")))
        #expect(MetadataExtractor.isLikelyVideoFile(url: URL(fileURLWithPath: "/tmp/a/movie.MOV")))
        #expect(!MetadataExtractor.isLikelyVideoFile(url: URL(fileURLWithPath: "/tmp/a/photo.jpg")))
        #expect(!MetadataExtractor.isLikelyVideoFile(url: URL(fileURLWithPath: "/tmp/a/notes.txt")))
    }
}

struct ThumbnailStoreTests {
    @Test func generationAndCaching() async throws {
        let dir = TestVideoFactory.tempDirectory()
        let paths = AppPaths(appSupport: dir)
        let url = try TestVideoFactory.makeVideo(at: dir.appendingPathComponent("thumb.mp4"), duration: 2)
        let metadata = try await MetadataExtractor.probe(url: url)
        let wallpaper = Wallpaper(name: "Thumb", fileName: url.lastPathComponent, isManaged: true, origin: .imported, metadata: metadata)

        let store = ThumbnailStore(directory: paths.thumbnails)
        let data = await store.thumbnail(for: wallpaper, sourceURL: url)
        #expect(data != nil)
        #expect((data?.count ?? 0) > 500) // real JPEG, not a stub

        // Cache file exists; a second request hits the cache (still returns data).
        let second = await store.thumbnail(for: wallpaper, sourceURL: url)
        #expect(second == data)

        let cleared = await store.clearAll()
        #expect(cleared == 1)
        #expect(store.cacheSizeBytes() == 0)
    }
}

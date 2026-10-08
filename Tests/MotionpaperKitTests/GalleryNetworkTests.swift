import Foundation
import Testing
@testable import MotionpaperKit

/// Live network tests for the opt-in gallery. Skipped unless
/// MOTIONPAPER_GALLERY_NET=1 — the default test run stays offline.
/// (This machine is online; run explicitly to verify the API integrations.)
struct GalleryNetworkTests {
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["MOTIONPAPER_GALLERY_NET"] == "1"

    @Test(.enabled(if: isEnabled))
    func nasaSearchAndDownload() async throws {
        let gallery = GalleryService()
        let items = try await gallery.search(source: .nasa, query: "earth")
        #expect(!items.isEmpty)
        #expect(items.allSatisfy { $0.source == .nasa })
        print("NASA results:", items.count, "— first:", items[0].title)

        let file = try await gallery.download(items[0])
        defer { try? FileManager.default.removeItem(at: file) }
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        print("downloaded \(size) bytes to", file.lastPathComponent)
        #expect(size > 10_000)
        #expect(MetadataExtractor.isLikelyVideoFile(url: file))
    }

    @Test(.enabled(if: isEnabled))
    func nasaNoResultsThrowsCleanly() async {
        let gallery = GalleryService()
        await #expect(throws: GalleryService.GalleryError.self) {
            _ = try await gallery.search(source: .nasa, query: "qqqqzzzzqqqq")
        }
    }

    @Test(.enabled(if: isEnabled))
    func missingKeyThrows() async {
        let gallery = GalleryService()
        await #expect(throws: GalleryService.GalleryError.missingAPIKey) {
            _ = try await gallery.search(source: .pixabay, query: "forest")
        }
        await #expect(throws: GalleryService.GalleryError.missingAPIKey) {
            _ = try await gallery.search(source: .pexels, query: "forest")
        }
    }
}

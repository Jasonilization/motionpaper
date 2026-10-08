import AppKit
import Foundation
import Testing
@testable import MotionpaperKit

struct WallpaperDecodingTests {
    /// Library files written before the sprite-sheet feature must keep loading.
    @Test func decodesLegacyJSONWithoutKindOrSprite() throws {
        let legacy = """
        {
          "id": "7F3A9C2E-1B44-4D1B-9E7A-0A2B3C4D5E6F",
          "name": "Old Video",
          "fileName": "7F3A9C2E-1B44-4D1B-9E7A-0A2B3C4D5E6F.mp4",
          "isManaged": true,
          "origin": "imported",
          "addedAt": "2026-10-01T12:00:00.000Z",
          "isFavorite": true,
          "tags": [],
          "metadata": {"width": 1920, "height": 1080, "duration": 12.0, "fps": 30.0,
                        "fileSizeBytes": 1000000, "codec": "H.264", "container": "MP4"},
          "status": "ok"
        }
        """
        let decoder = LibraryStore.decoder()
        let wallpaper = try decoder.decode(Wallpaper.self, from: Data(legacy.utf8))
        #expect(wallpaper.kind == .video)
        #expect(wallpaper.sprite == nil)
        #expect(wallpaper.isFavorite)
        #expect(wallpaper.metadata.width == 1920)
    }

    @Test func spriteSheetRoundTrip() throws {
        let wallpaper = Wallpaper(
            name: "Sans",
            fileName: "sans.png",
            isManaged: true,
            origin: .imported,
            addedAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .spriteSheet,
            sprite: Wallpaper.SpriteMetadata(columns: 6, rows: 2, framesPerSecond: 10)
        )
        let data = try LibraryStore.encoder().encode(wallpaper)
        let decoded = try LibraryStore.decoder().decode(Wallpaper.self, from: data)
        #expect(decoded == wallpaper)
        #expect(decoded.sprite?.totalFrames == 12)
    }

    @Test func dayCycleMath() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let playlist = Playlist(
            name: "Cycle",
            wallpaperIDs: [a, b, c],
            order: .sequential,
            changeInterval: 0,
            isEnabled: true,
            mode: .dayCycle
        )

        var calendar = Calendar.current
        calendar.timeZone = .current
        let base = calendar.startOfDay(for: Date())

        // 3 equal 8-hour segments.
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base) == a)
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base.addingTimeInterval(7 * 3600)) == a)
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base.addingTimeInterval(8 * 3600)) == b)
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base.addingTimeInterval(15 * 3600 + 59 * 60)) == b)
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base.addingTimeInterval(16 * 3600)) == c)
        #expect(PlaylistAdvancer.dayCycleWallpaper(in: playlist, at: base.addingTimeInterval(86_399)) == c)

        // Boundaries land exactly on segment edges.
        let boundary = PlaylistAdvancer.nextDayCycleBoundary(after: base.addingTimeInterval(3600), count: 3)
        #expect(boundary == base.addingTimeInterval(8 * 3600))

        // Segment labels: equal split of three.
        #expect(PlaylistAdvancer.dayCycleSegmentLabel(count: 3, index: 0) == "00:00 – 08:00")
        #expect(PlaylistAdvancer.dayCycleSegmentLabel(count: 3, index: 1) == "08:00 – 16:00")
        #expect(PlaylistAdvancer.dayCycleSegmentLabel(count: 3, index: 2) == "16:00 – 24:00")
    }

    @Test func spriteSheetSlicing() async throws {
        // Build a 4×1 sheet programmatically: 4 frames of 16×16 px.
        let width = 64, height = 16
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<width {
            for y in 0..<height {
                rep.setColor(NSColor(calibratedRed: Double(x) / Double(width), green: 0, blue: 0, alpha: 1),
                             atX: x, y: y)
            }
        }
        let cg = rep.cgImage!
        let frames = try SpriteSheetRenderer.slice(image: cg, columns: 4, rows: 1)
        #expect(frames.count == 4)
        #expect(frames[0].width == 16)
        #expect(frames[0].height == 16)

        // Bad grid → thrown error, never a crash.
        await #expect(throws: SpriteSheetRenderer.SliceError.frameGridTooSmall) {
            _ = try SpriteSheetRenderer.slice(image: cg, columns: 0, rows: 1)
        }
    }
}

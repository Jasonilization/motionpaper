import AppKit
import AVFoundation
import Foundation

/// Generates and caches JPEG thumbnails.
///
/// - One representative frame per video (seeks near the 10% mark with a wide
///   tolerance so the decoder doesn't do a precise, expensive seek).
/// - Cached on disk keyed by wallpaper UUID; generation is de-duplicated.
/// - All work runs off the main actor.
public actor ThumbnailStore {
    private let directory: URL
    private var inFlight: [UUID: Task<Data?, Never>] = [:]
    static let maxDimension: CGFloat = 640

    public init(directory: URL) {
        self.directory = directory
    }

    /// Returns cached JPEG bytes, generating them on first request.
    public func thumbnail(for wallpaper: Wallpaper, sourceURL: URL) async -> Data? {
        let cacheURL = directory.appendingPathComponent("\(wallpaper.id.uuidString).jpg")

        if let cached = try? Data(contentsOf: cacheURL), !cached.isEmpty {
            return cached
        }
        if let existing = inFlight[wallpaper.id] {
            return await existing.value
        }

        let task = Task<Data?, Never> {
            let data: Data?
            if wallpaper.kind == .spriteSheet, let sprite = wallpaper.sprite {
                data = (try? await SpriteSheetRenderer.firstFramePNG(at: sourceURL, sprite: sprite)) ?? nil
            } else {
                data = await Self.generate(sourceURL: sourceURL, duration: wallpaper.metadata.duration)
            }
            if let data {
                try? data.write(to: cacheURL, options: .atomic)
            }
            return data
        }
        inFlight[wallpaper.id] = task
        let result = await task.value
        inFlight[wallpaper.id] = nil
        return result
    }

    /// Drops the cached file for one wallpaper (e.g. after removal from the library).
    public func invalidate(id: UUID) {
        let cacheURL = directory.appendingPathComponent("\(id.uuidString).jpg")
        try? FileManager.default.removeItem(at: cacheURL)
    }

    /// Deletes every cached thumbnail. Returns the number of deleted files.
    @discardableResult
    public func clearAll() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return 0 }
        var count = 0
        for file in files where file.pathExtension.lowercased() == "jpg" {
            try? fm.removeItem(at: file)
            count += 1
        }
        return count
    }

    /// Total bytes used by the thumbnail cache.
    public nonisolated func cacheSizeBytes() -> Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { sum, url in
            sum + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    static func generate(sourceURL: URL, duration: Double?) async -> Data? {
        let asset = AVURLAsset(url: sourceURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxDimension, height: maxDimension)
        // Wide tolerance: a representative frame, not a precise one — much cheaper.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 3, preferredTimescale: 600)

        let seekSeconds: Double
        if let duration, duration.isFinite, duration > 0 {
            seekSeconds = min(duration * 0.1, 10)
        } else {
            seekSeconds = 0
        }
        let requested = CMTime(seconds: seekSeconds, preferredTimescale: 600)

        do {
            let (image, _) = try await generator.image(at: requested)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
        } catch {
            AppLog.library.warning("Thumbnail generation failed for \(sourceURL.lastPathComponent, privacy: .public): \(error)")
            return nil
        }
    }
}

import AppKit
import AVFoundation
import Foundation

/// Exports a high-quality poster frame (PNG) from a wallpaper video.
///
/// This powers the honest Lock Screen story: macOS lets third-party apps do
/// nothing on the Lock Screen itself, but a poster frame exported here can be
/// set as the system Lock Screen wallpaper in System Settings, giving a
/// visually continuous lock experience (static while locked).
public enum PosterFrameExporter {
    public enum ExportError: Error, CustomStringConvertible {
        case fileMissing
        case decodeFailed(String)

        public var description: String {
            switch self {
            case .fileMissing: "The wallpaper file is missing."
            case .decodeFailed(let reason): "Couldn't export a frame: \(reason)"
            }
        }
    }

    /// Exports a frame at the video's native resolution (capped at 4K).
    public static func export(sourceURL: URL, to destination: URL) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw ExportError.fileMissing
        }

        let asset = AVURLAsset(url: sourceURL)
        let (duration, playable) = try await asset.load(.duration, .isPlayable)
        guard playable else { throw ExportError.decodeFailed("Video not playable") }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 3840, height: 3840)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)

        let seconds: Double
        if duration.seconds.isFinite, duration.seconds > 0 {
            seconds = min(duration.seconds * 0.1, 10)
        } else {
            seconds = 0
        }

        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.decodeFailed("PNG encoding failed")
        }
        try png.write(to: destination, options: .atomic)
    }
}

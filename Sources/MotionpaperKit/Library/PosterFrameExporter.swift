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

    /// Exports a representative frame at the video's native resolution
    /// (capped at 4K). Samples five moments across the video and keeps the
    /// brightest one, so wallpapers that fade in from black still produce a
    /// visible lock-screen frame.
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
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let totalSeconds = duration.seconds.isFinite ? duration.seconds : 0
        let candidates: [Double] = totalSeconds > 0
            ? [0.10, 0.25, 0.40, 0.60, 0.85].map { totalSeconds * $0 }
            : [0]

        var bestImage: CGImage?
        var bestLuminance = -1.0
        for seconds in candidates {
            guard let (image, _) = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
                continue
            }
            let luminance = Self.meanLuminance(of: image)
            if luminance > bestLuminance {
                bestLuminance = luminance
                bestImage = image
            }
        }
        guard let image = bestImage else {
            throw ExportError.decodeFailed("No decodable frame found")
        }

        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw ExportError.decodeFailed("PNG encoding failed")
        }
        try png.write(to: destination, options: .atomic)
    }

    /// Cheap mean-luminance: downsample into a 16×16 grayscale context.
    static func meanLuminance(of image: CGImage) -> Double {
        let width = 16, height = 16
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return 0 }
        let pixelCount = width * height
        let pixels = data.bindMemory(to: UInt8.self, capacity: pixelCount)
        var total = 0
        for i in 0..<pixelCount {
            total += Int(pixels[i])
        }
        return Double(total) / Double(pixelCount)
    }
}

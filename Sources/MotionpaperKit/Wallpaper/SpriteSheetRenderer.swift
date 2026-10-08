import AppKit
import CoreGraphics
import Foundation

/// Slices sprite-sheet PNGs into animation frames and builds looping
/// Core Animation playback — GPU-composited, zero per-frame CPU work.
public enum SpriteSheetRenderer {
    public enum SliceError: Error, CustomStringConvertible {
        case imageUnreadable
        case frameGridTooSmall

        public var description: String {
            switch self {
            case .imageUnreadable: "The image couldn't be read."
            case .frameGridTooSmall: "The grid doesn't fit the image dimensions."
            }
        }
    }

    /// Crops the sheet into individual frames, left-to-right, top-to-bottom.
    public static func slice(image: CGImage, columns: Int, rows: Int) throws -> [CGImage] {
        guard columns > 0, rows > 0 else { throw SliceError.frameGridTooSmall }
        let frameWidth = image.width / columns
        let frameHeight = image.height / rows
        guard frameWidth > 0, frameHeight > 0 else { throw SliceError.frameGridTooSmall }

        var frames: [CGImage] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let rect = CGRect(
                    x: column * frameWidth,
                    y: (rows - 1 - row) * frameHeight, // CG origin is bottom-left
                    width: frameWidth,
                    height: frameHeight
                )
                if let frame = image.cropping(to: rect) {
                    frames.append(frame)
                }
            }
        }
        guard !frames.isEmpty else { throw SliceError.imageUnreadable }
        return frames
    }

    /// Loads a sheet's CGImage from disk.
    public static func loadImage(at url: URL) throws -> CGImage {
        guard let nsImage = NSImage(contentsOf: url),
              let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw SliceError.imageUnreadable
        }
        return cg
    }

    /// Builds an infinitely-looping keyframe animation over `layer.contents`.
    /// Returns the animation so the caller can add/remove it from the layer.
    public static func loopingAnimation(frames: [CGImage], framesPerSecond: Double) -> CAKeyframeAnimation? {
        guard !frames.isEmpty, framesPerSecond > 0 else { return nil }
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames
        animation.duration = Double(frames.count) / framesPerSecond
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        return animation
    }

    /// A representative first frame — used as the thumbnail.
    public static func firstFramePNG(at url: URL, sprite: Wallpaper.SpriteMetadata) async throws -> Data? {
        let image = try loadImage(at: url)
        let frames = try slice(image: image, columns: sprite.columns, rows: sprite.rows)
        guard let frame = frames.first else { return nil }
        let rep = NSBitmapImageRep(cgImage: frame)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    }
}

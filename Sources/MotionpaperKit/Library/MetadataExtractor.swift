import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Extracts video metadata with AVFoundation without decoding the whole file.
public enum MetadataExtractor {
    public enum ProbeError: Error, Equatable, Sendable, CustomStringConvertible {
        case noVideoTrack
        case notPlayable
        case unreadableFile

        public var description: String {
            switch self {
            case .noVideoTrack: "No video track found"
            case .notPlayable: "Codec or container not supported by macOS"
            case .unreadableFile: "File could not be read"
            }
        }
    }

    /// Extensions AVFoundation can typically play on macOS. Used as a fast filter
    /// before the real AVAsset probe; the probe is authoritative.
    public static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mpeg", "mpg", "mts"]

    public static func isLikelyVideoFile(url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension) {
            return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
        }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Probes a video file and returns its metadata. Throws `ProbeError` with a
    /// user-presentable reason when the file isn't a playable video.
    public static func probe(url: URL) async throws -> VideoMetadata {
        let asset = AVURLAsset(url: url)

        let playable: Bool
        let duration: CMTime
        do {
            playable = try await asset.load(.isPlayable)
            duration = try await asset.load(.duration)
        } catch {
            throw ProbeError.unreadableFile
        }

        guard playable else { throw ProbeError.notPlayable }

        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ProbeError.noVideoTrack
        }
        guard let track = videoTracks.first else { throw ProbeError.noVideoTrack }

        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let transformed = naturalSize.applying(preferredTransform)
        let width = Int(abs(transformed.width.rounded()))
        let height = Int(abs(transformed.height.rounded()))
        let fpsValue = Double(nominalFrameRate)
        let fps = fpsValue > 0 ? (fpsValue * 10).rounded() / 10 : nil

        let seconds = duration.seconds
        let durationValue = (seconds.isFinite && seconds > 0) ? (seconds * 100).rounded() / 100 : nil

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
        let container = url.pathExtension.isEmpty ? nil : url.pathExtension.uppercased()
        let codec = codecLabel(from: formatDescriptions)

        return VideoMetadata(
            width: width > 0 ? width : nil,
            height: height > 0 ? height : nil,
            duration: durationValue,
            fps: fps,
            fileSizeBytes: fileSize,
            codec: codec,
            container: container
        )
    }

    /// Maps the first video track's CMFormatDescription fourCC to a friendly codec label.
    static func codecLabel(from descriptions: [Any]) -> String? {
        guard let first = descriptions.first else { return nil }
        // AVAssetTrack.formatDescriptions is [Any], but its elements are always CMFormatDescription.
        let formatDesc = first as! CMFormatDescription
        let fourCC = CMFormatDescriptionGetMediaSubType(formatDesc)
        var chars: [UInt8] = []
        for shift in [UInt32(24), UInt32(16), UInt32(8), UInt32(0)] {
            let byte = UInt8((fourCC >> shift) & 0xFF)
            if byte == 0 { break }
            chars.append(byte)
        }
        let raw = String(bytes: chars, encoding: .ascii) ?? ""
        switch raw {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        case "ap4h", "ap4c", "apcn", "apch", "apcs", "apco": return "ProRes"
        case "vp09", "vp08": return "VP9"
        case "av01": return "AV1"
        case "dvh ", "dvhe", "dvh1": return "Dolby Vision"
        default: return raw.isEmpty ? nil : raw
        }
    }
}

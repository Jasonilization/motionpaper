import Foundation

// MARK: - Video metadata

/// Technical metadata extracted with AVFoundation at import time.
public struct VideoMetadata: Codable, Hashable, Sendable {
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var fps: Double?
    public var fileSizeBytes: Int?
    public var codec: String?
    public var container: String?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        fps: Double? = nil,
        fileSizeBytes: Int? = nil,
        codec: String? = nil,
        container: String? = nil
    ) {
        self.width = width
        self.height = height
        self.duration = duration
        self.fps = fps
        self.fileSizeBytes = fileSizeBytes
        self.codec = codec
        self.container = container
    }

    public var resolutionLabel: String {
        guard let width, let height else { return "—" }
        return "\(width)×\(height)"
    }

    public var durationLabel: String {
        guard let duration, duration.isFinite, duration > 0 else { return "—" }
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        if m > 0 { return String(format: "%d:%02d", m, s) }
        return "\(s)s"
    }

    public var aspectRatioLabel: String {
        guard let width, let height, width > 0, height > 0 else { return "—" }
        let ratio = Double(width) / Double(height)
        if abs(ratio - 16.0 / 9.0) < 0.02 { return "16:9" }
        if abs(ratio - 16.0 / 10.0) < 0.02 { return "16:10" }
        if abs(ratio - 4.0 / 3.0) < 0.02 { return "4:3" }
        if abs(ratio - 3.0 / 2.0) < 0.02 { return "3:2" }
        return String(format: "%.2f:1", ratio)
    }

    public var orientation: WallpaperOrientation {
        guard let width, let height, width > 0, height > 0 else { return .unknown }
        if width > height { return .landscape }
        if height > width { return .portrait }
        return .square
    }

    /// Shortest edge height, used for the 1080p/1440p/4K smart filters.
    public var shortEdge: Int {
        min(width ?? 0, height ?? 0)
    }

    public var is4KOrBetter: Bool { shortEdge >= 2160 }
    public var is1440pOrBetter: Bool { shortEdge >= 1440 }
    public var is1080pOrBetter: Bool { shortEdge >= 1080 }
}

public enum WallpaperOrientation: String, Codable, Sendable {
    case landscape
    case portrait
    case square
    case unknown
}

// MARK: - Wallpaper

/// The core library item. Identity is a stable UUID — filenames may change,
/// but the ID (and everything keyed on it: favorites, playlists, assignments)
/// persists for the life of the item.
public struct Wallpaper: Codable, Hashable, Identifiable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case missing
        case corrupt
        case unsupported

        public var label: String {
            switch self {
            case .ok: "OK"
            case .missing: "File missing"
            case .corrupt: "Unreadable"
            case .unsupported: "Unsupported"
            }
        }
    }

    public enum Origin: String, Codable, Sendable {
        case imported
        case folderImport
        case wallspaceMigration
    }

    public var id: UUID
    public var name: String
    /// File name inside the managed `Videos/` directory (when `isManaged`).
    public var fileName: String?
    /// Absolute path of the original file (when referenced in place).
    public var referencedPath: String?
    public var isManaged: Bool
    public var origin: Origin
    public var addedAt: Date
    public var lastUsedAt: Date?
    public var isFavorite: Bool
    public var tags: [String]
    public var metadata: VideoMetadata
    public var status: Status
    /// SHA-256 of the file content; used to avoid duplicate imports.
    public var contentHash: String?
    /// Where the file came from (provenance; used by migration UI).
    public var originalLocation: String?

    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String? = nil,
        referencedPath: String? = nil,
        isManaged: Bool,
        origin: Origin,
        addedAt: Date = Date(),
        lastUsedAt: Date? = nil,
        isFavorite: Bool = false,
        tags: [String] = [],
        metadata: VideoMetadata = VideoMetadata(),
        status: Status = .ok,
        contentHash: String? = nil,
        originalLocation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.referencedPath = referencedPath
        self.isManaged = isManaged
        self.origin = origin
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.isFavorite = isFavorite
        self.tags = tags
        self.metadata = metadata
        self.status = status
        self.contentHash = contentHash
        self.originalLocation = originalLocation
    }

    public var displayName: String { name }
}

// MARK: - Scaling

public enum ScalingMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case fill
    case fit
    case stretch

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .fill: "Fill"
        case .fit: "Fit"
        case .stretch: "Stretch"
        }
    }

    public var explanation: String {
        switch self {
        case .fill: "Fill the display, cropping edges if aspect ratios differ."
        case .fit: "Fit inside the display, letterboxing if needed. Never crops."
        case .stretch: "Stretch to the display exactly. Distorts when aspect ratios differ."
        }
    }
}

// MARK: - Library snapshot

/// Everything persisted in `library.json`.
public struct LibrarySnapshot: Codable, Sendable {
    public var version: Int
    public var wallpapers: [Wallpaper]
    public var collections: [WallpaperCollection]
    public var playlists: [Playlist]
    public var assignments: [DisplayAssignment]
    public var recents: [UUID]

    public init(
        version: Int = 1,
        wallpapers: [Wallpaper] = [],
        collections: [WallpaperCollection] = [],
        playlists: [Playlist] = [],
        assignments: [DisplayAssignment] = [],
        recents: [UUID] = []
    ) {
        self.version = version
        self.wallpapers = wallpapers
        self.collections = collections
        self.playlists = playlists
        self.assignments = assignments
        self.recents = recents
    }

    public static let currentVersion = 1
}

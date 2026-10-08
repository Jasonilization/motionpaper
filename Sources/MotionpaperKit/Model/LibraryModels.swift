import Foundation

// MARK: - Collections

/// A user-created, metadata-only collection (videos are never duplicated).
public struct WallpaperCollection: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var wallpaperIDs: [UUID]
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, wallpaperIDs: [UUID] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.createdAt = createdAt
    }
}

// MARK: - Playlists

public enum PlayOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case sequential
    case random

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .sequential: "Sequential"
        case .random: "Random"
        }
    }
}

public enum PlaylistMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Change every N minutes/hours.
    case interval
    /// Equal segments across the day: each wallpaper gets the same share of 24 h
    /// (e.g. day / midday / night for a 3-item playlist — 8 h each).
    case dayCycle

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .interval: "Every N minutes"
        case .dayCycle: "Day cycle (equal times)"
        }
    }
}

/// An auto-change playlist. Assigned to a display, optionally on a schedule.
public struct Playlist: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var wallpaperIDs: [UUID]
    public var order: PlayOrder
    /// Seconds between changes. Zero means "manual only".
    public var changeInterval: TimeInterval
    public var isEnabled: Bool
    /// nil (or .interval) keeps classic behavior; .dayCycle splits 24 h equally.
    public var mode: PlaylistMode?

    public init(
        id: UUID = UUID(),
        name: String,
        wallpaperIDs: [UUID] = [],
        order: PlayOrder = .sequential,
        changeInterval: TimeInterval = 0,
        isEnabled: Bool = true,
        mode: PlaylistMode? = nil
    ) {
        self.id = id
        self.name = name
        self.wallpaperIDs = wallpaperIDs
        self.order = order
        self.changeInterval = changeInterval
        self.isEnabled = isEnabled
        self.mode = mode
    }
}

// MARK: - Display assignments

/// Persisted per-display wallpaper configuration. Uses a stable composite key
/// (display name + native resolution) rather than the volatile screen number,
/// so assignments survive reconnection and app restarts.
public struct DisplayAssignment: Codable, Hashable, Identifiable, Sendable {
    public var id: String { displayKey }

    public var displayKey: String
    public var wallpaperID: UUID?
    public var playlistID: UUID?
    public var scaling: ScalingMode
    public var isMuted: Bool
    public var volume: Double

    public init(
        displayKey: String,
        wallpaperID: UUID? = nil,
        playlistID: UUID? = nil,
        scaling: ScalingMode = .fill,
        isMuted: Bool = true,
        volume: Double = 0.0
    ) {
        self.displayKey = displayKey
        self.wallpaperID = wallpaperID
        self.playlistID = playlistID
        self.scaling = scaling
        self.isMuted = isMuted
        self.volume = volume
    }
}

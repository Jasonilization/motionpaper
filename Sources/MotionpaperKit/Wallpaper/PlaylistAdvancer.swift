import Foundation

/// Auto-change logic for a playlist assigned to a display.
///
/// Sequential mode advances through the playlist in order (skipping missing
/// items); random picks a different entry each time. The engine owns the Task
/// lifecycle; this type only computes what to play next, which keeps the
/// behavior unit-testable without real timers.
public enum PlaylistAdvancer {
    /// Returns the next wallpaper ID to apply for a display.
    ///
    /// - Parameters:
    ///   - playlist: the assigned playlist (order + content).
    ///   - currentID: the wallpaper currently shown on the display, if any.
    public static func nextWallpaper(in playlist: Playlist, after currentID: UUID?) -> UUID? {
        let ids = playlist.wallpaperIDs
        guard !ids.isEmpty else { return nil }

        switch playlist.order {
        case .random:
            let pool = ids.filter { $0 != currentID }
            if pool.isEmpty { return ids.first }
            return pool.randomElement()

        case .sequential:
            guard let currentID, let index = ids.firstIndex(of: currentID) else {
                return ids.first
            }
            let next = ids.index(after: index)
            return next == ids.endIndex ? ids.first : ids[next]
        }
    }

    /// Returns the previous wallpaper ID (menu bar "Previous Wallpaper").
    public static func previousWallpaper(in playlist: Playlist, before currentID: UUID?) -> UUID? {
        let ids = playlist.wallpaperIDs
        guard !ids.isEmpty else { return nil }
        switch playlist.order {
        case .random:
            return nextWallpaper(in: playlist, after: currentID)
        case .sequential:
            guard let currentID, let index = ids.firstIndex(of: currentID) else {
                return ids.last
            }
            return index == ids.startIndex ? ids.last : ids[ids.index(before: index)]
        }
    }

    /// Time interval suggestions exposed by the UI (minutes → hours).
    public static let intervalChoices: [TimeInterval] = [
        5 * 60, 10 * 60, 15 * 60, 30 * 60,
        60 * 60, 2 * 60 * 60, 6 * 60 * 60, 12 * 60 * 60, 24 * 60 * 60,
    ]

    public static func intervalLabel(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) m"
    }
}

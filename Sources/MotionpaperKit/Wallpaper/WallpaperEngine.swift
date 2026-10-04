import AppKit
import AVFoundation
import Foundation
import Observation

/// Owns the desktop-level wallpaper windows and orchestrates playback per display.
///
/// - One `WallpaperWindowController` (independent AVQueuePlayer + looper) per display.
/// - Assignments persist in the library; display reconnections restore them.
/// - Screen changes, display sleep/wake, and system sleep/wake are handled here;
///   power-mode policy (battery, low power, lock) is layered on in later phases.
@MainActor @Observable
public final class WallpaperEngine {
    public private(set) var displays: [DisplayInfo] = []
    public private(set) var states: [String: WallpaperWindowController.PlaybackState] = [:]
    public private(set) var currentWallpaperIDs: [String: UUID] = [:]
    /// True when the user explicitly paused playback (menu bar / UI toggle).
    public private(set) var userPaused = false

    public let library: LibraryStore
    public let settings: SettingsStore

    @ObservationIgnored private var windows: [String: WallpaperWindowController] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Auto-change tasks per display key (playlist scheduling).
    @ObservationIgnored private var schedulers: [String: Task<Void, Never>] = [:]
    /// Multi-line diagnostics for the Settings → Diagnostics page.
    @ObservationIgnored public private(set) var rendererEvents: [String] = []

    public init(library: LibraryStore, settings: SettingsStore) {
        self.library = library
        self.settings = settings
    }

    public func start() {
        AppLog.renderer.info("Engine starting")
        record("Engine starting")
        displays = DisplayInfo.currentScreens()

        // Screen topology changed (connect/disconnect/resolution/scale).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshDisplays(reason: "screen parameters changed") }
        })

        // Display sleep/wake — pause decoding while the display is dark.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSystemPaused(true, reason: "display sleep") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSystemPaused(false, reason: "display wake") }
        })

        // System sleep/wake.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSystemPaused(true, reason: "system sleep") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setSystemPaused(false, reason: "system wake") }
        })

        restoreAllAssignments()
    }

    // MARK: - Apply / clear

    /// Applies a wallpaper to one display and persists the assignment.
    public func apply(wallpaperID: UUID, toDisplay displayKey: String) {
        guard let wallpaper = library.wallpaper(id: wallpaperID) else { return }
        guard let url = library.fileURL(for: wallpaper) else {
            states[displayKey] = .failed("File is missing — re-import or locate it.")
            return
        }
        guard let display = displays.first(where: { $0.id == displayKey }) else { return }

        // Applying a single wallpaper ends any playlist auto-change on this display.
        if let assignment = library.assignment(displayKey: displayKey), assignment.playlistID != nil {
            cancelScheduler(displayKey: displayKey)
        }
        var assignment = library.assignment(displayKey: displayKey) ?? DisplayAssignment(displayKey: displayKey)
        assignment.wallpaperID = wallpaperID
        assignment.playlistID = nil
        assignment.scaling = assignment.wallpaperID == nil ? settings.values.defaultScaling : assignment.scaling
        library.setAssignment(assignment)
        library.markUsed(id: wallpaperID)

        play(url: url, wallpaper: wallpaper, display: display, assignment: assignment)
        AppLog.renderer.info("Applied wallpaper \(wallpaper.name, privacy: .public) to \(displayKey, privacy: .public)")
        record("Applied “\(wallpaper.name)” to \(display.name)")
    }

    // MARK: - Playlist scheduling

    /// Assigns a playlist to a display: shows its first (or random) wallpaper
    /// immediately and starts the auto-change loop.
    public func assign(playlistID: UUID, toDisplay displayKey: String) {
        guard let playlist = library.playlist(id: playlistID),
              playlist.isEnabled,
              !playlist.wallpaperIDs.isEmpty else { return }

        var assignment = library.assignment(displayKey: displayKey) ?? DisplayAssignment(displayKey: displayKey)
        assignment.playlistID = playlistID
        library.setAssignment(assignment)

        if let next = PlaylistAdvancer.nextWallpaper(in: playlist, after: assignment.wallpaperID),
           next != assignment.wallpaperID {
            applyPlaylistItem(next, toDisplay: displayKey, keepingPlaylist: playlistID)
        } else if let current = assignment.wallpaperID {
            // Re-show the current one so the display isn't left empty.
            applyPlaylistItem(current, toDisplay: displayKey, keepingPlaylist: playlistID)
        }
        startScheduler(displayKey: displayKey)
    }

    /// Applies one playlist entry without clearing the playlist assignment.
    private func applyPlaylistItem(_ wallpaperID: UUID, toDisplay displayKey: String, keepingPlaylist playlistID: UUID) {
        guard let wallpaper = library.wallpaper(id: wallpaperID),
              let url = library.fileURL(for: wallpaper),
              let display = displays.first(where: { $0.id == displayKey }) else { return }

        var assignment = library.assignment(displayKey: displayKey) ?? DisplayAssignment(displayKey: displayKey)
        assignment.wallpaperID = wallpaperID
        assignment.playlistID = playlistID
        library.setAssignment(assignment)
        library.markUsed(id: wallpaperID)
        play(url: url, wallpaper: wallpaper, display: display, assignment: assignment)
        record("Auto-changed to “\(wallpaper.name)” on \(display.name)")
    }

    /// Starts (or restarts) the auto-change loop for a display that has an
    /// enabled playlist assignment.
    public func startScheduler(displayKey: String) {
        cancelScheduler(displayKey: displayKey)
        guard let assignment = library.assignment(displayKey: displayKey),
              let playlistID = assignment.playlistID,
              let playlist = library.playlist(id: playlistID),
              playlist.isEnabled,
              playlist.changeInterval > 0,
              displays.contains(where: { $0.id == displayKey }) else { return }

        let key = displayKey
        schedulers[key] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(playlist.changeInterval))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Re-read the playlist: it may have been edited since.
                guard let current = self.library.assignment(displayKey: key),
                      let currentPlaylistID = current.playlistID,
                      currentPlaylistID == playlistID,
                      let livePlaylist = self.library.playlist(id: currentPlaylistID),
                      livePlaylist.isEnabled,
                      let next = PlaylistAdvancer.nextWallpaper(in: livePlaylist, after: current.wallpaperID)
                else { return }
                self.applyPlaylistItem(next, toDisplay: key, keepingPlaylist: currentPlaylistID)
            }
        }
        record("Playlist “\(playlist.name)” auto-change every \(PlaylistAdvancer.intervalLabel(playlist.changeInterval)) on \(displayKey)")
    }

    /// Restarts schedulers on displays assigned to a playlist (after playlist edits).
    public func refreshSchedules(for playlistID: UUID) {
        for assignment in library.assignments where assignment.playlistID == playlistID {
            if let playlist = library.playlist(id: playlistID), !playlist.isEnabled {
                cancelScheduler(displayKey: assignment.displayKey)
            } else {
                startScheduler(displayKey: assignment.displayKey)
            }
        }
    }

    private func cancelScheduler(displayKey: String) {
        schedulers[displayKey]?.cancel()
        schedulers[displayKey] = nil
    }

    /// The live player for a display — used by the preview to avoid decoding
    /// the same video twice when it's already the active wallpaper.
    public func activePlayer(forDisplay displayKey: String) -> AVPlayer? {
        windows[displayKey]?.sharedPlayer
    }

    public func applyToAllDisplays(wallpaperID: UUID) {
        for display in displays {
            apply(wallpaperID: wallpaperID, toDisplay: display.id)
        }
    }

    /// Removes the wallpaper from a display but keeps the (now empty) assignment.
    public func clear(displayKey: String) {
        cancelScheduler(displayKey: displayKey)
        windows[displayKey]?.close()
        windows[displayKey] = nil
        currentWallpaperIDs[displayKey] = nil
        states[displayKey] = nil
        if var assignment = library.assignment(displayKey: displayKey) {
            assignment.wallpaperID = nil
            assignment.playlistID = nil
            library.setAssignment(assignment)
        }
        record("Cleared wallpaper on \(displayKey)")
    }

    /// Clears every display assignment (diagnostics/troubleshooting action).
    public func clearAllAssignments() {
        for key in windows.keys { clear(displayKey: key) }
        library.clearAssignments()
        record("Reset all display assignments")
    }

    /// Re-applies the currently assigned wallpaper on a display (retry after failure).
    public func reapply(displayKey: String) {
        guard let assignment = library.assignment(displayKey: displayKey),
              let wallpaperID = assignment.wallpaperID else { return }
        apply(wallpaperID: wallpaperID, toDisplay: displayKey)
    }

    /// Tears down and recreates every wallpaper surface (diagnostics action).
    public func recreateAllSurfaces() {
        let keys = Array(windows.keys)
        for key in keys {
            windows[key]?.close()
            windows[key] = nil
        }
        displays = DisplayInfo.currentScreens()
        restoreAllAssignments()
        record("Recreated all wallpaper surfaces")
    }

    // MARK: - Playback control

    public func toggleUserPause() {
        setUserPaused(!userPaused)
    }

    public func setUserPaused(_ paused: Bool) {
        userPaused = paused
        for window in windows.values {
            if paused { window.pause() } else { window.resume() }
        }
        record(paused ? "Paused by user" : "Resumed by user")
    }

    public func pauseAll() { setUserPaused(true) }
    public func resumeAll() { setUserPaused(false) }

    public func applyPlaybackSettings(displayKey: String) {
        guard let assignment = library.assignment(displayKey: displayKey) else { return }
        windows[displayKey]?.apply(
            scaling: assignment.scaling,
            muted: assignment.isMuted,
            volume: assignment.volume
        )
    }

    public func setScaling(displayKey: String, scaling: ScalingMode) {
        guard var assignment = library.assignment(displayKey: displayKey) else { return }
        assignment.scaling = scaling
        library.setAssignment(assignment)
        applyPlaybackSettings(displayKey: displayKey)
    }

    public func setMuted(displayKey: String, muted: Bool) {
        guard var assignment = library.assignment(displayKey: displayKey) else { return }
        assignment.isMuted = muted
        library.setAssignment(assignment)
        applyPlaybackSettings(displayKey: displayKey)
    }

    // MARK: - Display topology

    /// Diffs the current screens against active windows: closes surfaces for
    /// disconnected displays (assignments are preserved in the library), creates
    /// them for new displays that have persisted assignments, and repositions
    /// on resolution/frame changes.
    public func refreshDisplays(reason: String) {
        let newDisplays = DisplayInfo.currentScreens()
        let newKeys = Set(newDisplays.map(\.id))
        let oldKeys = Set(windows.keys)

        for gone in oldKeys.subtracting(newKeys) {
            AppLog.renderer.info("Display removed: \(gone, privacy: .public)")
            record("Display removed: \(gone) — assignment preserved")
            cancelScheduler(displayKey: gone)
            windows[gone]?.close()
            windows[gone] = nil
            // Keep states/currentWallpaperIDs readable for disconnected displays? No — surface gone.
            states[gone] = nil
            currentWallpaperIDs[gone] = nil
        }

        displays = newDisplays

        for display in newDisplays {
            if let window = windows[display.id] {
                window.show(onScreenFrame: display.frame) // repositions on resolution change
            } else if let assignment = library.assignment(displayKey: display.id),
                      assignment.wallpaperID != nil {
                // Display reconnected with a remembered wallpaper.
                apply(wallpaperID: assignment.wallpaperID!, toDisplay: display.id)
                record("Restored wallpaper on reconnected \(display.name)")
            }
        }
        record("Displays refreshed (\(reason)): \(newDisplays.count) display(s)")
    }

    /// Launch path: put remembered wallpapers on every display that has one.
    /// Playlist assignments resume with their current entry + the auto-change loop.
    public func restoreAllAssignments() {
        for display in displays {
            guard let assignment = library.assignment(displayKey: display.id) else { continue }
            if let playlistID = assignment.playlistID,
               let playlist = library.playlist(id: playlistID),
               playlist.isEnabled,
               !playlist.wallpaperIDs.isEmpty {
                let showID = assignment.wallpaperID ?? playlist.wallpaperIDs.first
                if let showID {
                    applyPlaylistItem(showID, toDisplay: display.id, keepingPlaylist: playlistID)
                }
                startScheduler(displayKey: display.id)
            } else if let wallpaperID = assignment.wallpaperID {
                apply(wallpaperID: wallpaperID, toDisplay: display.id)
            }
        }
        record("Restored assignments on launch")
    }

    // MARK: - System pause (display/system sleep)

    private var systemPaused = false

    private func setSystemPaused(_ paused: Bool, reason: String) {
        systemPaused = paused
        if paused {
            for window in windows.values { window.pause() }
        } else if !userPaused {
            for window in windows.values { window.resume() }
        }
        record("System pause \(paused) (\(reason))")
    }

    // MARK: - Internals

    private func play(url: URL, wallpaper: Wallpaper, display: DisplayInfo, assignment: DisplayAssignment) {
        let window = windows[display.id] ?? WallpaperWindowController(displayKey: display.id)
        windows[display.id] = window
        window.onStateChange = { [weak self] key, state in
            Task { @MainActor in
                self?.states[key] = state
            }
        }
        window.show(onScreenFrame: display.frame)
        window.play(
            url: url,
            wallpaperID: wallpaper.id,
            scaling: assignment.scaling,
            muted: assignment.isMuted,
            volume: assignment.volume
        )
        currentWallpaperIDs[display.id] = wallpaper.id
    }

    private func record(_ line: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        rendererEvents.append("\(stamp)  \(line)")
        if rendererEvents.count > 200 {
            rendererEvents.removeFirst(rendererEvents.count - 200)
        }
        AppLog.renderer.info("\(line, privacy: .public)")
    }
}

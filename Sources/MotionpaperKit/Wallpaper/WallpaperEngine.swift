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
    @ObservationIgnored private lazy var lockScreenMatcher = LockScreenMatcher(paths: library.storagePaths)
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
            Task { @MainActor in self?.setDisplaysAsleep(true, reason: "display sleep") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setDisplaysAsleep(false, reason: "display wake") }
        })

        // System sleep/wake.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setDisplaysAsleep(true, reason: "system sleep") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.setDisplaysAsleep(false, reason: "system wake") }
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

        // Keep the system wallpaper (and thus the Lock Screen) visually
        // matched with a still frame, when enabled.
        if settings.values.matchLockScreen {
            let source = url
            let wallpaperCopy = wallpaper
            Task { [weak self] in
                await self?.lockScreenMatcher.matchLockScreen(to: wallpaperCopy, sourceURL: source)
            }
        }
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

        if playlist.mode == .dayCycle {
            // The day-cycle scheduler shows the segment for the current time.
            startScheduler(displayKey: displayKey)
        } else if let next = PlaylistAdvancer.nextWallpaper(in: playlist, after: assignment.wallpaperID),
           next != assignment.wallpaperID {
            applyPlaylistItem(next, toDisplay: displayKey, keepingPlaylist: playlistID)
            startScheduler(displayKey: displayKey)
        } else if let current = assignment.wallpaperID {
            applyPlaylistItem(current, toDisplay: displayKey, keepingPlaylist: playlistID)
            startScheduler(displayKey: displayKey)
        }
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
              !playlist.wallpaperIDs.isEmpty,
              displays.contains(where: { $0.id == displayKey }) else { return }

        if playlist.mode == .dayCycle {
            startDayCycleScheduler(displayKey: displayKey, playlistID: playlistID)
        } else if playlist.changeInterval > 0 {
            startIntervalScheduler(displayKey: displayKey, playlist: playlist)
        }
    }

    /// Classic mode: sleep for the interval, advance, repeat.
    private func startIntervalScheduler(displayKey: String, playlist: Playlist) {
        let key = displayKey
        schedulers[key] = Task { [weak self] in
            var interval = playlist.changeInterval
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                // Re-read the playlist: it may have been edited since.
                guard let current = self.library.assignment(displayKey: key),
                      let currentPlaylistID = current.playlistID,
                      let livePlaylist = self.library.playlist(id: currentPlaylistID),
                      livePlaylist.isEnabled,
                      let next = PlaylistAdvancer.nextWallpaper(in: livePlaylist, after: current.wallpaperID)
                else { return }
                if livePlaylist.mode == .dayCycle {
                    // Mode switched while running — restart with the right loop.
                    self.startScheduler(displayKey: key)
                    return
                }
                self.applyPlaylistItem(next, toDisplay: key, keepingPlaylist: currentPlaylistID)
                interval = livePlaylist.changeInterval
            }
        }
        record("Playlist “\(playlist.name)” auto-change every \(PlaylistAdvancer.intervalLabel(playlist.changeInterval)) on \(displayKey)")
    }

    /// Day-cycle mode: equal 24 h segments; sleeps until the exact boundary.
    private func startDayCycleScheduler(displayKey: String, playlistID: UUID) {
        let key = displayKey
        // Show the current segment immediately.
        if let playlist = library.playlist(id: playlistID),
           let segmentID = PlaylistAdvancer.dayCycleWallpaper(in: playlist),
           segmentID != library.assignment(displayKey: key)?.wallpaperID {
            applyPlaylistItem(segmentID, toDisplay: key, keepingPlaylist: playlistID)
        }
        schedulers[key] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      let livePlaylist = self.library.playlist(id: playlistID) else { return }
                guard let boundary = PlaylistAdvancer.nextDayCycleBoundary(
                    after: Date(), count: livePlaylist.wallpaperIDs.count
                ) else { return }
                let seconds = max(1, boundary.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                guard let current = self.library.assignment(displayKey: key),
                      current.playlistID == playlistID,
                      let live = self.library.playlist(id: playlistID),
                      live.isEnabled,
                      let segmentID = PlaylistAdvancer.dayCycleWallpaper(in: live)
                else { return }
                if segmentID != current.wallpaperID {
                    self.applyPlaylistItem(segmentID, toDisplay: key, keepingPlaylist: playlistID)
                    self.record("Day cycle: “\(self.library.wallpaper(id: segmentID)?.name ?? "?")” on \(key)")
                }
            }
        }
        if let playlist = library.playlist(id: playlistID) {
            record("Day-cycle playlist “\(playlist.name)” (\(playlist.wallpaperIDs.count) equal segments) on \(displayKey)")
        }
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

    // MARK: - Lock Screen matching

    /// Immediately syncs a still frame of the primary display's wallpaper to
    /// the system wallpaper (what the Lock Screen renders).
    public func matchLockScreenNow() {
        guard settings.values.matchLockScreen else { return }
        guard let wallpaper = currentActiveWallpaper(),
              let url = library.fileURL(for: wallpaper) else { return }
        let wallpaperCopy = wallpaper
        Task { [weak self] in
            await self?.lockScreenMatcher.matchLockScreen(to: wallpaperCopy, sourceURL: url)
        }
    }

    /// Sets the pre-login window picture from the active wallpaper's frame.
    public func setLoginWindowPicture() async throws {
        guard let wallpaper = currentActiveWallpaper(),
              let url = library.fileURL(for: wallpaper) else {
            throw LockScreenMatcherError.noActiveWallpaper
        }
        let frameURL = try await lockScreenMatcher.exportLoginWindowFrame(from: url, wallpaperID: wallpaper.id)
        try await lockScreenMatcher.setLoginWindowPicture(frameURL)
    }

    public enum LockScreenMatcherError: Error, CustomStringConvertible {
        case noActiveWallpaper
        public var description: String {
            switch self {
            case .noActiveWallpaper: "No active wallpaper to match."
            }
        }
    }

    private func currentActiveWallpaper() -> Wallpaper? {
        let candidateID = currentWallpaperIDs.values.first
            ?? library.assignments.compactMap(\.wallpaperID).first
            ?? library.recents.first
        guard let id = candidateID else { return nil }
        return library.wallpaper(id: id)
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

    // MARK: - Next / previous (menu bar quick controls)

    /// Advances every display that shows a wallpaper: playlists advance within
    /// themselves; single wallpapers cycle through the library (name order).
    public func nextWallpaper() {
        for assignment in library.assignments {
            advance(displayKey: assignment.displayKey, forward: true)
        }
    }

    public func previousWallpaper() {
        for assignment in library.assignments {
            advance(displayKey: assignment.displayKey, forward: false)
        }
    }

    private func advance(displayKey: String, forward: Bool) {
        guard let assignment = library.assignment(displayKey: displayKey),
              displays.contains(where: { $0.id == displayKey }) else { return }

        // Playlist-assigned displays advance within the playlist.
        if let playlistID = assignment.playlistID,
           let playlist = library.playlist(id: playlistID), playlist.isEnabled {
            let next = forward
                ? PlaylistAdvancer.nextWallpaper(in: playlist, after: assignment.wallpaperID)
                : PlaylistAdvancer.previousWallpaper(in: playlist, before: assignment.wallpaperID)
            if let next, next != assignment.wallpaperID {
                applyPlaylistItem(next, toDisplay: displayKey, keepingPlaylist: playlistID)
            }
            return
        }

        // Otherwise cycle through the healthy library items in name order.
        let ordered = library.wallpapers
            .filter { $0.status == .ok }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        guard !ordered.isEmpty else { return }

        guard let currentID = assignment.wallpaperID,
              let index = ordered.firstIndex(where: { $0.id == currentID }) else {
            apply(wallpaperID: ordered[0].id, toDisplay: displayKey)
            return
        }
        let count = ordered.count
        let nextIndex = forward ? (index + 1) % count : (index - 1 + count) % count
        apply(wallpaperID: ordered[nextIndex].id, toDisplay: displayKey)
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

    // MARK: - Pause policy (three independent causes)

    /// True while a display or the system is asleep.
    @ObservationIgnored private var displayAsleep = false
    /// True when the ResourceController's power/visibility policy says pause.
    @ObservationIgnored private var policyPaused = false

    /// Pause summary for the UI (menu bar / diagnostics).
    public var pauseReasonSummary: String? {
        if userPaused { return "Paused by you" }
        if displayAsleep { return "Paused — display asleep" }
        if policyPaused { return "Paused — power policy" }
        return nil
    }

    public func toggleUserPause() {
        setUserPaused(!userPaused)
    }

    public func setUserPaused(_ paused: Bool) {
        guard userPaused != paused else { return }
        userPaused = paused
        reconcilePlayback()
        record(paused ? "Paused by user" : "Resumed by user")
    }

    public func pauseAll() { setUserPaused(true) }
    public func resumeAll() { setUserPaused(false) }

    /// Called by the ResourceController.
    public func setPolicyPaused(_ paused: Bool) {
        guard policyPaused != paused else { return }
        policyPaused = paused
        reconcilePlayback()
        record(paused ? "Power policy pause engaged" : "Power policy pause released")
    }

    private func setDisplaysAsleep(_ asleep: Bool, reason: String) {
        guard displayAsleep != asleep else { return }
        displayAsleep = asleep
        reconcilePlayback()
        record("Displays asleep=\(asleep) (\(reason))")
    }

    /// Applies the combined pause state to every surface. Idempotent.
    private func reconcilePlayback() {
        let shouldPlay = !userPaused && !displayAsleep && !policyPaused
        for window in windows.values {
            if shouldPlay {
                window.resume()
            } else {
                window.pause()
            }
        }
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
        if wallpaper.kind == .spriteSheet, let sprite = wallpaper.sprite {
            window.playSpriteSheet(url: url, wallpaperID: wallpaper.id, sprite: sprite, scaling: assignment.scaling)
        } else {
            window.play(
                url: url,
                wallpaperID: wallpaper.id,
                scaling: assignment.scaling,
                muted: assignment.isMuted,
                volume: assignment.volume
            )
        }
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

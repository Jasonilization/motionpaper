import AppKit
import Foundation
import MotionpaperKit

/// Crash-loop detection and self-healing.
///
/// The macOS 27.0 beta (26A5406e) has a broken Swift-concurrency runtime:
/// MenuBarClientCore — an Apple framework — segfaults inside
/// `swift_task_isCurrentExecutorWithFlagsImpl` with zero app frames in the
/// crash. The keepalive agent relaunches the app within seconds, but if the
/// same crash repeats rapidly, this recovery manager pauses the menu-bar
/// icon (the main surface that puts code in MenuBarClientCore's path) for
/// an hour. Everything else keeps working. The icon comes back by itself.
enum CrashRecovery {
    struct State: Codable {
        var recentLaunches: [Date] = []
        var menuBarCooldownUntil: Date?
        var cooldownNoticePending = false
    }

    private static var cachedState: State?

    private static var stateURL: URL {
        AppPaths.standard().appSupport.appendingPathComponent("recovery.json")
    }

    // MARK: - Launch recording

    /// Records a launch timestamp. When 3+ launches happen inside 15
    /// minutes, the menu-bar icon enters a one-hour cooldown.
    static func recordLaunch(now: Date = Date()) {
        var state = loadState()
        let cutoff = now.addingTimeInterval(-900)
        state.recentLaunches.removeAll { $0 <= cutoff }
        state.recentLaunches.append(now)

        if state.recentLaunches.count >= 3 {
            state.menuBarCooldownUntil = now.addingTimeInterval(3600)
            state.recentLaunches = []
            state.cooldownNoticePending = true
            AppLog.app.warning("Crash loop detected — menu-bar icon paused for 1 hour")
        }
        save(state)
        cachedState = state
    }

    // MARK: - Cooldown

    /// True while the menu-bar icon should stay hidden (crash-loop cooldown).
    static func menuBarInCooldown(now: Date = Date()) -> Bool {
        let state = loadState()
        guard let until = state.menuBarCooldownUntil else { return false }
        if now >= until {
            var cleared = state
            cleared.menuBarCooldownUntil = nil
            save(cleared)
            cachedState = cleared
            return false
        }
        return true
    }

    /// Time remaining in the cooldown, for the Settings UI.
    static var cooldownMinutesRemaining: Int {
        guard let until = loadState().menuBarCooldownUntil else { return 0 }
        return max(0, Int(until.timeIntervalSinceNow / 60) + 1)
    }

    /// Shows the explanatory alert once per cooldown entry.
    static func presentCooldownNoticeIfNeeded() {
        var state = loadState()
        guard state.cooldownNoticePending, state.menuBarCooldownUntil != nil else { return }
        state.cooldownNoticePending = false
        save(state)

        let alert = NSAlert()
        alert.messageText = "Menu-bar icon paused temporarily"
        alert.informativeText = """
        Motionpaper has recovered from a repeated macOS crash. \
        On this macOS beta, Apple's menu-bar code (MenuBarClientCore) \
        can crash any app that shows a menu-bar icon, so the icon is \
        paused for an hour. Wallpapers, playlists, and the Lock Screen \
        overlay are unaffected. The icon returns automatically — and \
        installing the pending macOS update (27.2+) fixes the OS bug \
        for good.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Persistence

    private static func loadState() -> State {
        if let cachedState { return cachedState }
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(State.self, from: data) else {
            return State()
        }
        return state
    }

    private static func save(_ state: State) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL, options: .atomic)
        }
    }
}

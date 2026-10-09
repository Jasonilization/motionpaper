import Foundation
import Observation

/// User preferences. A single Codable struct so settings round-trip atomically.
public struct AppSettings: Codable, Sendable, Equatable {
    public var launchAtLogin: Bool = false
    public var startInBackground: Bool = false
    public var showMenuBarIcon: Bool = true

    public var performanceMode: PerformanceMode = .balanced
    /// Pause playback when battery level is at or below this percentage. 0 = never.
    public var pauseOnBatteryBelowPercent: Int = 0
    public var pauseInLowPowerMode: Bool = true
    public var pauseWhenLocked: Bool = true

    public var defaultMuted: Bool = true
    public var defaultVolume: Double = 0.0
    public var defaultScaling: ScalingMode = .fill

    /// Automatically sync a still frame of the active wallpaper to the system
    /// wallpaper so the Lock Screen matches (Wallspace Pro's "lock screen"
    /// mechanism — stills only; macOS forbids live video there).
    public var matchLockScreen: Bool = false

    /// EXPERIMENTAL: live video on the Lock Screen via an undocumented SkyLight
    /// Space-level API (same technique as public open-source notch overlays).
    /// Off by default; may stop working on a future macOS release.
    public var enableLockScreenOverlay: Bool = false

    /// Auto-relaunch after crashes (the macOS beta's system-level hit-testing
    /// bug can kill the app; the watchdog restores the wallpaper in seconds).
    public var restartAfterCrashes: Bool = true

    // Gallery API keys (stored locally, only sent to their own services).
    public var pixabayAPIKey: String = ""
    public var pexelsAPIKey: String = ""

    public init() {}
}

public enum PerformanceMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Maximum Battery: pause aggressively whenever the wallpaper isn't visible.
    case batterySaver
    /// Balanced: normal playback, pause on display sleep/system sleep/lock.
    case balanced
    /// Maximum Quality: keep playback running whenever practical.
    case maximumQuality

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .batterySaver: "Maximum Battery"
        case .balanced: "Balanced"
        case .maximumQuality: "Maximum Quality"
        }
    }

    public var explanation: String {
        switch self {
        case .batterySaver:
            "Pauses wallpaper playback whenever the display sleeps, the Mac locks, you switch to a fullscreen app, or the Mac runs on battery. Quietest, longest battery life."
        case .balanced:
            "Plays normally; pauses during display sleep, system sleep, and while locked. Recommended."
        case .maximumQuality:
            "Keeps playback active whenever possible, including on battery. Uses more energy."
        }
    }
}

/// Settings persisted to `settings.json` (atomic writes, loaded at init).
@MainActor @Observable
public final class SettingsStore {
    public private(set) var values: AppSettings
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) {
            self.values = decoded
        } else {
            self.values = AppSettings()
        }
    }

    /// Atomically updates one or more settings and schedules a debounced save.
    public func update(_ mutate: (inout AppSettings) -> Void) {
        var copy = values
        mutate(&copy)
        guard copy != values else { return }
        values = copy
        saveTask?.cancel()
        let snapshot = copy
        let url = fileURL
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        if let data = try? JSONEncoder().encode(values) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

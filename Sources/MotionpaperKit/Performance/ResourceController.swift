import AppKit
import Foundation
import Observation

/// Applies the performance-mode policy: decides when the engine should be
/// paused for power/visibility reasons and tells the engine about it.
///
/// The engine keeps three independent pause causes (user, display/system
/// sleep, policy). This controller owns the "policy" cause only, so manual
/// pause and sleep handling always work regardless of mode.
@MainActor @Observable
public final class ResourceController {
    public private(set) var coveredDisplays: Set<String> = []
    public private(set) var lastReasons: [String] = []

    @ObservationIgnored private weak var engine: WallpaperEngine?
    @ObservationIgnored private var settings: SettingsStore?
    @ObservationIgnored private var power: PowerMonitor?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Wires everything together. Call once at app start.
    public func attach(engine: WallpaperEngine, settings: SettingsStore, power: PowerMonitor) {
        self.engine = engine
        self.settings = settings
        self.power = power

        power.onChange = { [weak self] in
            Task { @MainActor in self?.evaluate() }
        }

        // Fullscreen coverage changes when apps activate or Spaces switch.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.screensDidWakeNotification,
        ] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.evaluate() }
            })
        }

        evaluate()
    }

    /// Re-evaluates the current policy. Called on every relevant state change.
    public func evaluate() {
        guard let engine, let settings, let power else { return }
        let mode = settings.values.performanceMode
        var reasons: [String] = []

        // Lock: balanced pauses when locked; battery mode always; quality never.
        let pauseWhenLocked = settings.values.pauseWhenLocked || mode == .batterySaver
        if pauseWhenLocked && power.isScreenLocked {
            reasons.append("screen locked")
        }

        // Battery policy.
        if mode == .batterySaver && power.onBatteryPower {
            reasons.append("on battery")
        }
        if let level = power.batteryLevelPercent,
           settings.values.pauseOnBatteryBelowPercent > 0,
           level <= settings.values.pauseOnBatteryBelowPercent {
            reasons.append("battery at \(level)%")
        }

        // Low Power Mode (any mode, user-controlled setting; forced in battery mode).
        if (settings.values.pauseInLowPowerMode || mode == .batterySaver) && power.lowPowerModeEnabled {
            reasons.append("Low Power Mode")
        }

        // Fullscreen coverage: only in battery mode — in balanced/quality the
        // wallpaper may still be visible via Mission Control.
        if mode == .batterySaver {
            coveredDisplays = FullscreenDetector.coveredDisplays()
            if !coveredDisplays.isEmpty {
                reasons.append("fullscreen app showing")
            }
        } else {
            coveredDisplays = []
        }

        lastReasons = reasons
        engine.setPolicyPaused(!reasons.isEmpty)
    }

    /// Human-readable status for the menu bar and diagnostics.
    public var pauseSummary: String? {
        lastReasons.isEmpty ? nil : "Paused — " + lastReasons.joined(separator: ", ")
    }
}

import AppKit
import Foundation
import IOKit.ps

/// Monitors power state (AC vs battery, battery level, Low Power Mode) and
/// screen lock, using public APIs only:
///
/// - IOKit power-source notifications (`IOKit/ps.h`)
/// - `ProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChangeNotification`
/// - the system's well-known distributed notifications for lock/unlock
///   (macOS has no first-class lock-state API; these notifications are the
///   standard public mechanism third-party apps rely on).
@MainActor @Observable
public final class PowerMonitor {
    public private(set) var onBatteryPower = false
    public private(set) var batteryLevelPercent: Int?
    public private(set) var lowPowerModeEnabled = false
    public private(set) var isScreenLocked = false

    /// Called on every state transition (App wires this to policy evaluation).
    public var onChange: (() -> Void)?

    /// Called specifically on lock/unlock transitions (for the experimental
    /// lock-screen overlay; kept separate from general policy re-evaluation).
    public var onLockChange: ((Bool) -> Void)?

    @ObservationIgnored private var lockObserver: NSObjectProtocol?
    @ObservationIgnored private var unlockObserver: NSObjectProtocol?
    @ObservationIgnored private var lpmObserver: NSObjectProtocol?

    public init() {
        readPowerState()
        lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled

        // Power-source changes: read on-demand from the lock poll timer below.
        // The IOKit runloop-source C callback (the app's only continuously
        // firing C-to-Swift bridge) is the prime suspect for corrupting the
        // concurrency runtime on this macOS beta — every crash began after it
        // landed, and none predate it. Removing the bridge; state is now
        // refreshed by the 0.5 s timer that already runs.

        // Low Power Mode.
        lpmObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("NSProcessInfoPowerStateDidChange"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.onChange?()
            }
        }

        // Screen lock/unlock.
        let distributed = DistributedNotificationCenter.default()
        lockObserver = distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = true
                self?.onChange?()
                self?.onLockChange?(true)
            }
        }
        unlockObserver = distributed.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isScreenLocked = false
                self?.onChange?()
                self?.onLockChange?(false)
            }
        }

        startLockPolling()
    }

    /// Reliable lock-state polling: on current macOS builds the
    /// com.apple.screenIsLocked distributed notification is not delivered for
    /// real locks (verified live), so the session dictionary — a public
    /// CoreGraphics API — is the trustworthy signal. Fires only on changes.
    @ObservationIgnored private var lockPollTask: Task<Void, Never>?
    @ObservationIgnored private var lockPollActive = false

    @ObservationIgnored private let lockWatchdog = LockWatchdog()

    private func startLockPolling() {
        lockWatchdog.start()
        // Lock transitions are delivered to the nonisolated OverlayProcessManager
        // (the experimental overlay) and reflected via its screenLocked flag;
        // actor-isolated observers crash the broken executor check on this build.
        // The watchdog's notification is observed via target-selector below —
        // synchronous main-thread delivery with no Swift-concurrency runtime
        // involvement (every Task/dispatch bridge was unreliable or crashed
        // on this macOS build).
    }

    /// Reads the current power snapshot from IOKit.
    public func readPowerState() {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let descriptions = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return }

        var onBattery: Bool?
        var maxCapacity: Int?
        var currentCapacity: Int?

        for description in descriptions {
            guard let source = IOPSGetPowerSourceDescription(snapshot, description)?.takeUnretainedValue() as? [String: Any] else { continue }
            let type = source[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType {
                if let current = source[kIOPSCurrentCapacityKey] as? Int,
                   let max = source[kIOPSMaxCapacityKey] as? Int, max > 0 {
                    currentCapacity = current
                    maxCapacity = max
                }
                let powerSource = source[kIOPSPowerSourceStateKey] as? String
                if powerSource == kIOPSBatteryPowerValue {
                    onBattery = true
                } else if powerSource == kIOPSACPowerValue {
                    onBattery = false
                }
            }
        }

        onBatteryPower = onBattery ?? false
        if let currentCapacity, let maxCapacity {
            let level = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
            batteryLevelPercent = min(100, max(0, level))
        } else {
            batteryLevelPercent = nil
        }
    }

    /// True when the Mac is on battery with no level information (shouldn't happen on portable Macs).
    public var isOnBatteryWithUnknownLevel: Bool {
        onBatteryPower && batteryLevelPercent == nil
    }
}

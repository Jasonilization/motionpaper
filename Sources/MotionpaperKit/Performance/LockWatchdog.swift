import CoreGraphics
import Foundation

/// Lock-state polling without Swift concurrency: a target-selector Timer on
/// the main runloop. Task-created-from-timer contexts silently never ran in
/// this app's environment, and the concurrency runtime's executor checks were
/// the crash vector on this macOS beta — so this watchdog uses none of it.
///
/// Delivery happens on the main thread (where the timer fires); consumers hop
/// to their own isolation once.
public final class LockWatchdog: NSObject {
    private var timer: Timer?
    private var lastLocked: Bool?

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                      selector: #selector(tick), userInfo: nil, repeats: true)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private var heartbeat = 0

    @objc private func tick() {
        let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = dict?["CGSSessionScreenIsLocked"] != nil
        heartbeat += 1
        if heartbeat % 10 == 0 {
            WallpaperEngine.appendOverlayLog("watchdog tick \(heartbeat) locked=\(locked)")
        }
        guard locked != lastLocked else { return }
        lastLocked = locked
        WallpaperEngine.appendOverlayLog("watchdog TRANSITION locked=\(locked)")
        // Selector-based delivery (the single path — consumers observe the
        // notification; no direct closures): synchronous on the posting thread (main),
        // zero Swift-concurrency machinery. Every dispatch/Task bridge proved
        // unreliable or crash-prone on this macOS build; AppKit's own
        // target-selector mechanism is the one path that always runs.
        NotificationCenter.default.post(
            name: Self.lockChangedNotification,
            object: nil,
            userInfo: ["locked": locked]
        )
    }

    public static let lockChangedNotification = Notification.Name("motionpaper.lockChanged")
}

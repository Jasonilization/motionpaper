import AppKit
import MotionpaperKit

/// Prevents duplicate Motionpaper instances.
///
/// The keepalive agent relaunches the app after a crash, and a user `open`
/// can race it — two instances mean two wallpaper windows stacked on the
/// desktop, two menu-bar icons, and confusing "the app just quit" moments
/// when one of them dies. The second instance activates the first and
/// exits cleanly (exit 0 — the watchdog never restarts clean exits).
enum SingleInstanceLock {
    private static var lockFD: Int32 = -1

    static let activateNotificationName = "com.jasonilization.motionpaper.activate"

    /// Tries to take the exclusive app lock. Returns false when another
    /// Motionpaper instance already holds it.
    @discardableResult
    static func tryAcquire() -> Bool {
        let url = AppPaths.standard().appSupport.appendingPathComponent("app.lock")
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            // Never block startup because of a lock failure.
            return true
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        // Held for the lifetime of the process; the kernel releases it on exit.
        lockFD = fd
        return true
    }

    /// Brings the already-running instance to the front.
    static func activateExistingInstance() {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(activateNotificationName),
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let bundleID = Bundle.main.bundleIdentifier ?? "com.jasonilization.motionpaper"
        let selfPID = ProcessInfo.processInfo.processIdentifier
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        where app.processIdentifier != selfPID {
            app.activate(options: [.activateIgnoringOtherApps])
            break
        }
    }
}

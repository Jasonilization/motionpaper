import AppKit
import Foundation
import MotionpaperKit

// MotionpaperLockHelper — EXPERIMENTAL lock-screen overlay host.
//
// Runs in its own process so the undocumented SkyLight space operations can
// never destabilize the main app: on macOS builds where those operations
// corrupt the host process's concurrency state (observed on a macOS 27 beta),
// only this helper can crash — the main app relaunches it on the next lock.
//
// Usage: MotionpaperLockHelper <video-path> <scaling-mode>
// Exits by itself when the session unlocks (or after 24 h as a failsafe).

@main
struct LockHelperApp {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: MotionpaperLockHelper <video-path> [scaling]\n".utf8))
            exit(1)
        }
        let videoURL = URL(fileURLWithPath: args[1])
        let scaling: ScalingMode = args.count >= 3 ? (ScalingMode(rawValue: args[2]) ?? .fill) : .fill

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let delegate = HelperDelegate(videoURL: videoURL, scaling: scaling)
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class HelperDelegate: NSObject, NSApplicationDelegate {
    private let videoURL: URL
    private let scaling: ScalingMode
    private let overlay = LockScreenOverlay()
    private var unlockTimer: Timer?
    private var started = Date()

    init(videoURL: URL, scaling: ScalingMode) {
        self.videoURL = videoURL
        self.scaling = scaling
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prepare the lock-level space and show the wallpaper.
        overlay.prepare()
        guard overlay.isUsable else {
            FileHandle.standardError.write(Data("helper: overlay unavailable\n".utf8))
            WallpaperEngine.appendOverlayLog("helper: prepare unavailable — state \(overlay.state)")
            NSApp.terminate(nil)
            return
        }
        overlay.show(url: videoURL, scaling: scaling)
        WallpaperEngine.appendOverlayLog("helper: overlay shown — window up, playing")

        // Watch for unlock (session dictionary, same reliable signal) and exit
        // when the lock is gone — the window dies with this process.
        unlockTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            let dict = CGSessionCopyCurrentDictionary() as? [String: Any]
            let locked = dict?["CGSSessionScreenIsLocked"] != nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                if !locked || Date().timeIntervalSince(self.started) > 86_400 {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlay.hide()
        WallpaperEngine.appendOverlayLog("helper: exiting (hide + terminate)")
    }
}

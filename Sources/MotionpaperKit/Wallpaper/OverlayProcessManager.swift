import Foundation

/// Owns the experimental lock-screen overlay helper process.
///
/// Deliberately NOT @MainActor: Swift 6 injects executor checks into actor-
/// isolated entry points (including @objc methods), and those checks crash
/// in the concurrency runtime on this macOS beta during lock transitions.
/// This manager is called synchronously on the main thread (the watchdog's
/// runloop timer) but never touches the concurrency runtime at all — plain
/// Foundation only.
public final class OverlayProcessManager: NSObject, @unchecked Sendable {
    public static let shared: OverlayProcessManager = {
        // Registered for the lock notification at first use (main thread).
        let instance = OverlayProcessManager()
        return instance
    }()

    public struct Config {
        public var enabled: Bool
        public var videoPath: String
        public var scaling: String
        public var helperPath: String

        public init(enabled: Bool, videoPath: String, scaling: String, helperPath: String) {
            self.enabled = enabled
            self.videoPath = videoPath
            self.scaling = scaling
            self.helperPath = helperPath
        }
    }

    /// Written by the engine (main thread) at apply/restore; read at lock.
    private var config: Config?
    private var helperProcess: Process?

    /// Latest lock state, set synchronously at the lock transition. Main-
    /// thread-only access in practice (watchdog timer + engine reads).
    public nonisolated(unsafe) static var screenLocked = false

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLockChanged(_:)),
            name: LockWatchdog.lockChangedNotification, object: nil
        )
    }

    public func updateConfig(_ newConfig: Config) {
        config = newConfig
    }

    public var isHelperRunning: Bool {
        helperProcess?.isRunning ?? false
    }

    @objc private func handleLockChanged(_ note: Notification) {
        guard let locked = note.userInfo?["locked"] as? Bool else { return }
        Self.screenLocked = locked

        if locked {
            guard let config, config.enabled, !config.videoPath.isEmpty,
                  FileManager.default.fileExists(atPath: config.videoPath) else {
                WallpaperEngine.appendOverlayLog("mgr: lock — no config/disabled, skipping")
                return
            }
            if helperProcess?.isRunning == true {
                WallpaperEngine.appendOverlayLog("mgr: lock — helper already running")
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.helperPath)
            process.arguments = [config.videoPath, config.scaling]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                helperProcess = process
                WallpaperEngine.appendOverlayLog("mgr: helper launched pid=\(process.processIdentifier)")
            } catch {
                WallpaperEngine.appendOverlayLog("mgr: helper launch failed — \(error.localizedDescription)")
            }
        } else {
            if let process = helperProcess, process.isRunning {
                process.terminate()
                WallpaperEngine.appendOverlayLog("mgr: helper terminated on unlock")
            }
            helperProcess = nil
        }
    }
}

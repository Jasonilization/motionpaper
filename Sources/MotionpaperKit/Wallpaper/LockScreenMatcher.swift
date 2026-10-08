import AppKit
import AVFoundation
import Foundation

/// Matches the system Lock Screen to the active live wallpaper.
///
/// How this works — and the honest limits:
///
/// macOS renders the Lock Screen from the system *desktop wallpaper*, and the
/// pre-login window from the `com.apple.loginwindow DesktopPicture` default.
/// Third-party apps cannot play video on either surface (that's a hard macOS
/// boundary — no public or private API renders app content there). What apps
/// *can* do — the same approach Wallspace Pro ships as its "Lock Screen"
/// feature — is export a still frame of the live wallpaper and install it as
/// the system wallpaper, so the Lock Screen shows a matching still image
/// whenever the screen locks.
@MainActor
public final class LockScreenMatcher {
    public enum Status: Equatable {
        case idle
        case applied
        case failed(String)
    }

    public private(set) var status: Status = .idle

    private let paths: AppPaths

    /// Stable location for the generated still frame.
    private var frameDirectory: URL {
        paths.appSupport.appendingPathComponent("LockScreen", isDirectory: true)
    }

    public init(paths: AppPaths) {
        self.paths = paths
        try? FileManager.default.createDirectory(at: frameDirectory, withIntermediateDirectories: true)
    }

    /// Exports a frame of the wallpaper and installs it as the desktop picture
    /// for every screen — then syncs the Lock Screen surface to the same image.
    public func matchLockScreen(to wallpaper: Wallpaper, sourceURL: URL) async {
        do {
            let frameURL = frameDirectory.appendingPathComponent("lockframe-\(wallpaper.id.uuidString).png")
            try await exportFrame(from: sourceURL, to: frameURL)
            try await setDesktopImage(frameURL)
            syncIdleSurfaceToDesktop()
            status = .applied
            AppLog.renderer.info("Lock screen matched with still frame of \(wallpaper.name, privacy: .public)")
        } catch {
            status = .failed(error.localizedDescription)
            AppLog.renderer.error("Lock screen match failed: \(error)")
        }
    }

    /// Exports a representative frame at display resolution.
    private func exportFrame(from sourceURL: URL, to destination: URL) async throws {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PosterFrameExporter.ExportError.fileMissing
        }
        // Reuse the poster-frame exporter (native resolution, capped 4K).
        try await PosterFrameExporter.export(sourceURL: sourceURL, to: destination)
    }

    /// Sets the desktop picture on every screen using the public AppKit API.
    private func setDesktopImage(_ url: URL) async throws {
        let options: [NSWorkspace.DesktopImageOptionKey: Any] = [
            .imageScaling: NSImageScaling.scaleProportionallyUpOrDown,
            .allowClipping: true,
        ]
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
        }
    }

    /// Syncs the *Lock Screen surface* itself. macOS keeps the lock screen in
    /// an "Idle" slot of the same wallpaper store System Settings writes
    /// (`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`).
    /// There is no public API for it — Apple exposes `setDesktopImageURL` for
    /// the desktop only — so this mirrors the (already-matching) Desktop
    /// configuration into every Idle slot, then restarts the user-level
    /// wallpaper agent so it reloads. Format is undocumented; if Apple changes
    /// it, this fails gracefully and only the desktop picture stays matched.
    public func syncIdleSurfaceToDesktop() {
        let storeURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
        do {
            let data = try Data(contentsOf: storeURL)
            guard var index = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                throw NSError(domain: "LockScreenMatcher", code: 2)
            }
            let changed = mirrorIdle(&index)
            if changed > 0 {
                let out = try PropertyListSerialization.data(fromPropertyList: index, format: .binary, options: 0)
                try out.write(to: storeURL, options: .atomic)
                AppLog.renderer.info("Synced \(changed) lock-screen surface slots to the desktop image")
            }
            // Restart the user-level wallpaper renderer extensions so they
            // reload the store (ExtensionKit respawns them on demand).
            for processName in ["WallpaperImageExtension", "WallpaperAerialsExtension", "wallpaperagent"] {
                let agent = Process()
                agent.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
                agent.arguments = [processName]
                agent.standardOutput = FileHandle.nullDevice
                agent.standardError = FileHandle.nullDevice
                try? agent.run()
                agent.waitUntilExit()
            }
        } catch {
            AppLog.renderer.warning("Lock-screen surface sync skipped: \(error.localizedDescription)")
        }
    }

    /// Recursively finds containers holding both "Desktop" and "Idle" entries
    /// and replaces Idle with a deep copy of Desktop — the exact transformation
    /// proven against the live store (SystemDefault, per-Space, per-Display).
    private func mirrorIdle(_ node: inout [String: Any]) -> Int {
        var changed = 0
        if node["Desktop"] is [String: Any], node["Idle"] is [String: Any] {
            node["Idle"] = deepCopy(node["Desktop"] as? [String: Any] ?? [:])
            changed += 1
        }
        for key in Array(node.keys) {
            guard var child = node[key] as? [String: Any] else { continue }
            changed += mirrorIdle(&child)
            node[key] = child
        }
        return changed
    }

    /// Plist round-trip deep copy (the store's own serialization).
    private func deepCopy(_ dict: [String: Any]) -> [String: Any] {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0),
              let copy = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return dict
        }
        return copy
    }

    /// Exports a frame suitable for the login window and returns its URL.
    public func exportLoginWindowFrame(from sourceURL: URL, wallpaperID: UUID) async throws -> URL {
        let frameURL = frameDirectory.appendingPathComponent("lockframe-\(wallpaperID.uuidString).png")
        try await exportFrame(from: sourceURL, to: frameURL)
        return frameURL
    }

    /// Optionally also match the pre-login window (requires admin).
    /// Uses the same documented `com.apple.loginwindow DesktopPicture`
    /// preference Wallspace uses — invoked with administrator privileges so
    /// the user sees the standard system password prompt exactly once.
    public func setLoginWindowPicture(_ url: URL) async throws {
        let script = """
        do shell script "defaults write com.apple.loginwindow DesktopPicture '\\(url.path)'" with administrator privileges
        """
        let appleScript = NSAppleScript(source: script)
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            throw NSError(
                domain: "LockScreenMatcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: errorInfo[NSAppleScript.errorMessage] as? String ?? "Administrator permission denied"]
            )
        }
        AppLog.renderer.info("Login window picture set")
    }
}

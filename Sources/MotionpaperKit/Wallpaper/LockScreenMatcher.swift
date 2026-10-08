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

    /// Exports a frame of the wallpaper to the stable lock-screen file and
    /// installs it as the desktop picture for every screen. If the user has
    /// picked the stable file as their Lock Screen picture in System Settings,
    /// the lock surface stays in sync forever through that one choice.
    public func matchLockScreen(to wallpaper: Wallpaper, sourceURL: URL) async {
        do {
            let frameURL = stableLockFrameURL
            try await exportFrame(from: sourceURL, to: frameURL)
            try await setDesktopImage(frameURL)
            status = .applied
            AppLog.renderer.info("Lock screen frame synced (\(wallpaper.name, privacy: .public))")
        } catch {
            status = .failed(error.localizedDescription)
            AppLog.renderer.error("Lock screen match failed: \(error)")
        }
    }

    /// Exports a representative frame at display resolution.
    func exportFrame(from sourceURL: URL, to destination: URL) async throws {
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

    /// The single, stable frame file Motionpaper keeps in sync with the active
    /// wallpaper. The user picks this file ONCE as their Lock Screen picture
    /// in System Settings; afterwards every applied wallpaper overwrites this
    /// same file, and the lock screen re-reads it each time it shows. No
    /// configuration fighting: the system's own settings keep pointing here.
    public var stableLockFrameURL: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return pictures.appendingPathComponent("Motionpaper Lock Screen.png")
    }

    /// Exports a frame suitable for the login window and returns its URL.
    public func exportLoginWindowFrame(from sourceURL: URL, wallpaperID: UUID) async throws -> URL {
        try await exportFrame(from: sourceURL, to: stableLockFrameURL)
        return stableLockFrameURL
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

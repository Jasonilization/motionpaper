import Foundation

/// Feature detection for what macOS actually permits this app to do.
///
/// Every entry states the technical reason for its status — no fake "Pro"
/// toggles. The Settings → Capabilities UI renders this list directly.
public enum CapabilityState: Equatable, Sendable {
    /// Works via public APIs.
    case supported(String)
    /// macOS exposes no public API; the reason explains the closest behavior we ship.
    case notSupportedByMacOS(String)
    /// Shipped but flagged experimental, with the caveat.
    case experimental(String)
    /// Not in this build yet, with the planned mechanism.
    case roadmap(String)

    public var label: String {
        switch self {
        case .supported: "Supported"
        case .notSupportedByMacOS: "Not supported by macOS"
        case .experimental: "Experimental"
        case .roadmap: "Planned"
        }
    }
}

public struct SystemCapability: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let state: CapabilityState

    public init(_ id: String, _ name: String, _ state: CapabilityState) {
        self.id = id
        self.name = name
        self.state = state
    }
}

public enum SystemCapabilities {
    /// Computed at call time (macOS version may change the picture).
    public static func all() -> [SystemCapability] {
        [
            SystemCapability(
                "desktop-video",
                "Desktop video wallpaper",
                .supported("Rendered in a borderless window at the macOS desktop window level — sits behind desktop icons, joins all Spaces, never takes focus.")
            ),
            SystemCapability(
                "multi-display",
                "Per-display wallpapers",
                .supported("Each display gets its own player and assignment, keyed by display name + native resolution + IOKit identity so assignments survive reconnection.")
            ),
            SystemCapability(
                "spaces",
                "Spaces & Mission Control",
                .supported("The wallpaper window uses .canJoinAllSpaces + .stationary, so it shows on every Space and stays put during Mission Control.")
            ),
            SystemCapability(
                "fullscreen-apps",
                "Fullscreen apps",
                .supported("Fullscreen apps draw above the wallpaper; Maximum Battery mode additionally pauses decoding while a fullscreen app covers the display.")
            ),
            SystemCapability(
                "menu-bar",
                "Menu-bar controls",
                .supported("Pause/resume, next/previous, reapply, favorites, recents, and per-display actions.")
            ),
            SystemCapability(
                "playlists",
                "Playlists & auto-change",
                .supported("Sequential or random order, interval-based changes per display, persisted across launches.")
            ),
            SystemCapability(
                "battery",
                "Battery & power monitoring",
                .supported("AC/battery state, battery percentage, and Low Power Mode via IOKit and ProcessInfo — all public APIs.")
            ),
            SystemCapability(
                "lock-pause",
                "Lock/unlock pause & resume",
                .supported("Playback pauses when the screen locks (per performance mode) and resumes on unlock, using the system's public lock/unlock distributed notifications.")
            ),
            SystemCapability(
                "lockscreen-live",
                "Live wallpaper on the Lock Screen",
                .notSupportedByMacOS("No third-party app can play video on the Lock Screen — that surface is system-rendered. Motionpaper does the same thing Wallspace Pro's lock-screen feature does, and one step further: it exports a still frame of your live wallpaper, installs it as the system wallpaper via the public NSWorkspace API, and syncs the Lock Screen's own wallpaper slot (the same configuration System Settings writes) so locking shows the matching frame. It's a still image — live video there is impossible.")
            ),
            SystemCapability(
                "loginwindow",
                "Login Window wallpaper",
                .notSupportedByMacOS("The pre-login login window runs outside the user session; only system wallpapers can appear there. Not accessible to any third-party app.")
            ),
            SystemCapability(
                "screensaver",
                "Screen Saver module",
                .roadmap("macOS supports third-party screen savers (.saver bundles), but they are a separate plug-in target; a Motionpaper-powered saver is planned. Until then, display sleep already pauses playback.")
            ),
            SystemCapability(
                "sleep",
                "Sleep/wake recovery",
                .supported("Playback pauses when displays or the system sleep and resumes on wake. Motionpaper never blocks system sleep (AVPlayer display-sleep prevention is disabled).")
            ),
            SystemCapability(
                "hotkeys",
                "Global hotkeys",
                .roadmap("Planned via public Carbon RegisterEventHotKey APIs — no Accessibility permission needed.")
            ),
        ]
    }
}

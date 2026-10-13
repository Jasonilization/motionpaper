import AppKit
import AVFoundation
import Foundation

/// EXPERIMENTAL: Live wallpaper on the Lock Screen via an undocumented
/// SkyLight window-space API.
///
/// There's no public API to draw anything on the macOS Lock Screen. This
/// implementation uses the same private-API technique as several open-source
/// notch/overlay apps (SkyLightWindow, MewNotch, mini-control): a dedicated
/// window Space whose "absolute level" is set to
/// NotificationCenterAtScreenLock (400) — the level at which Notification
/// Center content renders *above* the lock surface (screen lock is 300).
///
/// Lifecycle follows the shape proven by those apps: the Space is created and
/// shown ONCE when the feature is enabled, and is never destroyed or hidden
/// afterwards — lock/unlock only move a lazy window into/out of it. (Creating
/// or destroying Spaces at lock time destabilizes the system's menu-bar
/// client on some macOS builds.)
///
/// Safety rules:
/// - 100% lazy symbol loading — if Apple removes these functions, `prepare()`
///   reports unavailable and the feature disables itself.
/// - The overlay window is non-interactive, never takes focus, and is merely
///   ordered out (never destroyed) on unlock, so teardown churn can't occur.
@MainActor
public final class LockScreenOverlay {
    public enum State: Equatable {
        case idle
        case unavailable(String)
        case prepared
        case active
    }

    public private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    public var onStateChange: ((State) -> Void)?

    // MARK: - SkyLight symbols (lazy)

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    private var mainConnectionID: F_SLSMainConnectionID?
    private var spaceCreate: F_SLSSpaceCreate?
    private var spaceSetAbsoluteLevel: F_SLSSpaceSetAbsoluteLevel?
    private var showSpaces: F_SLSShowSpaces?
    private var spaceAddWindows: F_SLSSpaceAddWindowsAndRemoveFromSpaces?

    private var connectionID: Int32 = 0
    private var lockSpace: Int32 = 0

    /// The level at which Notification Center renders on the Lock Screen.
    public static let notificationCenterAtScreenLockLevel: Int32 = 400

    /// One below the Screen Lock level (300): renders *behind* the lock
    /// surface's own UI — password field, Touch ID prompt, and avatar stay
    /// visible — while sitting above the desktop. Where a wallpaper belongs.
    public static let screenLockWallpaperLevel: Int32 = 299

    public init() {}

    // MARK: - Preparation (once)

    /// Resolves symbols and creates the persistent lock-level Space.
    /// Call once when the feature is enabled — never during lock transitions.
    public func prepare() {
        guard state == .idle else { return }
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/SkyLight.framework")
        ) else {
            state = .unavailable("SkyLight framework not found")
            return
        }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let pointer = CFBundleGetFunctionPointerForName(bundle, name as CFString) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard let conn: F_SLSMainConnectionID = sym("SLSMainConnectionID", F_SLSMainConnectionID.self),
              let create: F_SLSSpaceCreate = sym("SLSSpaceCreate", F_SLSSpaceCreate.self),
              let setLevel: F_SLSSpaceSetAbsoluteLevel = sym("SLSSpaceSetAbsoluteLevel", F_SLSSpaceSetAbsoluteLevel.self),
              let show: F_SLSShowSpaces = sym("SLSShowSpaces", F_SLSShowSpaces.self),
              let addWindows: F_SLSSpaceAddWindowsAndRemoveFromSpaces = sym("SLSSpaceAddWindowsAndRemoveFromSpaces", F_SLSSpaceAddWindowsAndRemoveFromSpaces.self) else {
            state = .unavailable("Required SkyLight symbols missing on this macOS")
            AppLog.renderer.warning("Lock-screen overlay unavailable: SkyLight symbols missing")
            return
        }

        mainConnectionID = conn
        spaceCreate = create
        spaceSetAbsoluteLevel = setLevel
        showSpaces = show
        spaceAddWindows = addWindows

        connectionID = conn()
        lockSpace = create(connectionID, 1, 0)
        // Level 400 (NotificationCenterAtScreenLock) is the only level verified
        // to render on the Lock Screen; the UI remains visible through the
        // window's center cutout and receives all input (the window is
        // non-interactive).
        _ = setLevel(connectionID, lockSpace, Self.notificationCenterAtScreenLockLevel)
        _ = show(connectionID, [lockSpace] as CFArray)

        state = .prepared
        AppLog.renderer.info("Lock-screen overlay space prepared (level 400)")
    }

    public var isUsable: Bool {
        state == .prepared || state == .active
    }

    // MARK: - Window lifecycle (lazy, ordered in/out only — never destroyed)

    private var overlayWindow: NSWindow?
    private var overlayPlayer: AVQueuePlayer?
    private var overlayLooper: AVPlayerLooper?

    /// Shows the live wallpaper above the lock surface.
    public func show(url: URL, scaling: ScalingMode) {
        guard state == .prepared else { return }

        let window: NSWindow
        if let existing = overlayWindow {
            window = existing
        } else {
            let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            // Transparent surface: masked (cutout) regions must show the lock
            // UI beneath, not a window background.
            window.backgroundColor = .clear
            window.isOpaque = false
            window.ignoresMouseEvents = true
            window.acceptsMouseMovedEvents = false
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.ignoresCycle, .stationary]
            window.level = .floating

            let content = NSView()
            content.wantsLayer = true
            let layer = AVPlayerLayer()
            content.layer = layer
            window.contentView = content

            // Cut a hole in the video for the lock UI (password field etc.)
            Self.applyCutout(to: layer, in: frame)

            overlayWindow = window
        }

        // Independent player, muted, looping.
        overlayLooper?.disableLooping()
        overlayPlayer?.pause()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        overlayLooper = AVPlayerLooper(player: player, templateItem: item)
        overlayPlayer = player
        (window.contentView?.layer as? AVPlayerLayer)?.player = player
        (window.contentView?.layer as? AVPlayerLayer)?.videoGravity = scaling.avVideoGravity

        window.orderFrontRegardless()
        FileHandle.standardError.write(Data("DBG: overlay moving to lock space\n".utf8))
        _ = spaceAddWindows?(connectionID, lockSpace, [window.windowNumber] as CFArray, 7)
        player.play()
        state = .active
        FileHandle.standardError.write(Data("DBG: overlay ACTIVE\n".utf8))
        AppLog.renderer.warning("Lock-screen overlay active (experimental)")
    }

    /// Cuts two precise holes in the video matching the macOS Lock Screen UI:
    ///
    /// 1. Clock hole: the large clock + date at top center
    ///    (visual y ≈ 8%–20% of screen, 40% width)
    ///
    /// 2. Login hole: avatar + user name + password field + Touch ID hint
    ///    (visual y ≈ 40%–59% of screen, 30% width)
    ///
    /// Between the holes, the video plays. The video also fills the margins.
    /// All positions are configurable via a JSON file so the user can
    /// fine-tune without rebuilding.
    static func applyCutout(to layer: CALayer, in frame: CGRect) {
        let config = Self.cutoutConfig()
        let bounds = CGRect(origin: .zero, size: frame.size)
        let maskLayer = CAShapeLayer()
        let path = CGMutablePath()
        path.addRect(bounds)

        // Hole 1: Clock cluster (top center — text, use rectangle)
        let clockWidth = bounds.width * config.clock.widthFraction
        let clockHeight = bounds.height * config.clock.heightFraction
        let clockCenterCG = bounds.height * (1.0 - config.clock.centerYFraction)
        let clockHole = CGRect(
            x: bounds.midX - clockWidth / 2,
            y: clockCenterCG - clockHeight / 2,
            width: clockWidth,
            height: clockHeight
        )
        path.addRoundedRect(in: clockHole, cornerWidth: 12, cornerHeight: 12)

        // Hole 2: Avatar (CIRCLE — profile pic is always circular)
        if let avatar = config.avatar, avatar.radiusFraction > 0 {
            let radius = bounds.height * avatar.radiusFraction
            let avatarCenterCG = bounds.height * (1.0 - avatar.centerYFraction)
            path.addEllipse(in: CGRect(
                x: bounds.midX - radius,
                y: avatarCenterCG - radius,
                width: radius * 2,
                height: radius * 2
            ))
        }

        // Hole 3: Login cluster (password field + name + Touch ID — bottom)
        let loginWidth = bounds.width * config.login.widthFraction
        let loginHeight = bounds.height * config.login.heightFraction
        let loginCenterCG = bounds.height * (1.0 - config.login.centerYFraction)
        let loginHole = CGRect(
            x: bounds.midX - loginWidth / 2,
            y: loginCenterCG - loginHeight / 2,
            width: loginWidth,
            height: loginHeight
        )
        path.addRoundedRect(in: loginHole, cornerWidth: 12, cornerHeight: 12)

        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        layer.mask = maskLayer
    }

    struct CutoutConfig: Codable {
        struct Hole: Codable {
            var widthFraction: CGFloat
            var heightFraction: CGFloat
            var centerYFraction: CGFloat
        }
        struct Circle: Codable {
            var radiusFraction: CGFloat  // as fraction of screen HEIGHT
            var centerYFraction: CGFloat  // from top
        }
        var clock: Hole
        var avatar: Circle?
        var login: Hole

        static func defaults() -> CutoutConfig {
            // Tuned from the user's annotated lock screen screenshot
            CutoutConfig(
                clock: Hole(
                    widthFraction: 0.24,
                    heightFraction: 0.14,
                    centerYFraction: 0.166
                ),
                avatar: Circle(
                    radiusFraction: 0.035,
                    centerYFraction: 0.84
                ),
                login: Hole(
                    widthFraction: 0.09,
                    heightFraction: 0.05,
                    centerYFraction: 0.93
                )
            )
        }
    }

    static func cutoutConfig() -> CutoutConfig {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Motionpaper/lockscreen-cutout.json")
        if let data = try? Data(contentsOf: path),
           let config = try? JSONDecoder().decode(CutoutConfig.self, from: data) {
            return config
        }
        let defaults = CutoutConfig.defaults()
        writeConfig(defaults, to: path)
        return defaults
    }

    static func writeConfig(_ config: CutoutConfig, to path: URL) {
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: path, options: .atomic)
        }
    }

    /// Hides the overlay — orders the window out and stops decode. The window
    /// and the Space stay alive (the proven-stable lifecycle).
    public func hide() {
        guard state == .active else { return }
        overlayPlayer?.pause()
        overlayLooper?.disableLooping()
        overlayPlayer?.replaceCurrentItem(with: nil)
        overlayWindow?.orderOut(nil)
        state = .prepared
        AppLog.renderer.info("Lock-screen overlay hidden")
    }
}

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
    private var overlayPlayerLayer: AVPlayerLayer?

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

            let content = LockOverlayContentView()
            content.frame = frame
            window.contentView = content
            overlayPlayerLayer = content.playerLayer

            overlayWindow = window
        }

        if let content = window.contentView as? LockOverlayContentView {
            content.syncCutoutAndPlayerFrame()
            overlayPlayerLayer = content.playerLayer
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
        overlayPlayerLayer?.player = player
        overlayPlayerLayer?.videoGravity = scaling.avVideoGravity

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
    ///
    /// The mask is applied to a normal host `CALayer`. `AVPlayerLayer` ignores
    /// layer masks, so video must live in a sublayer beneath a masked host.
    static func applyCutout(to hostLayer: CALayer, in frame: CGRect) {
        let config = Self.cutoutConfig()
        let bounds = CGRect(origin: .zero, size: frame.size)
        let maskLayer = CAShapeLayer()
        maskLayer.frame = bounds
        maskLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let path = cutoutPath(in: bounds, config: config)
        maskLayer.path = path
        maskLayer.fillRule = .evenOdd
        hostLayer.mask = maskLayer
    }

    /// Holes the user placed on a picture of their lock screen. When `shapes`
    /// was saved, those are the holes. Older files keep clock, avatar, and login.
    static func cutoutPath(in bounds: CGRect, config: CutoutConfig) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        if config.shapesExplicit {
            for shape in config.shapes {
                append(shape, to: path, in: bounds)
            }
            return path
        }

        append(
            CutoutConfig.Shape(
                kind: .rect,
                widthFraction: config.clock.widthFraction,
                heightFraction: config.clock.heightFraction,
                centerYFraction: config.clock.centerYFraction,
                centerXFraction: config.clock.centerXFraction
            ),
            to: path,
            in: bounds
        )
        if let avatar = config.avatar, avatar.radiusFraction > 0 {
            let diameter = avatar.radiusFraction * 2
            append(
                CutoutConfig.Shape(
                    kind: .circle,
                    widthFraction: diameter * bounds.height / max(bounds.width, 1),
                    heightFraction: diameter,
                    centerYFraction: avatar.centerYFraction,
                    centerXFraction: avatar.centerXFraction
                ),
                to: path,
                in: bounds
            )
        }
        append(
            CutoutConfig.Shape(
                kind: .rect,
                widthFraction: config.login.widthFraction,
                heightFraction: config.login.heightFraction,
                centerYFraction: config.login.centerYFraction,
                centerXFraction: config.login.centerXFraction
            ),
            to: path,
            in: bounds
        )
        return path
    }

    private static func append(_ shape: CutoutConfig.Shape, to path: CGMutablePath, in bounds: CGRect) {
        let width = bounds.width * shape.widthFraction
        let height = bounds.height * shape.heightFraction
        let centerY = bounds.height * (1.0 - shape.centerYFraction)
        let centerX = bounds.width * shape.centerXFraction
        let rect = CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
        if shape.kind == .circle {
            path.addEllipse(in: rect)
        } else {
            path.addRoundedRect(in: rect, cornerWidth: 12, cornerHeight: 12)
        }
    }

    /// Renders the cutout mask geometry to PNG (alpha preserved). Hole pixels
    /// are transparent; everything else is opaque red — no SkyLight, window, or video.
    public static func renderCutoutProofPNG(size: CGSize) -> Data? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let bounds = CGRect(origin: .zero, size: size)
        let host = CALayer()
        host.frame = bounds
        host.contentsScale = scale

        let standIn = CALayer()
        standIn.frame = bounds
        standIn.backgroundColor = NSColor.red.cgColor
        host.addSublayer(standIn)

        applyCutout(to: host, in: bounds)

        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                  data: nil,
                  width: pixelWidth,
                  height: pixelHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        host.render(in: context)
        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }

    public struct CutoutConfig: Codable {
        public struct Hole: Codable {
            public var widthFraction: CGFloat
            public var heightFraction: CGFloat
            public var centerYFraction: CGFloat
            public var centerXFraction: CGFloat

            enum CodingKeys: String, CodingKey {
                case widthFraction, heightFraction, centerYFraction, centerXFraction
            }

            public init(
                widthFraction: CGFloat,
                heightFraction: CGFloat,
                centerYFraction: CGFloat,
                centerXFraction: CGFloat = 0.5
            ) {
                self.widthFraction = widthFraction
                self.heightFraction = heightFraction
                self.centerYFraction = centerYFraction
                self.centerXFraction = centerXFraction
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                widthFraction = try c.decode(CGFloat.self, forKey: .widthFraction)
                heightFraction = try c.decode(CGFloat.self, forKey: .heightFraction)
                centerYFraction = try c.decode(CGFloat.self, forKey: .centerYFraction)
                centerXFraction = try c.decodeIfPresent(CGFloat.self, forKey: .centerXFraction) ?? 0.5
            }
        }
        public struct Circle: Codable {
            public var radiusFraction: CGFloat
            public var centerYFraction: CGFloat
            public var centerXFraction: CGFloat

            enum CodingKeys: String, CodingKey {
                case radiusFraction, centerYFraction, centerXFraction
            }

            public init(
                radiusFraction: CGFloat,
                centerYFraction: CGFloat,
                centerXFraction: CGFloat = 0.5
            ) {
                self.radiusFraction = radiusFraction
                self.centerYFraction = centerYFraction
                self.centerXFraction = centerXFraction
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                radiusFraction = try c.decode(CGFloat.self, forKey: .radiusFraction)
                centerYFraction = try c.decode(CGFloat.self, forKey: .centerYFraction)
                centerXFraction = try c.decodeIfPresent(CGFloat.self, forKey: .centerXFraction) ?? 0.5
            }
        }
        /// A hole the user dragged onto the lock-screen picture.
        public struct Shape: Codable, Equatable {
            public enum Kind: String, Codable { case rect, circle }

            public var kind: Kind
            public var widthFraction: CGFloat
            public var heightFraction: CGFloat
            public var centerYFraction: CGFloat
            public var centerXFraction: CGFloat

            public init(
                kind: Kind,
                widthFraction: CGFloat,
                heightFraction: CGFloat,
                centerYFraction: CGFloat,
                centerXFraction: CGFloat
            ) {
                self.kind = kind
                self.widthFraction = widthFraction
                self.heightFraction = heightFraction
                self.centerYFraction = centerYFraction
                self.centerXFraction = centerXFraction
            }
        }

        public var clock: Hole
        public var avatar: Circle?
        public var login: Hole
        /// Present only after the editor has saved a shape list, including an empty one.
        public var shapes: [Shape]
        public var shapesExplicit: Bool

        public init(clock: Hole, avatar: Circle?, login: Hole, shapes: [Shape] = [], shapesExplicit: Bool = false) {
            self.clock = clock
            self.avatar = avatar
            self.login = login
            self.shapes = shapes
            self.shapesExplicit = shapesExplicit
        }

        enum CodingKeys: String, CodingKey {
            case clock, avatar, login, shapes
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            clock = try c.decode(Hole.self, forKey: .clock)
            avatar = try c.decodeIfPresent(Circle.self, forKey: .avatar)
            login = try c.decode(Hole.self, forKey: .login)
            if c.contains(.shapes) {
                shapes = try c.decode([Shape].self, forKey: .shapes)
                shapesExplicit = true
            } else {
                shapes = []
                shapesExplicit = false
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(clock, forKey: .clock)
            try c.encodeIfPresent(avatar, forKey: .avatar)
            try c.encode(login, forKey: .login)
            if shapesExplicit {
                try c.encode(shapes, forKey: .shapes)
            }
        }

        public static func defaults() -> CutoutConfig {
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
        loadCutout()
    }

    public static var cutoutConfigFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Motionpaper/lockscreen-cutout.json")
    }

    public static func loadCutout() -> CutoutConfig {
        let path = cutoutConfigFileURL
        if let data = try? Data(contentsOf: path),
           let config = try? JSONDecoder().decode(CutoutConfig.self, from: data) {
            return config
        }
        let defaults = CutoutConfig.defaults()
        saveCutout(defaults)
        return defaults
    }

    public static func saveCutout(_ config: CutoutConfig) {
        let path = cutoutConfigFileURL
        let folder = path.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(config) {
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

// MARK: - Overlay content (host layer + masked video sublayer)

@MainActor
private final class LockOverlayContentView: NSView {
    private let hostLayer = CALayer()
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // makeBackingLayer runs only after the view is layer-backed.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        hostLayer.backgroundColor = NSColor.clear.cgColor
        hostLayer.addSublayer(playerLayer)
        return hostLayer
    }

    override func layout() {
        super.layout()
        syncCutoutAndPlayerFrame()
    }

    func syncCutoutAndPlayerFrame() {
        guard let host = layer else { return }
        playerLayer.frame = host.bounds
        LockScreenOverlay.applyCutout(to: host, in: bounds)
    }
}

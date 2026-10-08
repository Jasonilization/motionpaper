import AppKit
import AVFoundation
import Foundation

/// A borderless window that sits at the macOS desktop level, playing a looping
/// video via AVFoundation — behind desktop icons, across all Spaces, never
/// receiving focus or mouse events.
///
/// Main-actor isolated: NSWindow/AVPlayer work happens on the main thread and
/// the engine only calls in from the main actor.
@MainActor
public final class WallpaperWindowController: NSObject {

    public enum PlaybackState: Equatable, Sendable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    public let displayKey: String
    public private(set) var state: PlaybackState = .idle {
        didSet { onStateChange?(displayKey, state) }
    }

    public var onStateChange: ((String, PlaybackState) -> Void)?

    public private(set) var window: NSWindow?
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var playerLayer: AVPlayerLayer?
    private var spriteLayer: CALayer?
    private var statusObservation: NSKeyValueObservation?
    public private(set) var currentWallpaperID: UUID?

    /// The queue player driving this surface — exposed so the in-app preview can
    /// attach to the same player (no duplicated decode for the active wallpaper).
    public var sharedPlayer: AVPlayer { player }

    // MARK: - Sprite-sheet playback

    /// Plays a PNG sprite sheet as an infinitely looping Core Animation —
    /// GPU-composited, no per-frame CPU work after slicing.
    public func playSpriteSheet(url: URL, wallpaperID: UUID, sprite: Wallpaper.SpriteMetadata, scaling: ScalingMode) {
        currentWallpaperID = wallpaperID
        // Stop any video playback and detach the player layer.
        looper = nil
        statusObservation?.invalidate()
        statusObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        playerLayer?.isHidden = true

        do {
            let image = try SpriteSheetRenderer.loadImage(at: url)
            let frames = try SpriteSheetRenderer.slice(image: image, columns: sprite.columns, rows: sprite.rows)
            guard let layer = spriteLayer,
                  let animation = SpriteSheetRenderer.loopingAnimation(frames: frames, framesPerSecond: sprite.framesPerSecond) else {
                state = .failed("Sprite sheet couldn't be animated")
                return
            }
            layer.removeAnimation(forKey: "spriteLoop")
            layer.isHidden = false
            layer.contents = frames.first
            layer.contentsGravity = scaling.spriteContentsGravity
            layer.add(animation, forKey: "spriteLoop")
            updateLayerFrames()
            state = .playing
        } catch {
            state = .failed(error.localizedDescription)
            AppLog.renderer.error("Sprite sheet failed on \(self.displayKey, privacy: .public): \(error)")
        }
    }

    /// Switches sprite scaling (fill/fit/stretch) without reloading frames.
    public func applySpriteScaling(_ scaling: ScalingMode) {
        spriteLayer?.contentsGravity = scaling.spriteContentsGravity
    }

    public init(displayKey: String) {
        self.displayKey = displayKey
        super.init()
    }

    // MARK: - Window lifecycle

    /// Creates or reconfigures the desktop-level window for the given screen frame.
    public func show(onScreenFrame frame: CGRect) {
        if let window {
            window.setFrame(frame, display: true)
            updateLayerFrames()
        } else {
            let window = NSWindow(
                contentRect: frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.acceptsMouseMovedEvents = false
            window.hidesOnDeactivate = false
            window.collectionBehavior = [
                .canJoinAllSpaces,
                .stationary,
                .ignoresCycle,
                .fullScreenAuxiliary,
            ]
            window.isReleasedWhenClosed = false

            let contentView = NSView()
            contentView.wantsLayer = true
            let rootLayer = CALayer()
            contentView.layer = rootLayer

            let playerLayer = AVPlayerLayer()
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            rootLayer.addSublayer(playerLayer)

            let spriteLayer = CALayer()
            spriteLayer.contentsGravity = .resizeAspectFill
            spriteLayer.isHidden = true
            rootLayer.addSublayer(spriteLayer)

            window.contentView = contentView
            self.spriteLayer = spriteLayer

            self.window = window
            self.playerLayer = playerLayer
            window.orderFrontRegardless()
            updateLayerFrames()
        }
    }

    private func updateLayerFrames() {
        guard let bounds = window?.contentView?.bounds else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer?.frame = bounds
        spriteLayer?.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Playback

    /// Loads a wallpaper and starts looping playback. A failing/unloadable file
    /// transitions to `.failed` instead of crashing anything.
    public func play(url: URL, wallpaperID: UUID, scaling: ScalingMode, muted: Bool, volume: Double, startPosition: Double = 0) {
        currentWallpaperID = wallpaperID
        // Hide any sprite-sheet surface from a previous assignment.
        spriteLayer?.removeAnimation(forKey: "spriteLoop")
        spriteLayer?.isHidden = true
        playerLayer?.isHidden = false
        apply(scaling: scaling, muted: muted, volume: volume)

        looper = nil
        statusObservation?.invalidate()

        let item = AVPlayerItem(url: url)
        // The wallpaper must never keep the display or system awake.
        player.preventsDisplaySleepDuringVideoPlayback = false

        statusObservation = item.observe(\.status) { [weak self] observedItem, _ in
            // Extract Sendable values here; hop to the main actor below.
            let status = observedItem.status
            let errorDescription = observedItem.error?.localizedDescription
            Task { @MainActor [weak self] in
                self?.handleItemStatus(status, errorDescription: errorDescription)
            }
        }
        looper = AVPlayerLooper(player: player, templateItem: item)
        state = .loading
        player.play()
        if startPosition > 1 {
            player.seek(to: CMTime(seconds: startPosition, preferredTimescale: 600))
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status, errorDescription: String?) {
        guard state != .idle, state != .paused else { return }
        switch status {
        case .readyToPlay:
            state = .playing
        case .failed:
            let reason = errorDescription ?? "Video could not be played"
            state = .failed(reason)
            AppLog.renderer.error("Wallpaper failed on \(self.displayKey, privacy: .public): \(reason)")
        default:
            break
        }
    }

    public func apply(scaling: ScalingMode, muted: Bool, volume: Double) {
        playerLayer?.videoGravity = scaling.avVideoGravity
        applySpriteScaling(scaling)
        player.isMuted = muted
        player.volume = Float(max(0, min(volume, 1)))
    }

    public func pause() {
        guard state == .playing || state == .loading || state == .paused else { return }
        player.pause()
        state = .paused
    }

    public func resume() {
        guard state == .paused else { return }
        player.play()
        state = .playing
    }

    public func close() {
        statusObservation?.invalidate()
        statusObservation = nil
        looper?.disableLooping()
        looper = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        spriteLayer?.removeAnimation(forKey: "spriteLoop")
        spriteLayer?.isHidden = true
        window?.orderOut(nil)
        window = nil
        playerLayer = nil
        spriteLayer = nil
        currentWallpaperID = nil
        state = .idle
    }
}

extension ScalingMode {
    var avVideoGravity: AVLayerVideoGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .stretch: .resize
        case .fit: .resizeAspect
        }
    }

    public var spriteContentsGravity: CALayerContentsGravity {
        switch self {
        case .fill: .resizeAspectFill
        case .stretch: .resize
        case .fit: .resizeAspect
        }
    }
}

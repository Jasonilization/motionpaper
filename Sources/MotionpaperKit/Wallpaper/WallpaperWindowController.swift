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
    private var statusObservation: NSKeyValueObservation?
    public private(set) var currentWallpaperID: UUID?

    /// The queue player driving this surface — exposed so the in-app preview can
    /// attach to the same player (no duplicated decode for the active wallpaper).
    public var sharedPlayer: AVPlayer { player }

    public init(displayKey: String) {
        self.displayKey = displayKey
        super.init()
    }

    // MARK: - Window lifecycle

    /// Creates or reconfigures the desktop-level window for the given screen frame.
    public func show(onScreenFrame frame: CGRect) {
        if let window {
            window.setFrame(frame, display: true)
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
            let layer = AVPlayerLayer()
            layer.player = player
            layer.videoGravity = .resizeAspectFill
            contentView.layer = layer
            window.contentView = contentView

            self.window = window
            self.playerLayer = layer
            window.orderFrontRegardless()
        }
    }

    // MARK: - Playback

    /// Loads a wallpaper and starts looping playback. A failing/unloadable file
    /// transitions to `.failed` instead of crashing anything.
    public func play(url: URL, wallpaperID: UUID, scaling: ScalingMode, muted: Bool, volume: Double, startPosition: Double = 0) {
        currentWallpaperID = wallpaperID
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
        window?.orderOut(nil)
        window = nil
        playerLayer = nil
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
}

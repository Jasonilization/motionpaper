import AVKit
import AVFoundation
import AppKit
import MotionpaperKit

// MARK: - Video preview window (AVKit, pure AppKit)

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    let store: AppStore
    let window: NSWindow
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerView = AVPlayerView()
    private var wallpaper: Wallpaper
    private var speedPopup: NSPopUpButton?

    private static let speeds: [Float] = [0.5, 1, 1.5, 2]

    init(store: AppStore, wallpaper: Wallpaper) {
        self.store = store
        self.wallpaper = wallpaper

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 460),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = wallpaper.name
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 300)

        playerView.controlsStyle = .floating
        playerView.player = player
        window.contentView = playerView

        super.init()

        window.delegate = self
        window.center()

        let toolbar = NSToolbar(identifier: "motionpaper-preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar

        startPlayback()
    }

    private func startPlayback() {
        guard let url = store.library.fileURL(for: wallpaper) else {
            let alert = NSAlert()
            alert.messageText = "Can't preview"
            alert.informativeText = "The backing file for this wallpaper is missing."
            alert.runModal()
            return
        }
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        player.pause()
        return true
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.previewSpeed, .flexibleSpace, .previewApply]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.previewSpeed, .flexibleSpace, .previewApply]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .previewSpeed:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Speed"
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 70, height: 24), pullsDown: false)
            popup.bezelStyle = .rounded
            popup.controlSize = .small
            for speed in Self.speeds {
                popup.addItem(withTitle: speed == Float(1) ? "1×" : "\(speed)×")
            }
            popup.selectItem(at: 1)
            popup.target = self
            popup.action = #selector(speedChanged(_:))
            item.view = popup
            return item
        case .previewApply:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Apply as Wallpaper"
            item.paletteLabel = "Apply"
            item.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Apply")
            item.isBordered = true
            item.target = self
            item.action = #selector(applyClicked)
            return item
        default:
            return nil
        }
    }

    @objc private func speedChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < Self.speeds.count else { return }
        player.rate = Self.speeds[index]
    }

    @objc private func applyClicked() {
        store.engine.applyToAllDisplays(wallpaperID: wallpaper.id)
    }
}

extension NSToolbarItem.Identifier {
    static let previewSpeed = NSToolbarItem.Identifier("motionpaper.preview.speed")
    static let previewApply = NSToolbarItem.Identifier("motionpaper.preview.apply")
}

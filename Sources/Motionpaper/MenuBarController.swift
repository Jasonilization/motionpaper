import AppKit
import MotionpaperKit
import SwiftUI

/// The menu-bar quick-control surface. Rebuilt on every open (delegate pattern)
/// so it always reflects current engine state without polling.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var store: AppStore?

    func attach(store: AppStore) {
        self.store = store
        // Only create the NSStatusItem when the user explicitly enables it.
        // On macOS 27.0 betas, MenuBarClientCore (the system's own framework)
        // crashes the process through broken concurrency-runtime executor
        // checks — even with the icon hidden, the object's existence triggers it.
        if store.settings.values.showMenuBarIcon {
            updateVisibility(true)
        }
    }

    func updateVisibility(_ visible: Bool) {
        if visible {
            guard statusItem == nil else { return }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.image = NSImage(systemSymbolName: "rectangle.on.rectangle.fill", accessibilityDescription: "Motionpaper")
            item.button?.toolTip = "Motionpaper — live wallpapers"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        } else {
            if let statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
            statusItem = nil
        }
    }

    // MARK: - Menu construction (on open)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let store else { return }
        menu.removeAllItems()

        // Current state header.
        for display in store.engine.displays {
            menu.addItem(displayMenuItem(display))
        }
        menu.addItem(.separator())

        // Quick controls.
        let pauseTitle = store.engine.userPaused ? "Resume" : "Pause"
        let pauseItem = NSMenuItem(
            title: pauseTitle,
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pauseItem.target = self
        if let reason = store.resource.pauseSummary {
            pauseItem.toolTip = reason
        }
        menu.addItem(pauseItem)

        addSimpleItem(menu, title: "Next Wallpaper", action: #selector(nextWallpaper))
        addSimpleItem(menu, title: "Previous Wallpaper", action: #selector(previousWallpaper))
        addSimpleItem(menu, title: "Reapply Wallpapers", action: #selector(reapply))
        menu.addItem(.separator())

        // Favorites & recents (apply via submenu per display).
        addWallpaperListSection(
            menu: menu,
            title: "Favorites",
            wallpapers: store.library.favoriteWallpapers.prefix(8)
        )
        addWallpaperListSection(
            menu: menu,
            title: "Recent",
            wallpapers: store.library.recentWallpapers.prefix(5)
        )
        menu.addItem(.separator())

        addSimpleItem(menu, title: "Open Library", action: #selector(openLibrary))
        addSimpleItem(menu, title: "Settings…", action: #selector(openSettings))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Motionpaper", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    // MARK: - Items

    private func addSimpleItem(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func displayMenuItem(_ display: DisplayInfo) -> NSMenuItem {
        guard let store else { return NSMenuItem(title: display.name, action: nil, keyEquivalent: "") }
        let assignment = store.library.assignment(displayKey: display.id)
        let wallpaperName = assignment?.wallpaperID.flatMap { store.library.wallpaper(id: $0)?.name } ?? "No wallpaper"

        let item = NSMenuItem(title: "\(display.name): \(wallpaperName)", action: nil, keyEquivalent: "")
        item.isEnabled = true

        if let image = menuThumbnail(for: assignment?.wallpaperID) {
            item.image = image
        } else {
            item.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
        }

        let submenu = NSMenu()
        if let wallpaperID = assignment?.wallpaperID {
            let reapply = NSMenuItem(title: "Reapply", action: #selector(reapplyOnDisplay(_:)), keyEquivalent: "")
            reapply.target = self
            reapply.representedObject = display.id
            submenu.addItem(reapply)
            let clear = NSMenuItem(title: "Remove from Display", action: #selector(clearDisplay(_:)), keyEquivalent: "")
            clear.target = self
            clear.representedObject = display.id
            submenu.addItem(clear)
            submenu.addItem(.separator())
        }
        let choose = NSMenuItem(title: "Open Library to Change…", action: #selector(openLibrary), keyEquivalent: "")
        choose.target = self
        submenu.addItem(choose)
        item.submenu = submenu
        return item
    }

    private func menuThumbnail(for wallpaperID: UUID?) -> NSImage? {
        guard let store, let id = wallpaperID,
              let wallpaper = store.library.wallpaper(id: id) else { return nil }
        let url = store.paths.thumbnailURL(for: wallpaper.id)
        guard let image = NSImage(contentsOf: url) else { return nil }
        let target = NSSize(width: 16, height: 16)
        image.size = target
        return image
    }

    private func addWallpaperListSection(menu: NSMenu, title: String, wallpapers: some Sequence<Wallpaper>) {
        guard let store else { return }
        var items: [Wallpaper] = []
        for wallpaper in wallpapers { items.append(wallpaper) }
        guard !items.isEmpty else { return }

        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for wallpaper in items.prefix(8) {
            let item = NSMenuItem(title: wallpaper.name, action: nil, keyEquivalent: "")
            if let image = menuThumbnail(for: wallpaper.id) {
                item.image = image
            }
            let submenu = NSMenu()
            for display in store.engine.displays {
                let apply = NSMenuItem(
                    title: "Apply to \(display.name)",
                    action: #selector(applyToDisplay(_:)),
                    keyEquivalent: ""
                )
                apply.target = self
                apply.representedObject = DisplayAction(displayKey: display.id, wallpaperID: wallpaper.id)
                submenu.addItem(apply)
            }
            item.submenu = submenu
            menu.addItem(item)
        }
    }

    private struct DisplayAction {
        let displayKey: String
        let wallpaperID: UUID
    }

    // MARK: - Actions

    @objc private func togglePause() { store?.engine.toggleUserPause() }
    @objc private func nextWallpaper() { store?.engine.nextWallpaper() }
    @objc private func previousWallpaper() { store?.engine.previousWallpaper() }
    @objc private func reapply() { store?.engine.recreateAllSurfaces() }
    @objc private func openLibrary() {
        NSApp.activate(ignoringOtherApps: true)
        let candidate = NSApp.windows.first { $0.title == "Motionpaper" && $0.canBecomeMain }
        if let window = candidate {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(self)
        }
    }
    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func applyToDisplay(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DisplayAction else { return }
        store?.engine.apply(wallpaperID: action.wallpaperID, toDisplay: action.displayKey)
    }

    @objc private func reapplyOnDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store?.engine.reapply(displayKey: key)
    }

    @objc private func clearDisplay(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        store?.engine.clear(displayKey: key)
    }
}

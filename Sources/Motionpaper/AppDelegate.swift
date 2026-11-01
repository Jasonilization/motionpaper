import AppKit
import MotionpaperKit

// Pure AppKit entry point — no SwiftUI, no broken concurrency runtime
// machinery, no hosting-view hit-testing. The same code path every stable
// Mac app uses.

@main
struct MotionpaperMain {
    @MainActor
    static func main() {
        // Exactly one instance: the keepalive relaunch and a user `open`
        // can race. The loser activates the winner and exits cleanly.
        guard SingleInstanceLock.tryAcquire() else {
            SingleInstanceLock.activateExistingInstance()
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = AppStore()
    private var mainWindowController: MainWindowController?
    private var settingsWindowController: SettingsWindowController?
    private var cutEditor: LockScreenCutEditorController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Defensive AppKit-level patch for the macOS 27.0 beta (the pressure
        // latch only). The SwiftUI responder-walk patches are obsolete now
        // that no SwiftUI views exist in the app.
        ClickCrashFix.install()

        buildMainMenu()

        // Crash-loop recovery bookkeeping (self-pauses the menu-bar icon if
        // Apple's MenuBarClientCore beta bug keeps killing us).
        CrashRecovery.recordLaunch()

        store.startEngine()
        store.menuBar.attach(store: store)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettingsRequested),
            name: .openSettings,
            object: nil
        )

        mainWindowController = MainWindowController(store: store)
        mainWindowController?.showWindow()

        if store.settings.values.startInBackground {
            mainWindowController?.window.orderOut(nil)
        } else {
            cutEditor = LockScreenCutEditorController()
            cutEditor?.present()
        }

        scheduleUISnapshotIfRequested()
        CrashRecovery.presentCooldownNoticeIfNeeded()
    }

    /// Debug/self-test facility: `--ui-snapshot <path>` renders the main
    /// window's content view to a PDF a few seconds after launch (after
    /// thumbnails load), so the UI can be verified headlessly.
    private var snapshotTimer: Timer?

    private func scheduleUISnapshotIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--ui-snapshot"),
              index + 1 < arguments.count else { return }
        let path = arguments[index + 1]
        trace("ui-snapshot scheduled for: \(path)")
        // Timer-with-closure on the main runloop — the pattern proven to run
        // in this environment (see LockWatchdog's isolation notes).
        snapshotTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            self?.writeUISnapshot(to: path)
        }
    }

    private func writeUISnapshot(to path: String) {
        trace("ui-snapshot: begin")
        guard let window = mainWindowController?.window else {
            trace("ui-snapshot: no window")
            return
        }
        guard let contentView = window.contentView else {
            trace("ui-snapshot: no content view")
            return
        }
        // The previous PDF path missed every layer-backed view, so the library
        // grid (thumbnails, labels, empty state) came out as a black rectangle.
        // Force Library, then render the layer tree into a PNG.
        mainWindowController?.sidebarController.selectSection(.library)
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bounds = contentView.bounds
        trace("ui-snapshot: rendering, bounds=\(bounds)")
        guard let data = Self.bitmapPNG(of: contentView) else {
            trace("ui-snapshot: bitmap render failed")
            return
        }
        let requested = URL(fileURLWithPath: path)
        let destination = requested.pathExtension.lowercased() == "png"
            ? requested
            : requested.deletingPathExtension().appendingPathExtension("png")
        do {
            try data.write(to: destination)
            trace("ui-snapshot: written to \(destination.path) bytes=\(data.count)")
        } catch {
            trace("ui-snapshot: write failed: \(error)")
        }
    }

    /// Renders a layer-backed view, including collection-view thumbnails, which
    /// `dataWithPDF(inside:)` skips.
    private static func bitmapPNG(of view: NSView) -> Data? {
        let bounds = view.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = view.window?.backingScaleFactor ?? 2
        let pixelsWide = max(Int((bounds.width * scale).rounded()), 1)
        let pixelsHigh = max(Int((bounds.height * scale).rounded()), 1)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        rep.size = bounds.size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = graphics
        if let layer = view.layer {
            layer.render(in: graphics.cgContext)
        } else {
            view.displayIgnoringOpacity(bounds, in: graphics)
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func trace(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // the wallpaper engine keeps running without windows
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindowController?.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.library.saveNow()
        store.settings.saveNow()
    }

    // MARK: - Settings

    /// Reached from the app menu (Cmd-,), the menu bar item (via the
    /// `showSettingsWindow:` responder-chain action), and the sidebar button.
    @objc func showSettingsWindow(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(store: store)
        }
        settingsWindowController?.showWindow()
    }

    @objc private func openSettingsRequested() {
        showSettingsWindow(nil)
    }

    // MARK: - Actions

    @objc private func importVideos(_ sender: Any?) {
        mainWindowController?.presentImportPanel()
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "Motionpaper")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Motionpaper", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindow(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Motionpaper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Motionpaper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        fileMenu.addItem(withTitle: "Import Videos…", action: #selector(importVideos(_:)), keyEquivalent: "i")
        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(fileMenuItem)

        // Edit menu (standard responders — needed by text fields)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenuItem.submenu = editMenu
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        viewMenu.addItem(withTitle: "Show Toolbar", action: #selector(NSWindow.toggleToolbarShown(_:)), keyEquivalent: "t")
        viewMenu.addItem(withTitle: "Customize Toolbar…", action: #selector(NSWindow.runToolbarCustomizationPalette(_:)), keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)

        // Window menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

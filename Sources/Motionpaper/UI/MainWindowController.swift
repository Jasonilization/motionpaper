import AppKit
import MotionpaperKit

@MainActor
final class MainWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate, NSSearchFieldDelegate {
    let store: AppStore
    let window: NSWindow
    let sidebarController: SidebarViewController
    let contentController: ContentContainerViewController
    private let splitViewController: NSSplitViewController

    private static let toolbarIdentifiers: [NSToolbarItem.Identifier] = [
        .importVideos, .flexibleSpace, .searchToolbar, .sortToolbar, .filterToolbar
    ]

    init(store: AppStore) {
        self.store = store

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Motionpaper"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)

        sidebarController = SidebarViewController(store: store)
        contentController = ContentContainerViewController(store: store)
        splitViewController = NSSplitViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        sidebarItem.canCollapse = false
        splitViewController.addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentController)
        contentItem.canCollapse = false
        splitViewController.addSplitViewItem(contentItem)

        window.contentViewController = splitViewController

        super.init()

        window.delegate = self
        _ = window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") {
            window.center()
        }

        let toolbar = NSToolbar(identifier: "motionpaper-main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar

        sidebarController.onSelect = { [weak self] section in
            self?.contentController.show(section: section)
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleLibraryChange), name: .libraryDidChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleOpenLibrary), name: .openLibrary, object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleActivateRequest),
            name: Notification.Name(SingleInstanceLock.activateNotificationName),
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func showWindow() {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Import

    func presentImportPanel() {
        MPUI.presentVideoImportPanel(store: store)
    }

    // MARK: - Notification handlers

    @objc private func handleLibraryChange() {
        contentController.libraryController.refresh()
        contentController.refreshCurrent()
    }

    @objc private func handleOpenLibrary() {
        sidebarController.selectSection(.library)
        showWindow()
    }

    /// A second instance asked us to come to the front.
    @objc private func handleActivateRequest() {
        showWindow()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Hide instead of close — the wallpaper engine keeps running.
        sender.orderOut(nil)
        return false
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.toolbarIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case .importVideos:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Import"
            item.paletteLabel = "Import"
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Import videos")
            item.isBordered = true
            item.target = self
            item.action = #selector(importClicked)
            return item

        case .searchToolbar:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.delegate = self
            item.searchField.placeholderString = "Search wallpapers"
            return item

        case .sortToolbar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Sort"
            item.view = makeSortPopup()
            return item

        case .filterToolbar:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "Filter"
            item.view = makeFilterPopup()
            return item

        default:
            return nil
        }
    }

    private func makeSortPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 26), pullsDown: false)
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        for option in SortOption.allCases {
            popup.addItem(withTitle: option.label)
        }
        popup.selectItem(at: SortOption.allCases.firstIndex(of: contentController.libraryController.sortOption) ?? 0)
        popup.target = self
        popup.action = #selector(sortChanged(_:))
        return popup
    }

    private func makeFilterPopup() -> NSPopUpButton {
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26), pullsDown: false)
        popup.bezelStyle = .rounded
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 12)
        popup.addItem(withTitle: FilterTitles.all)
        popup.addItem(withTitle: FilterTitles.best1080)
        popup.addItem(withTitle: FilterTitles.fourK)
        popup.addItem(withTitle: FilterTitles.portrait)
        popup.addItem(withTitle: FilterTitles.landscape)
        popup.target = self
        popup.action = #selector(filterChanged(_:))
        return popup
    }

    // MARK: - Toolbar actions

    @objc private func importClicked() {
        presentImportPanel()
    }

    @objc private func sortChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < SortOption.allCases.count else { return }
        sidebarController.selectSection(.library)
        contentController.libraryController.sortOption = SortOption.allCases[index]
        contentController.libraryController.refresh()
    }

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        sidebarController.selectSection(.library)
        contentController.libraryController.filterText = sender.titleOfSelectedItem ?? FilterTitles.all
        contentController.libraryController.refresh()
    }

    // MARK: - NSTextFieldDelegate (live search)

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        sidebarController.selectSection(.library)
        contentController.libraryController.searchText = field.stringValue
        contentController.libraryController.refresh()
    }
}

// MARK: - Toolbar identifiers

extension NSToolbarItem.Identifier {
    static let importVideos = NSToolbarItem.Identifier("motionpaper.import")
    static let searchToolbar = NSToolbarItem.Identifier("motionpaper.search")
    static let sortToolbar = NSToolbarItem.Identifier("motionpaper.sort")
    static let filterToolbar = NSToolbarItem.Identifier("motionpaper.filter")
}

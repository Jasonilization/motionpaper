import AppKit
import MotionpaperKit

// MARK: - Sidebar

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let store: AppStore
    var onSelect: ((SidebarSection) -> Void)?

    private var outlineView: NSOutlineView!

    private struct Row {
        let title: String
        let symbol: String
        let section: SidebarSection
    }

    private let rows: [Row] = [
        Row(title: "Home", symbol: "house", section: .home),
        Row(title: "Library", symbol: "square.grid.2x2", section: .library),
        Row(title: "Favorites", symbol: "star", section: .favorites),
        Row(title: "Playlists", symbol: "arrow.triangle.2.circlepath", section: .playlists),
        Row(title: "Gallery", symbol: "photo.on.rectangle", section: .gallery),
        Row(title: "Displays", symbol: "display.2", section: .displays),
    ]

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.frame = NSRect(x: 0, y: 0, width: 220, height: 600)

        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.selectionHighlightStyle = .sourceList
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .medium

        let scrollView = NSScrollView()
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)

        let settingsButton = NSButton(title: "Settings…", target: self, action: #selector(settingsClicked))
        settingsButton.bezelStyle = .texturedRounded
        settingsButton.font = .systemFont(ofSize: 13)
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageLeading
        settingsButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(settingsButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -8),

            settingsButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            settingsButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            settingsButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        view = container
        outlineView = outline

        selectSection(.library)
    }

    func selectSection(_ section: SidebarSection) {
        loadViewIfNeeded()
        guard let index = rows.firstIndex(where: { $0.section == section }) else { return }
        outlineView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    @objc private func settingsClicked() {
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? rows.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        rows[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        false
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? Row else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("SidebarCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? Self.makeCell(identifier: identifier)
        cell.textField?.stringValue = row.title
        cell.imageView?.image = NSImage(systemSymbolName: row.symbol, accessibilityDescription: row.title)
        return cell
    }

    private static func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        cell.imageView = imageView
        cell.addSubview(imageView)

        let textField = NSTextField(labelWithString: "")
        textField.font = .systemFont(ofSize: 13, weight: .medium)
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = textField
        cell.addSubview(textField)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outlineView.selectedRow
        guard row >= 0, row < rows.count else { return }
        onSelect?(rows[row].section)
    }
}

// MARK: - Content container

@MainActor
final class ContentContainerViewController: NSViewController {
    let store: AppStore
    let libraryController: LibraryGridController
    private let homeController: HomeViewController
    private let playlistsController: PlaylistsViewController
    private let displaysController: DisplaysViewController
    private let galleryController: GalleryViewController
    private var currentChild: NSViewController?
    private(set) var currentSection: SidebarSection = .library

    init(store: AppStore) {
        self.store = store
        libraryController = LibraryGridController(store: store)
        homeController = HomeViewController(store: store)
        playlistsController = PlaylistsViewController(store: store)
        displaysController = DisplaysViewController(store: store)
        galleryController = GalleryViewController(store: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView()
        view.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
        show(section: .library)
    }

    func show(section: SidebarSection) {
        currentSection = section

        let child: NSViewController
        switch section {
        case .home: child = homeController
        case .library, .favorites: child = libraryController
        case .playlists: child = playlistsController
        case .gallery: child = galleryController
        case .displays: child = displaysController
        }

        if currentChild !== child {
            currentChild?.view.removeFromSuperview()
            child.view.frame = view.bounds
            child.view.autoresizingMask = [.width, .height]
            view.addSubview(child.view)
            currentChild = child
        }

        switch section {
        case .home:
            homeController.refresh()
        case .library, .favorites:
            libraryController.showFavoritesOnly = (section == .favorites)
            libraryController.refresh()
        case .playlists:
            playlistsController.refresh()
        case .gallery:
            galleryController.refresh()
        case .displays:
            displaysController.refresh()
        }
    }

    /// Refreshes whichever section is currently on screen.
    func refreshCurrent() {
        show(section: currentSection)
    }
}

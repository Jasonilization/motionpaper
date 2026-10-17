import AppKit
import MotionpaperKit

// MARK: - Collection view with context menu + double-click support

@MainActor
final class LibraryCollectionView: NSCollectionView {
    var contextMenuProvider: ((_ indexPath: IndexPath) -> NSMenu?)?
    var backgroundMenuProvider: (() -> NSMenu?)?
    var doubleClickHandler: ((_ indexPath: IndexPath) -> Void)?
    var spaceKeyHandler: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " {
            spaceKeyHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else {
            return backgroundMenuProvider?()
        }
        // Right-clicking an unselected item selects it first (Finder behavior).
        if !selectionIndexPaths.contains(indexPath) {
            selectItems(at: [indexPath], scrollPosition: [])
        }
        return contextMenuProvider?(indexPath)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount >= 2 else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return }
        doubleClickHandler?(indexPath)
    }
}

// MARK: - Scroll view that accepts file drops (drag-and-drop import)

@MainActor
final class DropScrollView: NSScrollView {
    var onFilesDropped: (([URL]) -> Void)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(sender).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggedFileURLs(sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = draggedFileURLs(sender)
        guard !urls.isEmpty else { return false }
        onFilesDropped?(urls)
        return true
    }

    private func draggedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }
}

// MARK: - Empty state

@MainActor
final class EmptyStateView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        iconView.image = NSImage(systemSymbolName: "film.stack", accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .tertiaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .center
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 48),
            iconView.heightAnchor.constraint(equalToConstant: 48),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 14),
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            bottomAnchor.constraint(equalTo: messageLabel.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(favoritesOnly: Bool, searching: Bool) {
        if searching {
            titleLabel.stringValue = "No matches"
            messageLabel.stringValue = "Nothing matches your search. Try a different term."
        } else if favoritesOnly {
            titleLabel.stringValue = "No favorites"
            messageLabel.stringValue = "Right-click a wallpaper in the Library and choose “Add to Favorites”."
        } else {
            titleLabel.stringValue = "No wallpapers yet"
            messageLabel.stringValue = "Drag videos anywhere onto this area, or use the Import button."
        }
    }
}

// MARK: - Library grid controller

@MainActor
final class LibraryGridController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let store: AppStore
    var searchText = ""
    var sortOption: SortOption = .dateAddedDesc
    var filterText = FilterTitles.all
    var showFavoritesOnly = false

    private var collectionView: LibraryCollectionView!
    private var wallpapers: [Wallpaper] = []
    private var emptyState: EmptyStateView?
    private var previewController: PreviewWindowController?

    private static let reuseIdentifier = NSUserInterfaceItemIdentifier("wallpaper")

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 240, height: 210)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)

        let collection = LibraryCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [NSColor.clear]
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = false
        collection.register(WallpaperCollectionViewItem.self, forItemWithIdentifier: Self.reuseIdentifier)
        collection.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        collection.autoresizingMask = [.width]

        let scroll = DropScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.registerForDraggedTypes([.fileURL])
        scroll.onFilesDropped = { [weak self] urls in
            guard let self else { return }
            Task { @MainActor in
                await self.store.importer.importFiles(urls, into: self.store.library, mode: .copy)
                self.refresh()
            }
        }

        collection.contextMenuProvider = { [weak self] indexPath in
            self?.menuForItem(at: indexPath)
        }
        collection.backgroundMenuProvider = { [weak self] in
            self?.backgroundMenu()
        }
        collection.doubleClickHandler = { [weak self] indexPath in
            self?.applyToAllDisplays(at: indexPath)
        }
        collection.spaceKeyHandler = { [weak self] in
            self?.previewSpacePressed()
        }

        view = scroll
        collectionView = collection

        refresh()
    }

    // MARK: - Data pipeline

    func refresh() {
        loadViewIfNeeded()

        var items = store.library.wallpapers

        if showFavoritesOnly {
            items = items.filter(\.isFavorite)
        }

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter { wallpaper in
                wallpaper.name.lowercased().contains(query)
                    || wallpaper.tags.contains { $0.lowercased().contains(query) }
            }
        }

        switch filterText {
        case FilterTitles.best1080: items = items.filter { $0.metadata.is1080pOrBetter }
        case FilterTitles.fourK: items = items.filter { $0.metadata.is4KOrBetter }
        case FilterTitles.portrait: items = items.filter { $0.metadata.orientation == .portrait }
        case FilterTitles.landscape: items = items.filter { $0.metadata.orientation == .landscape }
        default: break
        }

        switch sortOption {
        case .dateAddedDesc: items.sort { $0.addedAt > $1.addedAt }
        case .dateAddedAsc: items.sort { $0.addedAt < $1.addedAt }
        case .nameAsc: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .durationDesc: items.sort { ($0.metadata.duration ?? 0) > ($1.metadata.duration ?? 0) }
        case .resolutionDesc: items.sort { $0.metadata.shortEdge > $1.metadata.shortEdge }
        }

        wallpapers = items
        collectionView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        if wallpapers.isEmpty {
            if emptyState == nil {
                let empty = EmptyStateView()
                view.addSubview(empty)
                NSLayoutConstraint.activate([
                    empty.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                    empty.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
                ])
                emptyState = empty
            }
            emptyState?.configure(favoritesOnly: showFavoritesOnly, searching: !searchText.isEmpty)
            emptyState?.isHidden = false
        } else {
            emptyState?.isHidden = true
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        wallpapers.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.reuseIdentifier, for: indexPath) as! WallpaperCollectionViewItem
        if indexPath.item < wallpapers.count {
            let wallpaper = wallpapers[indexPath.item]
            item.configure(
                with: wallpaper,
                isActive: store.library.assignments.contains { $0.wallpaperID == wallpaper.id },
                store: store
            )
        }
        return item
    }

    // MARK: - NSCollectionViewDelegate

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        // Selection highlight is enough; actions happen via double-click or context menu.
    }

    // MARK: - Context menus

    private struct DisplayAction {
        let displayKey: String
        let wallpaperID: UUID
    }

    private struct PlaylistAction {
        let playlistID: UUID
        let wallpaperID: UUID
    }

    private func menuForItem(at indexPath: IndexPath) -> NSMenu? {
        guard indexPath.item < wallpapers.count else { return nil }
        let wallpaper = wallpapers[indexPath.item]
        let menu = NSMenu()

        // Preview
        let preview = NSMenuItem(title: "Preview", action: #selector(previewAction(_:)), keyEquivalent: "")
        preview.target = self
        preview.representedObject = wallpaper.id
        menu.addItem(preview)

        menu.addItem(.separator())

        // Apply
        let apply = NSMenuItem(title: "Apply", action: nil, keyEquivalent: "")
        let applySubmenu = NSMenu()
        for display in store.engine.displays {
            let item = NSMenuItem(title: "to \(display.name)", action: #selector(applyToDisplayAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = DisplayAction(displayKey: display.id, wallpaperID: wallpaper.id)
            applySubmenu.addItem(item)
        }
        if store.engine.displays.count > 1 {
            applySubmenu.addItem(.separator())
            let all = NSMenuItem(title: "to All Displays", action: #selector(applyToAllAction(_:)), keyEquivalent: "")
            all.target = self
            all.representedObject = wallpaper.id
            applySubmenu.addItem(all)
        }
        apply.submenu = applySubmenu
        menu.addItem(apply)

        // Playlists
        let playlistItem = NSMenuItem(title: "Add to Playlist", action: nil, keyEquivalent: "")
        let playlistSubmenu = NSMenu()
        for playlist in store.library.playlists {
            let item = NSMenuItem(title: playlist.name, action: #selector(addToPlaylistAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = PlaylistAction(playlistID: playlist.id, wallpaperID: wallpaper.id)
            playlistSubmenu.addItem(item)
        }
        playlistSubmenu.addItem(.separator())
        let newPlaylist = NSMenuItem(title: "New Playlist…", action: #selector(newPlaylistFromItem(_:)), keyEquivalent: "")
        newPlaylist.target = self
        newPlaylist.representedObject = wallpaper.id
        playlistSubmenu.addItem(newPlaylist)
        playlistItem.submenu = playlistSubmenu
        menu.addItem(playlistItem)

        menu.addItem(.separator())

        // Favorite
        let favoriteTitle = wallpaper.isFavorite ? "Remove from Favorites" : "Add to Favorites"
        let favorite = NSMenuItem(title: favoriteTitle, action: #selector(toggleFavoriteAction(_:)), keyEquivalent: "")
        favorite.target = self
        favorite.representedObject = wallpaper.id
        menu.addItem(favorite)

        // Rename
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameAction(_:)), keyEquivalent: "")
        rename.target = self
        rename.representedObject = wallpaper.id
        menu.addItem(rename)

        // Reveal
        let reveal = NSMenuItem(title: "Reveal in Finder", action: #selector(revealAction(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = wallpaper.id
        menu.addItem(reveal)

        menu.addItem(.separator())

        // Remove
        let remove = NSMenuItem(title: "Remove from Library…", action: #selector(removeAction(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = wallpaper.id
        menu.addItem(remove)

        return menu
    }

    private func backgroundMenu() -> NSMenu? {
        let menu = NSMenu()
        let importItem = NSMenuItem(title: "Import Videos…", action: #selector(importAction), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
        return menu
    }

    // MARK: - Preview

    private func preview(at indexPath: IndexPath) {
        guard indexPath.item < wallpapers.count else { return }
        previewController?.window.orderOut(nil)
        previewController = PreviewWindowController(store: store, wallpaper: wallpapers[indexPath.item])
        previewController?.showWindow()
    }

    private func previewSpacePressed() {
        guard let indexPath = collectionView.selectionIndexPaths.first else { return }
        preview(at: indexPath)
    }

    @objc private func previewAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = wallpapers.firstIndex(where: { $0.id == id }) else { return }
        preview(at: IndexPath(item: index, section: 0))
    }

    // MARK: - Menu actions

    @objc private func importAction() {
        MPUI.presentVideoImportPanel(store: store)
    }

    @objc private func applyToDisplayAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? DisplayAction else { return }
        store.engine.apply(wallpaperID: action.wallpaperID, toDisplay: action.displayKey)
        refresh()
    }

    @objc private func applyToAllAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.engine.applyToAllDisplays(wallpaperID: id)
        refresh()
    }

    private func applyToAllDisplays(at indexPath: IndexPath) {
        guard indexPath.item < wallpapers.count else { return }
        store.engine.applyToAllDisplays(wallpaperID: wallpapers[indexPath.item].id)
        refresh()
    }

    @objc private func addToPlaylistAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PlaylistAction,
              var playlist = store.library.playlist(id: action.playlistID) else { return }
        guard !playlist.wallpaperIDs.contains(action.wallpaperID) else { return }
        playlist.wallpaperIDs.append(action.wallpaperID)
        store.library.update(playlist)
    }

    @objc private func newPlaylistFromItem(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let wallpaperID = UUID(uuidString: idString) else { return }
        guard let name = MPUI.presentTextAlert(
            title: "New Playlist",
            message: "Add this wallpaper to a new playlist.",
            placeholder: "",
            confirmTitle: "Create"
        ) else { return }
        var playlist = store.library.createPlaylist(name: name)
        playlist.wallpaperIDs.append(wallpaperID)
        store.library.update(playlist)
    }

    @objc private func toggleFavoriteAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        store.library.toggleFavorite(id: id)
        refresh()
    }

    @objc private func renameAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let wallpaper = store.library.wallpaper(id: id) else { return }
        guard let name = MPUI.presentTextAlert(
            title: "Rename Wallpaper",
            message: "Enter a new name.",
            placeholder: wallpaper.name,
            confirmTitle: "Rename"
        ) else { return }
        store.library.rename(id: id, to: name)
        refresh()
    }

    @objc private func revealAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let wallpaper = store.library.wallpaper(id: id),
              let url = store.library.fileURL(for: wallpaper) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func removeAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let wallpaper = store.library.wallpaper(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Remove “\(wallpaper.name)” from the library?"
        alert.informativeText = "The managed copy is deleted. Originals you imported from are never touched."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.library.remove(id: id, deleteManagedFile: true)
        refresh()
    }
}

// MARK: - Wallpaper card

@MainActor
final class WallpaperCollectionViewItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(labelWithString: "")
    private let favoriteStar = NSImageView()
    private let activeBadge = NSTextField(labelWithString: "Active")
    private var loadTask: Task<Void, Never>?

    override func loadView() {
        let container = NSView()

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 10
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
        thumbnailView.contentTintColor = .quaternaryLabelColor
        container.addSubview(thumbnailView)

        favoriteStar.translatesAutoresizingMaskIntoConstraints = false
        favoriteStar.image = NSImage(systemSymbolName: "star.fill", accessibilityDescription: "Favorite")
        favoriteStar.imageScaling = .scaleProportionallyUpOrDown
        favoriteStar.contentTintColor = .systemYellow
        container.addSubview(favoriteStar)

        activeBadge.translatesAutoresizingMaskIntoConstraints = false
        activeBadge.font = .systemFont(ofSize: 10, weight: .semibold)
        activeBadge.textColor = .white
        activeBadge.alignment = .center
        activeBadge.wantsLayer = true
        activeBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.85).cgColor
        activeBadge.layer?.cornerRadius = 7
        activeBadge.layer?.masksToBounds = true
        activeBadge.isHidden = true
        container.addSubview(activeBadge)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(nameLabel)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(infoLabel)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: 148),

            favoriteStar.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            favoriteStar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -2),
            favoriteStar.widthAnchor.constraint(equalToConstant: 14),
            favoriteStar.heightAnchor.constraint(equalToConstant: 14),

            activeBadge.leadingAnchor.constraint(equalTo: thumbnailView.leadingAnchor, constant: 8),
            activeBadge.bottomAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: -8),
            activeBadge.heightAnchor.constraint(equalToConstant: 16),
            activeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),

            nameLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            nameLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: favoriteStar.leadingAnchor, constant: -4),

            infoLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -2),
            infoLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            infoLabel.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),
        ])

        view = container
    }

    func configure(with wallpaper: Wallpaper, isActive: Bool, store: AppStore) {
        nameLabel.stringValue = wallpaper.name
        infoLabel.stringValue = "\(wallpaper.metadata.resolutionLabel)  ·  \(wallpaper.metadata.durationLabel)"
        favoriteStar.isHidden = !wallpaper.isFavorite
        activeBadge.isHidden = !isActive

        loadTask?.cancel()
        guard let url = store.library.fileURL(for: wallpaper) else { return }
        loadTask = Task { [weak self] in
            let data = await store.thumbnails.thumbnail(for: wallpaper, sourceURL: url)
            guard !Task.isCancelled, let self, let data, let image = NSImage(data: data) else { return }
            self.thumbnailView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        thumbnailView.image = NSImage(systemSymbolName: "film", accessibilityDescription: nil)
    }
}

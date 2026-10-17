import AppKit
import MotionpaperKit

// MARK: - Online gallery

@MainActor
final class GalleryViewController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    let store: AppStore
    private let service = GalleryService()

    private var collectionView: NSCollectionView!
    private var searchField: NSSearchField!
    private var sourcePopup: NSPopUpButton!
    private var statusLabel: NSTextField!
    private var emptyLabel: NSTextField!
    private var activityIndicator: NSProgressIndicator!

    private var results: [GalleryItem] = []
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?

    private static let reuseIdentifier = NSUserInterfaceItemIdentifier("gallery")

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.frame = NSRect(x: 0, y: 0, width: 820, height: 600)

        let title = MPUI.titleLabel("Gallery")
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let subtitle = MPUI.captionLabel(
            "Optional online wallpapers. The gallery only touches the network while you're using it."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subtitle)

        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)

        sourcePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 26), pullsDown: false)
        sourcePopup.bezelStyle = .rounded
        sourcePopup.controlSize = .small
        for source in GallerySource.allCases {
            sourcePopup.addItem(withTitle: source.label)
        }
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        controls.addArrangedSubview(sourcePopup)

        searchField = NSSearchField(frame: NSRect(x: 0, y: 0, width: 220, height: 26))
        searchField.placeholderString = "Search videos"
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchClicked)
        controls.addArrangedSubview(searchField)

        let searchButton = NSButton(title: "Search", target: self, action: #selector(searchClicked))
        searchButton.bezelStyle = .rounded
        controls.addArrangedSubview(searchButton)

        activityIndicator = NSProgressIndicator()
        activityIndicator.controlSize = .small
        activityIndicator.style = .spinning
        activityIndicator.isDisplayedWhenStopped = false
        controls.addArrangedSubview(activityIndicator)

        statusLabel = MPUI.captionLabel("NASA needs no API key. Pixabay and Pexels need a free key — Settings → Gallery.")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(statusLabel)

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 240, height: 210)
        layout.minimumInteritemSpacing = 16
        layout.minimumLineSpacing = 20
        layout.sectionInset = NSEdgeInsets(top: 16, left: 20, bottom: 24, right: 20)

        let collection = NSCollectionView()
        collection.collectionViewLayout = layout
        collection.dataSource = self
        collection.delegate = self
        collection.backgroundColors = [NSColor.clear]
        collection.isSelectable = true
        collection.allowsEmptySelection = true
        collection.allowsMultipleSelection = false
        collection.register(GalleryCardItem.self, forItemWithIdentifier: Self.reuseIdentifier)
        collection.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        collection.autoresizingMask = [.width]

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scroll)

        emptyLabel = MPUI.captionLabel("Search to explore wallpapers — NASA's space footage is keyless.")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            controls.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),

            statusLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),

            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor, constant: -30),
        ])

        view = container
        collectionView = collection
    }

    func refresh() {
        loadViewIfNeeded()
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !results.isEmpty
    }

    // MARK: - Search

    private var currentSource: GallerySource {
        let index = sourcePopup.indexOfSelectedItem
        guard index >= 0, index < GallerySource.allCases.count else { return .nasa }
        return GallerySource.allCases[index]
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        updateKeyHint()
    }

    private func updateKeyHint() {
        let source = currentSource
        if source.requiresAPIKey {
            let hasKey = !key(for: source).isEmpty
            statusLabel.stringValue = hasKey
                ? "Searching \(source.label)."
                : "\(source.label) needs a free API key — add it in Settings → Gallery."
        } else {
            statusLabel.stringValue = "NASA needs no API key."
        }
    }

    private func key(for source: GallerySource) -> String {
        switch source {
        case .pixabay: return store.settings.values.pixabayAPIKey
        case .pexels: return store.settings.values.pexelsAPIKey
        case .nasa: return ""
        }
    }

    @objc private func searchClicked() {
        runSearch()
    }

    private func runSearch() {
        let source = currentSource
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        let pixabayKey = store.settings.values.pixabayAPIKey
        let pexelsKey = store.settings.values.pexelsAPIKey

        searchTask?.cancel()
        activityIndicator.startAnimation(nil)
        statusLabel.stringValue = "Searching \(source.label)…"

        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let items = try await self.service.search(
                    source: source,
                    query: query,
                    pixabayKey: pixabayKey,
                    pexelsKey: pexelsKey
                )
                guard !Task.isCancelled else { return }
                self.results = items
                self.collectionView.reloadData()
                self.statusLabel.stringValue = "\(items.count) result\(items.count == 1 ? "" : "s") from \(source.label)"
            } catch {
                guard !Task.isCancelled else { return }
                self.results = []
                self.collectionView.reloadData()
                self.statusLabel.stringValue = "Search failed: \(error.localizedDescription)"
            }
            self.activityIndicator.stopAnimation(nil)
            self.updateEmptyState()
        }
    }

    // MARK: - Import

    @objc private func importClicked(_ sender: Any?) {
        let indexPaths = collectionView.selectionIndexPaths
        guard let indexPath = indexPaths.first, indexPath.item < results.count else { return }
        importItem(results[indexPath.item])
    }

    private func importItem(_ item: GalleryItem) {
        importTask?.cancel()
        statusLabel.stringValue = "Downloading “\(item.title)”…"
        activityIndicator.startAnimation(nil)

        importTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let tempURL = try await self.service.download(item)
                await self.store.importer.importFiles([tempURL], into: self.store.library, mode: .copy)
                try? FileManager.default.removeItem(at: tempURL)
                NotificationCenter.default.post(name: .libraryDidChange, object: nil)
                self.statusLabel.stringValue = "“\(item.title)” added to your library."
            } catch {
                self.statusLabel.stringValue = "Download failed: \(error.localizedDescription)"
            }
            self.activityIndicator.stopAnimation(nil)
        }
    }

    // MARK: - NSCollectionViewDataSource

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        results.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: Self.reuseIdentifier, for: indexPath) as! GalleryCardItem
        if indexPath.item < results.count {
            item.configure(with: results[indexPath.item]) { [weak self] galleryItem in
                self?.importItem(galleryItem)
            }
        }
        return item
    }
}

// MARK: - Search field delegate

extension GalleryViewController: NSSearchFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        // Return key triggers the search action; no live search for network calls.
    }
}

// MARK: - Gallery card

@MainActor
final class GalleryCardItem: NSCollectionViewItem {
    private let thumbnailView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var loadTask: Task<Void, Never>?
    private var onAdd: ((GalleryItem) -> Void)?
    private var galleryItem: GalleryItem?

    override func loadView() {
        let container = NSView()

        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.cornerRadius = 10
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        thumbnailView.contentTintColor = .quaternaryLabelColor
        container.addSubview(thumbnailView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(titleLabel)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.lineBreakMode = .byTruncatingMiddle
        container.addSubview(captionLabel)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.title = "Add"
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addClicked)
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            thumbnailView.topAnchor.constraint(equalTo: container.topAnchor),
            thumbnailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            thumbnailView.heightAnchor.constraint(equalToConstant: 148),

            titleLabel.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 6),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -2),

            captionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            captionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
            captionLabel.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -2),

            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            addButton.topAnchor.constraint(equalTo: thumbnailView.bottomAnchor, constant: 18),
            addButton.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -4),
        ])

        view = container
    }

    func configure(with item: GalleryItem, onAdd: @escaping (GalleryItem) -> Void) {
        galleryItem = item
        self.onAdd = onAdd
        titleLabel.stringValue = item.title
        captionLabel.stringValue = [item.author, item.durationLabel]
            .compactMap(\.self)
            .joined(separator: " · ")

        loadTask?.cancel()
        guard let thumbURL = item.thumbnailURL else { return }
        loadTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: thumbURL),
                  let image = NSImage(data: data) else { return }
            guard !Task.isCancelled, let self else { return }
            self.thumbnailView.image = image
        }
    }

    @objc private func addClicked() {
        guard let galleryItem else { return }
        onAdd?(galleryItem)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        loadTask?.cancel()
        loadTask = nil
        thumbnailView.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
    }
}

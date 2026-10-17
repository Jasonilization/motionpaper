import AppKit
import MotionpaperKit

// MARK: - Home

@MainActor
final class HomeViewController: NSViewController {
    let store: AppStore

    private var pauseButton: NSButton!
    private var statsLabel: NSTextField!
    private var appliedList = NSStackView()

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()

        let title = MPUI.titleLabel("Motionpaper")
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let subtitle = MPUI.captionLabel(
            "Live wallpapers for macOS. Import videos, apply them to your displays, and let them play behind your desktop."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitle)

        let actions = NSStackView()
        actions.orientation = .horizontal
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(actions)

        let importButton = NSButton(title: "Import Videos", target: self, action: #selector(importClicked))
        actions.addArrangedSubview(importButton)

        pauseButton = NSButton(title: "Pause", target: self, action: #selector(pauseClicked))
        actions.addArrangedSubview(pauseButton)

        let nextButton = NSButton(title: "Next Wallpaper", target: self, action: #selector(nextClicked))
        actions.addArrangedSubview(nextButton)

        let reapplyButton = NSButton(title: "Reapply All", target: self, action: #selector(reapplyClicked))
        actions.addArrangedSubview(reapplyButton)

        let appliedTitle = MPUI.sectionLabel("Currently Applied")
        appliedTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(appliedTitle)

        appliedList.orientation = .vertical
        appliedList.alignment = .leading
        appliedList.spacing = 10
        appliedList.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(appliedList)

        let libraryTitle = MPUI.sectionLabel("Library")
        libraryTitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(libraryTitle)

        statsLabel = MPUI.captionLabel("")
        statsLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(statsLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            actions.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            actions.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            appliedTitle.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 24),
            appliedTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            appliedList.topAnchor.constraint(equalTo: appliedTitle.bottomAnchor, constant: 10),
            appliedList.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            appliedList.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),

            libraryTitle.topAnchor.constraint(equalTo: appliedList.bottomAnchor, constant: 24),
            libraryTitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            statsLabel.topAnchor.constraint(equalTo: libraryTitle.bottomAnchor, constant: 4),
            statsLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            statsLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        view = MPUI.scrollContainer(content: root)
        refresh()
    }

    func refresh() {
        loadViewIfNeeded()

        pauseButton.title = store.engine.userPaused ? "Resume" : "Pause"

        statsLabel.stringValue = [
            "\(store.library.wallpapers.count) wallpapers",
            "\(store.library.favoriteWallpapers.count) favorites",
            "\(store.library.playlists.count) playlists",
        ].joined(separator: "  ·  ")

        rebuildAppliedList()
    }

    private func rebuildAppliedList() {
        for subview in appliedList.views {
            appliedList.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for display in store.engine.displays {
            let row = appliedRow(for: display)
            appliedList.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: appliedList.widthAnchor).isActive = true
        }

        if store.engine.displays.isEmpty {
            let empty = MPUI.captionLabel("No displays detected.")
            appliedList.addArrangedSubview(empty)
        }
    }

    private func appliedRow(for display: DisplayInfo) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let assignment = store.library.assignment(displayKey: display.id)
        let wallpaper = assignment?.wallpaperID.flatMap { store.library.wallpaper(id: $0) }

        let thumb = NSImageView()
        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.masksToBounds = true
        thumb.imageScaling = .scaleProportionallyUpOrDown
        if let wallpaper, let image = NSImage(contentsOf: store.paths.thumbnailURL(for: wallpaper.id)) {
            thumb.image = image
        } else {
            thumb.image = NSImage(systemSymbolName: "display", accessibilityDescription: nil)
            thumb.contentTintColor = .tertiaryLabelColor
        }
        row.addSubview(thumb)

        let nameLabel = NSTextField(labelWithString: wallpaper?.name ?? "No wallpaper")
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(nameLabel)

        let detailLabel = MPUI.captionLabel(
            "\(display.name)  ·  \(display.nativeWidth)×\(display.nativeHeight)" + (display.isPrimary ? "  ·  Primary" : "")
        )
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            thumb.topAnchor.constraint(equalTo: row.topAnchor),
            thumb.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 64),
            thumb.heightAnchor.constraint(equalToConstant: 40),

            nameLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            nameLabel.topAnchor.constraint(equalTo: row.topAnchor, constant: 1),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),

            detailLabel.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 12),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])

        return row
    }

    // MARK: - Actions

    @objc private func importClicked() {
        MPUI.presentVideoImportPanel(store: store)
    }

    @objc private func pauseClicked() {
        store.engine.toggleUserPause()
        refresh()
    }

    @objc private func nextClicked() {
        store.engine.nextWallpaper()
        refresh()
    }

    @objc private func reapplyClicked() {
        store.engine.recreateAllSurfaces()
        refresh()
    }
}

// MARK: - Displays

@MainActor
final class DisplaysViewController: NSViewController {
    let store: AppStore

    private var listStack = NSStackView()

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()

        let title = MPUI.titleLabel("Displays")
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let subtitle = MPUI.captionLabel(
            "Every connected screen gets its own wallpaper. Change it here, or right-click any wallpaper in the Library."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitle)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(listStack)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            listStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 18),
            listStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            listStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            listStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])

        view = MPUI.scrollContainer(content: root)
        refresh()
    }

    func refresh() {
        loadViewIfNeeded()

        for subview in listStack.views {
            listStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        for display in store.engine.displays {
            let card = card(for: display)
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }

        if store.engine.displays.isEmpty {
            let empty = MPUI.captionLabel("No displays detected.")
            listStack.addArrangedSubview(empty)
        }
    }

    private func card(for display: DisplayInfo) -> NSView {
        let box = MPUI.cardBox()

        let nameLabel = NSTextField(labelWithString: display.name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(nameLabel)

        let detailLabel = MPUI.captionLabel(
            "\(display.nativeWidth)×\(display.nativeHeight)" + (display.isPrimary ? "  ·  Primary display" : "")
        )
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(detailLabel)

        let assignment = store.library.assignment(displayKey: display.id)
        let currentName = assignment?.wallpaperID
            .flatMap { store.library.wallpaper(id: $0)?.name } ?? "No wallpaper"
        let playlistName = assignment?.playlistID
            .flatMap { store.library.playlist(id: $0)?.name }
        let currentText = playlistName.map { "Playlist: \($0)" } ?? "Wallpaper: \(currentName)"
        let currentLabel = MPUI.captionLabel(currentText)
        currentLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(currentLabel)

        let changeButton = NSButton(title: "Change…", target: self, action: #selector(changeClicked))
        changeButton.translatesAutoresizingMaskIntoConstraints = false
        changeButton.bezelStyle = .rounded
        changeButton.controlSize = .small
        box.addSubview(changeButton)

        let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearClicked(_:)))
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.identifier = NSUserInterfaceItemIdentifier(display.id)
        box.addSubview(clearButton)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -8),

            currentLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 8),
            currentLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            currentLabel.trailingAnchor.constraint(lessThanOrEqualTo: changeButton.leadingAnchor, constant: -8),
            currentLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),

            changeButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            changeButton.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -12),
            clearButton.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            clearButton.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 14),
        ])

        return box
    }

    // MARK: - Actions

    @objc private func changeClicked() {
        NotificationCenter.default.post(name: .openLibrary, object: nil)
    }

    @objc private func clearClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        store.engine.clear(displayKey: key)
        refresh()
    }
}

// MARK: - Playlists

@MainActor
final class PlaylistsViewController: NSViewController {
    let store: AppStore

    private var listStack = NSStackView()
    private var emptyLabel: NSTextField!

    private static let intervalOptions: [(label: String, seconds: TimeInterval)] = [
        ("Off (manual)", 0),
        ("5 Minutes", 300),
        ("15 Minutes", 900),
        ("30 Minutes", 1800),
        ("1 Hour", 3600),
        ("3 Hours", 10800),
        ("6 Hours", 21600),
        ("12 Hours", 43200),
        ("1 Day", 86400),
    ]

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let root = NSView()

        let title = MPUI.titleLabel("Playlists")
        title.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(title)

        let subtitle = MPUI.captionLabel(
            "A playlist rotates its wallpapers automatically — on a timer, or split evenly across the day."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(subtitle)

        let newButton = NSButton(title: "New Playlist…", target: self, action: #selector(newPlaylistClicked))
        newButton.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(newButton)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 12
        listStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(listStack)

        emptyLabel = MPUI.captionLabel(
            "No playlists yet. Create one, then right-click wallpapers in the Library to add them."
        )
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),

            newButton.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            newButton.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),

            listStack.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 16),
            listStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            listStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            listStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),

            emptyLabel.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 18),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
        ])

        view = MPUI.scrollContainer(content: root)
        refresh()
    }

    func refresh() {
        loadViewIfNeeded()

        for subview in listStack.views {
            listStack.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let playlists = store.library.playlists
        emptyLabel.isHidden = !playlists.isEmpty

        for playlist in playlists {
            let card = card(for: playlist)
            listStack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
        }
    }

    private func card(for playlist: Playlist) -> NSView {
        let box = MPUI.cardBox()

        let nameLabel = NSTextField(labelWithString: playlist.name)
        nameLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(nameLabel)

        let enabledCheckbox = NSButton(
            checkboxWithTitle: "Enabled",
            target: self,
            action: #selector(enabledChanged(_:))
        )
        enabledCheckbox.state = playlist.isEnabled ? .on : .off
        enabledCheckbox.identifier = NSUserInterfaceItemIdentifier(playlist.id.uuidString)
        enabledCheckbox.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(enabledCheckbox)

        var summaryParts: [String] = [
            "\(playlist.wallpaperIDs.count) wallpaper\(playlist.wallpaperIDs.count == 1 ? "" : "s")",
            playlist.mode == .dayCycle ? PlaylistMode.dayCycle.label : playlist.order.label,
        ]
        if playlist.mode != .dayCycle {
            let interval = Self.intervalOptions.first { $0.seconds == playlist.changeInterval }
                ?? Self.intervalOptions.first { $0.seconds >= playlist.changeInterval && playlist.changeInterval > 0 }
            summaryParts.append(interval?.label ?? "Off (manual)")
        }
        let summaryLabel = MPUI.captionLabel(summaryParts.joined(separator: "  ·  "))
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(summaryLabel)

        // Thumbnail strip (up to 10 items)
        let thumbRow = NSStackView()
        thumbRow.orientation = .horizontal
        thumbRow.spacing = 6
        thumbRow.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(thumbRow)

        let wallpapers = store.library.wallpapers(ids: playlist.wallpaperIDs)
        let visible = wallpapers.prefix(10)
        for wallpaper in visible {
            let thumb = NSImageView()
            thumb.translatesAutoresizingMaskIntoConstraints = false
            thumb.wantsLayer = true
            thumb.layer?.cornerRadius = 5
            thumb.layer?.masksToBounds = true
            thumb.imageScaling = .scaleProportionallyUpOrDown
            if let image = NSImage(contentsOf: store.paths.thumbnailURL(for: wallpaper.id)) {
                thumb.image = image
            }
            thumb.widthAnchor.constraint(equalToConstant: 56).isActive = true
            thumb.heightAnchor.constraint(equalToConstant: 36).isActive = true
            thumbRow.addArrangedSubview(thumb)
        }
        if wallpapers.count > visible.count {
            let more = MPUI.captionLabel("+\(wallpapers.count - visible.count) more")
            more.font = .systemFont(ofSize: 11)
            thumbRow.addArrangedSubview(more)
        }
        if wallpapers.isEmpty {
            let none = MPUI.captionLabel("Empty — add wallpapers from the Library's context menu.")
            none.font = .systemFont(ofSize: 11)
            thumbRow.addArrangedSubview(none)
        }

        // Controls row
        let controls = NSStackView()
        controls.orientation = .horizontal
        controls.spacing = 10
        controls.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(controls)

        let applyPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 170, height: 24), pullsDown: false)
        applyPopup.bezelStyle = .rounded
        applyPopup.controlSize = .small
        applyPopup.addItem(withTitle: "Apply to…")
        for display in store.engine.displays {
            let item = NSMenuItem(title: display.name, action: #selector(applyPopupChanged(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = display.id
            applyPopup.menu?.addItem(item)
        }
        if store.engine.displays.count > 1 {
            let all = NSMenuItem(title: "All Displays", action: #selector(applyPopupChanged(_:)), keyEquivalent: "")
            all.target = self
            all.representedObject = "ALL"
            applyPopup.menu?.addItem(all)
        }
        applyPopup.identifier = NSUserInterfaceItemIdentifier(playlist.id.uuidString)
        controls.addArrangedSubview(applyPopup)

        let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24), pullsDown: false)
        modePopup.bezelStyle = .rounded
        modePopup.controlSize = .small
        modePopup.addItem(withTitle: PlaylistMode.interval.label)
        modePopup.addItem(withTitle: PlaylistMode.dayCycle.label)
        modePopup.selectItem(at: playlist.mode == .dayCycle ? 1 : 0)
        modePopup.identifier = NSUserInterfaceItemIdentifier(playlist.id.uuidString)
        modePopup.target = self
        modePopup.action = #selector(modePopupChanged(_:))
        controls.addArrangedSubview(modePopup)

        let intervalPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 130, height: 24), pullsDown: false)
        intervalPopup.bezelStyle = .rounded
        intervalPopup.controlSize = .small
        for option in Self.intervalOptions {
            intervalPopup.addItem(withTitle: option.label)
        }
        if playlist.mode != .dayCycle {
            let index = Self.intervalOptions.firstIndex { $0.seconds == playlist.changeInterval }
                ?? Self.intervalOptions.firstIndex { $0.seconds >= playlist.changeInterval && playlist.changeInterval > 0 }
                ?? 0
            intervalPopup.selectItem(at: index)
        } else {
            intervalPopup.isEnabled = false
        }
        intervalPopup.identifier = NSUserInterfaceItemIdentifier(playlist.id.uuidString)
        intervalPopup.target = self
        intervalPopup.action = #selector(intervalPopupChanged(_:))
        controls.addArrangedSubview(intervalPopup)

        let deleteButton = NSButton(title: "Delete…", target: self, action: #selector(deleteClicked(_:)))
        deleteButton.bezelStyle = .rounded
        deleteButton.controlSize = .small
        deleteButton.identifier = NSUserInterfaceItemIdentifier(playlist.id.uuidString)
        controls.addArrangedSubview(deleteButton)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: enabledCheckbox.leadingAnchor, constant: -8),

            enabledCheckbox.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            enabledCheckbox.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            summaryLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            summaryLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),

            thumbRow.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            thumbRow.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            thumbRow.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),

            controls.topAnchor.constraint(equalTo: thumbRow.bottomAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -16),
            controls.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])

        return box
    }

    // MARK: - Actions

    @objc private func newPlaylistClicked() {
        guard let name = MPUI.presentTextAlert(
            title: "New Playlist",
            message: "Give the playlist a name. Wallpapers can be added from the Library's context menu.",
            placeholder: "",
            confirmTitle: "Create"
        ) else { return }
        _ = store.library.createPlaylist(name: name)
        refresh()
    }

    @objc private func applyPopupChanged(_ sender: NSPopUpButton) {
        guard let playlistKey = sender.identifier?.rawValue,
              let playlistID = UUID(uuidString: playlistKey),
              let target = sender.selectedItem?.representedObject as? String else { return }
        if target == "ALL" {
            for display in store.engine.displays {
                store.engine.assign(playlistID: playlistID, toDisplay: display.id)
            }
        } else {
            store.engine.assign(playlistID: playlistID, toDisplay: target)
        }
        refresh()
    }

    @objc private func modePopupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,
              let id = UUID(uuidString: key),
              var playlist = store.library.playlist(id: id) else { return }
        playlist.mode = sender.indexOfSelectedItem == 1 ? .dayCycle : .interval
        store.library.update(playlist)
        refresh()
    }

    @objc private func intervalPopupChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,
              let id = UUID(uuidString: key),
              var playlist = store.library.playlist(id: id),
              sender.indexOfSelectedItem < Self.intervalOptions.count else { return }
        playlist.changeInterval = Self.intervalOptions[sender.indexOfSelectedItem].seconds
        store.library.update(playlist)
        refresh()
    }

    @objc private func enabledChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let id = UUID(uuidString: key),
              var playlist = store.library.playlist(id: id) else { return }
        playlist.isEnabled = sender.state == .on
        store.library.update(playlist)
    }

    @objc private func deleteClicked(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let id = UUID(uuidString: key),
              let playlist = store.library.playlist(id: id) else { return }

        let alert = NSAlert()
        alert.messageText = "Delete playlist “\(playlist.name)”?"
        alert.informativeText = "The wallpapers stay in your library. Displays using this playlist keep their current wallpaper."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.library.deletePlaylist(id: id)
        refresh()
    }
}

import AppKit
import MotionpaperKit
import ServiceManagement

// MARK: - Settings window controller

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    let store: AppStore
    let window: NSWindow

    init(store: AppStore) {
        self.store = store

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Motionpaper Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 460)

        let tabController = NSTabViewController()
        tabController.tabStyle = .toolbar

        func tab(_ label: String, _ symbol: String, _ viewController: NSViewController) -> NSTabViewItem {
            let item = NSTabViewItem(viewController: viewController)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            return item
        }

        tabController.addTabViewItem(tab("General", "gearshape", GeneralSettingsViewController(store: store)))
        tabController.addTabViewItem(tab("Playback", "play.circle", PlaybackSettingsViewController(store: store)))
        tabController.addTabViewItem(tab("Lock Screen", "lock.rectangle", LockScreenSettingsViewController(store: store)))
        tabController.addTabViewItem(tab("Gallery", "photo.on.rectangle", GallerySettingsViewController(store: store)))
        tabController.addTabViewItem(tab("Storage", "internaldrive", StorageSettingsViewController(store: store)))

        window.contentViewController = tabController

        super.init()

        window.delegate = self
        window.center()
    }

    func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        true
    }
}

// MARK: - Form helpers

@MainActor
private func makeLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.textColor = .labelColor
    return label
}

@MainActor
private func makeCheckbox(_ title: String, isOn: Bool, target: AnyObject?, action: Selector) -> NSButton {
    let checkbox = NSButton(checkboxWithTitle: title, target: target, action: action)
    checkbox.state = isOn ? .on : .off
    return checkbox
}

@MainActor
private func makeSeparator() -> NSBox {
    let box = NSBox()
    box.boxType = .separator
    return box
}

// MARK: - General

@MainActor
final class GeneralSettingsViewController: NSViewController {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let launchAtLogin = makeCheckbox(
            "Launch at login", isOn: store.settings.values.launchAtLogin,
            target: self, action: #selector(launchAtLoginChanged(_:))
        )
        let startInBackground = makeCheckbox(
            "Start in background (no window)", isOn: store.settings.values.startInBackground,
            target: self, action: #selector(startInBackgroundChanged(_:))
        )
        let menuBarIcon = makeCheckbox(
            "Show menu-bar icon", isOn: store.settings.values.showMenuBarIcon,
            target: self, action: #selector(menuBarIconChanged(_:))
        )
        let cooldownNote = MPUI.captionLabel("")
        cooldownNote.font = .systemFont(ofSize: 11)
        if CrashRecovery.menuBarInCooldown() {
            cooldownNote.stringValue = "Paused for \(CrashRecovery.cooldownMinutesRemaining) min — automatic crash-loop recovery on this macOS beta. It returns by itself."
        } else {
            cooldownNote.isHidden = true
        }
        let restartAfterCrashes = makeCheckbox(
            "Restart automatically after crashes", isOn: store.settings.values.restartAfterCrashes,
            target: self, action: #selector(restartAfterCrashesChanged(_:))
        )

        let note = MPUI.captionLabel(
            "The crash watchdog uses a user-level launchd agent that relaunches Motionpaper within seconds if it ever exits unexpectedly. Clean quits are never restarted."
        )
        note.font = .systemFont(ofSize: 11)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [launchAtLogin, startInBackground, menuBarIcon, cooldownNote, restartAfterCrashes, note] {
            stack.addArrangedSubview(view)
        }
        note.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = MPUI.scrollContainer(content: root)
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            store.settings.update { $0.launchAtLogin = enabled }
        } catch {
            sender.state = enabled ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Login item unavailable"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func startInBackgroundChanged(_ sender: NSButton) {
        store.settings.update { $0.startInBackground = sender.state == .on }
    }

    @objc private func menuBarIconChanged(_ sender: NSButton) {
        let visible = sender.state == .on
        store.settings.update { $0.showMenuBarIcon = visible }
        store.menuBar.updateVisibility(visible)
    }

    @objc private func restartAfterCrashesChanged(_ sender: NSButton) {
        store.settings.update { $0.restartAfterCrashes = sender.state == .on }
        store.updateKeepAliveAgent()
    }
}

// MARK: - Playback

@MainActor
final class PlaybackSettingsViewController: NSViewController {
    private let store: AppStore
    private var batteryValueLabel: NSTextField?
    private var volumeValueLabel: NSTextField?

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let values = store.settings.values

        let modeLabel = makeLabel("Performance Mode")
        let modeSegment = NSSegmentedControl(
            labels: PerformanceMode.allCases.map(\.label),
            trackingMode: .selectOne,
            target: self,
            action: #selector(modeChanged(_:))
        )
        modeSegment.selectedSegment = PerformanceMode.allCases.firstIndex(of: values.performanceMode) ?? 1
        let modeExplanation = MPUI.captionLabel(values.performanceMode.explanation)
        modeExplanation.font = .systemFont(ofSize: 11)

        let batteryLabel = makeLabel("Pause on battery below")
        let batterySlider = NSSlider(
            value: Double(values.pauseOnBatteryBelowPercent),
            minValue: 0, maxValue: 100,
            target: self,
            action: #selector(batteryChanged(_:))
        )
        batterySlider.isContinuous = true
        batterySlider.controlSize = .small
        let batteryValue = NSTextField(labelWithString: values.pauseOnBatteryBelowPercent == 0 ? "Never" : "\(values.pauseOnBatteryBelowPercent)%")
        batteryValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        batteryValue.textColor = .secondaryLabelColor
        batteryValueLabel = batteryValue
        let batteryNote = MPUI.captionLabel("0 = never pause on battery.")
        batteryNote.font = .systemFont(ofSize: 11)

        let lowPower = makeCheckbox(
            "Pause in Low Power Mode", isOn: values.pauseInLowPowerMode,
            target: self, action: #selector(lowPowerChanged(_:))
        )
        let pauseLocked = makeCheckbox(
            "Pause when the Mac is locked", isOn: values.pauseWhenLocked,
            target: self, action: #selector(pauseLockedChanged(_:))
        )

        let mutedLabel = makeLabel("Play wallpapers muted")
        let muted = NSSegmentedControl(
            labels: ["Muted", "With Audio"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(mutedChanged(_:))
        )
        muted.selectedSegment = values.defaultMuted ? 0 : 1

        let volumeLabel = makeLabel("Volume")
        let volumeSlider = NSSlider(
            value: values.defaultVolume * 100,
            minValue: 0, maxValue: 100,
            target: self,
            action: #selector(volumeChanged(_:))
        )
        volumeSlider.isContinuous = true
        volumeSlider.controlSize = .small
        let volumeValue = NSTextField(labelWithString: "\(Int(values.defaultVolume * 100))%")
        volumeValue.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        volumeValue.textColor = .secondaryLabelColor
        volumeValueLabel = volumeValue

        let scalingLabel = makeLabel("Scaling")
        let scalingPopup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24), pullsDown: false)
        scalingPopup.bezelStyle = .rounded
        scalingPopup.controlSize = .small
        for mode in ScalingMode.allCases {
            scalingPopup.addItem(withTitle: mode.label)
        }
        scalingPopup.selectItem(at: ScalingMode.allCases.firstIndex(of: values.defaultScaling) ?? 0)
        scalingPopup.target = self
        scalingPopup.action = #selector(scalingChanged(_:))

        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false

        grid.addRow(with: [modeLabel, modeSegment])
        grid.addRow(with: [NSView(), modeExplanation])
        grid.addRow(with: [batteryLabel, batterySlider, batteryValue])
        grid.addRow(with: [NSView(), batteryNote])
        grid.addRow(with: [lowPower])
        grid.addRow(with: [pauseLocked])
        grid.addRow(with: [mutedLabel, muted])
        grid.addRow(with: [volumeLabel, volumeSlider, volumeValue])
        grid.addRow(with: [scalingLabel, scalingPopup])
        grid.column(at: 0).xPlacement = .trailing

        let root = NSView()
        root.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = MPUI.scrollContainer(content: root)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let all = PerformanceMode.allCases
        guard sender.selectedSegment >= 0, sender.selectedSegment < all.count else { return }
        let mode = all[sender.selectedSegment]
        store.settings.update { $0.performanceMode = mode }
        store.resource.evaluate()
    }

    @objc private func batteryChanged(_ sender: NSSlider) {
        let value = Int(sender.intValue)
        store.settings.update { $0.pauseOnBatteryBelowPercent = value }
        batteryValueLabel?.stringValue = value == 0 ? "Never" : "\(value)%"
    }

    @objc private func lowPowerChanged(_ sender: NSButton) {
        store.settings.update { $0.pauseInLowPowerMode = sender.state == .on }
        store.resource.evaluate()
    }

    @objc private func pauseLockedChanged(_ sender: NSButton) {
        store.settings.update { $0.pauseWhenLocked = sender.state == .on }
    }

    @objc private func mutedChanged(_ sender: NSSegmentedControl) {
        let muted = sender.selectedSegment == 0
        store.settings.update { $0.defaultMuted = muted }
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let value = Double(sender.intValue) / 100.0
        store.settings.update { $0.defaultVolume = value }
        volumeValueLabel?.stringValue = "\(Int(sender.intValue))%"
    }

    @objc private func scalingChanged(_ sender: NSPopUpButton) {
        let all = ScalingMode.allCases
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < all.count else { return }
        store.settings.update { $0.defaultScaling = all[sender.indexOfSelectedItem] }
    }
}

// MARK: - Lock Screen

@MainActor
final class LockScreenSettingsViewController: NSViewController {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let values = store.settings.values

        let matchToggle = makeCheckbox(
            "Match Lock Screen automatically (still frame)",
            isOn: values.matchLockScreen,
            target: self, action: #selector(matchChanged(_:))
        )
        let matchNote = MPUI.captionLabel(
            "Exports a still frame of the current wallpaper to your Pictures folder so the Lock Screen matches the desktop. macOS only allows still images there."
        )
        matchNote.font = .systemFont(ofSize: 11)
        matchNote.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true

        let setupButton = NSButton(
            title: "Set Up Lock Screen Picture…",
            target: self,
            action: #selector(setupClicked)
        )
        let matchNowButton = NSButton(
            title: "Re-export Current Frame",
            target: self,
            action: #selector(matchNowClicked)
        )

        let loginButton = NSButton(
            title: "Set Login Window Picture…",
            target: self,
            action: #selector(loginPictureClicked)
        )

        let overlayToggle = makeCheckbox(
            "Live video on the Lock Screen (experimental)",
            isOn: values.enableLockScreenOverlay,
            target: self, action: #selector(overlayChanged(_:))
        )
        let overlayNote = MPUI.captionLabel(
            "Plays the actual video on the Lock Screen using an undocumented system API — the same technique notch-overlay apps use. It may stop working in a future macOS update, and needs administrator approval once. Changes take effect the next time the screen locks."
        )
        overlayNote.font = .systemFont(ofSize: 11)
        overlayNote.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        for view in [matchToggle, matchNote, setupButton, matchNowButton, loginButton] {
            stack.addArrangedSubview(view)
        }
        stack.addArrangedSubview(makeSeparator())
        for view in [overlayToggle, overlayNote] {
            stack.addArrangedSubview(view)
        }

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = MPUI.scrollContainer(content: root)
    }

    @objc private func matchChanged(_ sender: NSButton) {
        store.settings.update { $0.matchLockScreen = sender.state == .on }
    }

    @objc private func setupClicked() {
        store.exportStableLockFrame()
        store.openWallpaperSettings()
    }

    @objc private func matchNowClicked() {
        store.matchLockScreenNow()
    }

    @objc private func loginPictureClicked() {
        Task { @MainActor in
            do {
                try await store.setLoginWindowPicture()
                let alert = NSAlert()
                alert.messageText = "Login window picture set"
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't set the login window picture"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc private func overlayChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        store.settings.update { $0.enableLockScreenOverlay = enabled }
        if enabled {
            store.engine.prepareLockScreenOverlayIfEnabled()
        }
    }
}

// MARK: - Gallery keys

@MainActor
final class GallerySettingsViewController: NSViewController, NSTextFieldDelegate {
    private let store: AppStore
    private var pixabayField: NSTextField?
    private var pexelsField: NSTextField?

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let intro = MPUI.captionLabel(
            "Optional API keys for browsing more wallpapers online. Keys are stored locally on this Mac and only sent to their own services. NASA images need no key."
        )
        intro.font = .systemFont(ofSize: 11)
        intro.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true

        let pixabayLabel = makeLabel("Pixabay API key")
        let pixabay = NSTextField()
        pixabay.stringValue = store.settings.values.pixabayAPIKey
        pixabay.font = .systemFont(ofSize: 12)
        pixabay.delegate = self
        pixabay.placeholderString = "Get a free key at pixabay.com"
        pixabayField = pixabay

        let pexelsLabel = makeLabel("Pexels API key")
        let pexels = NSTextField()
        pexels.stringValue = store.settings.values.pexelsAPIKey
        pexels.font = .systemFont(ofSize: 12)
        pexels.delegate = self
        pexels.placeholderString = "Get a free key at pexels.com/api"
        pexelsField = pexels

        let grid = NSGridView()
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.addRow(with: [pixabayLabel, pixabay])
        grid.addRow(with: [pexelsLabel, pexels])
        grid.column(at: 0).xPlacement = .trailing
        pixabay.widthAnchor.constraint(equalToConstant: 260).isActive = true
        pexels.widthAnchor.constraint(equalToConstant: 260).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(intro)
        stack.addArrangedSubview(grid)

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = MPUI.scrollContainer(content: root)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === pixabayField {
            store.settings.update { $0.pixabayAPIKey = field.stringValue.trimmingCharacters(in: .whitespaces) }
        } else if field === pexelsField {
            store.settings.update { $0.pexelsAPIKey = field.stringValue.trimmingCharacters(in: .whitespaces) }
        }
    }
}

// MARK: - Storage

@MainActor
final class StorageSettingsViewController: NSViewController {
    private let store: AppStore
    private var summaryLabel: NSTextField?

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let summary = MPUI.captionLabel("")
        summaryLabel = summary

        let location = NSTextField(labelWithString: store.paths.appSupport.path)
        location.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        location.textColor = .secondaryLabelColor
        location.lineBreakMode = .byTruncatingMiddle
        location.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        let revealButton = NSButton(title: "Reveal in Finder", target: self, action: #selector(revealClicked))
        let clearThumbsButton = NSButton(title: "Clear Thumbnail Cache", target: self, action: #selector(clearThumbsClicked))

        let resetButton = NSButton(title: "Reset All Data…", target: self, action: #selector(resetClicked))
        let resetNote = MPUI.captionLabel(
            "Removes all imported wallpapers, playlists, and display assignments. Your settings are kept, and original files you imported from are never touched."
        )
        resetNote.font = .systemFont(ofSize: 11)
        resetNote.widthAnchor.constraint(lessThanOrEqualToConstant: 460).isActive = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(summary)
        stack.addArrangedSubview(location)
        stack.addArrangedSubview(revealButton)
        stack.addArrangedSubview(clearThumbsButton)
        stack.addArrangedSubview(makeSeparator())
        stack.addArrangedSubview(resetButton)
        stack.addArrangedSubview(resetNote)

        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        view = MPUI.scrollContainer(content: root)
        updateSummary()
    }

    private func updateSummary() {
        let count = store.library.wallpapers.count
        let bytes = (try? FileManager.default.contentsOfDirectory(
            at: store.paths.videos, includingPropertiesForKeys: [.fileSizeKey]
        ))?.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        } ?? 0
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        summaryLabel?.stringValue = "\(count) wallpapers  ·  \(size) on disk"
    }

    @objc private func revealClicked() {
        NSWorkspace.shared.open(store.paths.appSupport)
    }

    @objc private func clearThumbsClicked() {
        Task { @MainActor in
            let cleared = await store.thumbnails.clearAll()
            updateSummary()
            let alert = NSAlert()
            alert.messageText = "Thumbnail cache cleared"
            alert.informativeText = "Removed \(cleared) cached thumbnails. They regenerate automatically as needed."
            alert.runModal()
        }
    }

    @objc private func resetClicked() {
        let alert = NSAlert()
        alert.messageText = "Reset all Motionpaper data?"
        alert.informativeText = "All imported wallpapers, playlists, and display assignments are removed. Your settings are kept. Original files you imported from are never touched. This cannot be undone."
        alert.addButton(withTitle: "Reset Everything")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        store.resetAllData()
        updateSummary()
    }
}

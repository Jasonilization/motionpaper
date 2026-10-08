import ServiceManagement
import SwiftUI
import MotionpaperKit

/// The full settings window (⌘, in the app).
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            PlaybackTab().tabItem { Label("Playback", systemImage: "play.circle") }
            LockScreenTab().tabItem { Label("Lock Screen", systemImage: "lock.rectangle") }
            StorageTab().tabItem { Label("Storage", systemImage: "internaldrive") }
            MigrationTab().tabItem { Label("Migration", systemImage: "arrow.down.circle") }
            CapabilitiesTab().tabItem { Label("Capabilities", systemImage: "checkmark.seal") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 600, height: 480)
    }
}

// MARK: - Migration

/// Import from Wallspace: scans its locally accessible storage read-only,
/// reports what it found, and imports new wallpapers without touching
/// the Wallspace installation.
private struct MigrationTab: View {
    @Environment(AppStore.self) private var store
    @State private var report: WallspaceMigrator.ScanReport?
    @State private var isImporting = false
    @State private var resultLine: String?

    var body: some View {
        Form {
            Section {
                if let report {
                    LabeledContent("Found in Wallspace") {
                        Text("\(report.items.count) wallpaper\(report.items.count == 1 ? "" : "s")")
                    }
                    LabeledContent("Already in Motionpaper") {
                        Text("\(report.alreadyImportedCount)")
                    }
                    LabeledContent("Ready to import") {
                        Text("\(report.newCount)")
                    }
                    if report.unsupportedCount > 0 {
                        LabeledContent("Unsupported") {
                            Text("\(report.unsupportedCount)")
                        }
                    }

                    if !report.items.isEmpty {
                        ForEach(report.items.filter { $0.status == .new }) { item in
                            HStack {
                                Image(systemName: item.isFavorite ? "star.fill" : "photo")
                                    .foregroundStyle(item.isFavorite ? .yellow : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title ?? item.fileURL.lastPathComponent)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(item.category ?? "no category info")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }

                    if report.newCount > 0 {
                        Button(report.newCount == 1 ? "Import 1 Wallpaper" : "Import \(report.newCount) Wallpapers") {
                            importNew()
                        }
                        .disabled(isImporting)
                    } else if !report.items.isEmpty {
                        Label("Everything found is already in your library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    if isImporting {
                        ProgressView()
                    }
                    if let resultLine {
                        Text(resultLine).font(.caption).foregroundStyle(.secondary)
                    }

                    Button("Scan Again") {
                        Task { await scan() }
                    }
                    .disabled(isImporting)
                } else {
                    Text("Motionpaper can import wallpapers from a locally installed Wallspace app — including favorites and titles — without modifying Wallspace or its files.")
                        .font(.callout)
                    Button("Scan for Wallspace Data…") {
                        Task { await scan() }
                    }
                }
            } header: {
                Text("Import from Wallspace")
            } footer: {
                Text("Only wallpapers already downloaded to this Mac are found. Wallspace's installation and files are never modified; imported copies live in Motionpaper's own library.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await scan() }
    }

    private func scan() async {
        let migrator = WallspaceMigrator.defaultMigrator()
        report = await migrator.scan(library: store.library)
    }

    private func importNew() {
        guard let report else { return }
        let items = report.items.filter { $0.status == .new }
        isImporting = true
        resultLine = nil
        let migrator = WallspaceMigrator.defaultMigrator()
        Task {
            let outcome = await migrator.importItems(items, into: store.library, importer: store.importer)
            isImporting = false
            resultLine = "Imported \(outcome.imported), skipped \(outcome.skipped)."
            await scan()
        }
    }
}

// MARK: - Lock Screen

/// Honest Lock Screen integration: macOS owns that surface, so this tab
/// explains the limitation and provides the closest supported behavior —
/// poster-frame export + guided setup for a matching static lock screen.
private struct LockScreenTab: View {
    @Environment(AppStore.self) private var store
    @State private var isExporting = false
    @State private var exportResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Match Lock Screen automatically", isOn: Binding(
                    get: { store.settings.values.matchLockScreen },
                    set: { enabled in
                        store.settings.update { $0.matchLockScreen = enabled }
                        if enabled {
                            store.matchLockScreenNow()
                        }
                    }
                ))
                .help("Exports a still frame of your active wallpaper and sets it as the system wallpaper, so the Lock Screen shows a matching image when you lock. This is the same mechanism Wallspace Pro uses — stills only; macOS does not allow live video on the Lock Screen.")

                Text("When enabled, every applied wallpaper also updates the system wallpaper with a matching still frame. The Lock Screen always renders the system wallpaper, so your lock view stays visually in sync with your desktop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Also match the pre-login window…") {
                    Task { try? await store.setLoginWindowPicture() }
                }
                .help("Writes the documented com.apple.loginwindow DesktopPicture preference — the screen shown before you log in. Asks for your administrator password once.")

                LabeledContent("When the screen locks") {
                    Text(store.settings.values.performanceMode == .maximumQuality
                         ? "Playback keeps running behind the lock (Maximum Quality)"
                         : "Playback pauses until you unlock")
                }
                LabeledContent("On unlock") {
                    Text("Your wallpaper resumes automatically")
                }
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("macOS doesn't let third-party apps play video on the Lock Screen — any app claiming to do it is showing a still image. Motionpaper matches it honestly: your lock screen shows the same frame your desktop is playing.")
                    .font(.caption)
            }

            Section {
                Button("Export Poster Frame…") {
                    exportPosterFrame()
                }
                .disabled(isExporting || store.library.wallpapers.isEmpty)

                if isExporting {
                    Text("Exporting…").font(.caption).foregroundStyle(.secondary)
                }
                if let exportResult {
                    Text(exportResult).font(.caption).foregroundStyle(.secondary)
                }

                Button("Open System Wallpaper Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
                }
                .help("Opens System Settings → Wallpaper, where you can add the exported frame as your Lock Screen wallpaper.")

                Text("Closest supported behavior: export a poster frame of your current wallpaper, then set it as the Lock Screen picture in System Settings. Your lock screen will show a matching still image while your desktop keeps playing the live version.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Match your Lock Screen (optional)")
            } footer: {
                Text("Tip: run the same export for your desktop wallpaper to keep a consistent look everywhere macOS requires a still image.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func exportPosterFrame() {
        // Default to the wallpaper on the primary display, else the most recent item.
        let candidates = store.engine.displays.compactMap { display -> Wallpaper? in
            store.library.assignment(displayKey: display.id)?.wallpaperID.flatMap { store.library.wallpaper(id: $0) }
        }
        let fallback = store.library.recentWallpapers.first ?? store.library.wallpapers.first
        guard let wallpaper = candidates.first ?? fallback,
              let sourceURL = store.playableURL(for: wallpaper) else {
            exportResult = "No playable wallpaper found."
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Poster Frame"
        panel.nameFieldStringValue = "\(wallpaper.name) — Poster.png"
        panel.allowedContentTypes = [.png]
        if let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first {
            panel.directoryURL = pictures
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        isExporting = true
        exportResult = nil
        Task {
            do {
                try await PosterFrameExporter.export(sourceURL: sourceURL, to: destination)
                exportResult = "Saved: \(destination.lastPathComponent)"
            } catch {
                exportResult = error.localizedDescription
            }
            isExporting = false
        }
    }
}

// MARK: - Capabilities

/// Feature detection panel — every claim states the technical reality.
private struct CapabilitiesTab: View {
    var body: some View {
        List {
            ForEach(SystemCapabilities.all()) { capability in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(capability.name)
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text(capability.state.label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(badgeColor(capability.state), in: Capsule())
                            .foregroundStyle(.black)
                    }
                    Text(reasonText(capability.state))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
    }

    private func badgeColor(_ state: CapabilityState) -> Color {
        switch state {
        case .supported: .green
        case .experimental: .orange
        case .roadmap: .blue
        case .notSupportedByMacOS: .gray.opacity(0.55)
        }
    }

    private func reasonText(_ state: CapabilityState) -> String {
        switch state {
        case .supported(let reason): reason
        case .notSupportedByMacOS(let reason): reason
        case .experimental(let reason): reason
        case .roadmap(let reason): reason
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @Environment(AppStore.self) private var store
    @State private var loginStatus: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { store.settings.values.launchAtLogin },
                    set: { enabled in setLaunchAtLogin(enabled) }
                ))
                .help("Registers Motionpaper as a login item using the public SMAppService API.")

                Toggle("Start in background", isOn: Binding(
                    get: { store.settings.values.startInBackground },
                    set: { enabled in store.settings.update { $0.startInBackground = enabled } }
                ))
                .help("On launch, don't bring the window forward. Wallpapers start normally.")

                Toggle("Show menu-bar icon", isOn: Binding(
                    get: { store.settings.values.showMenuBarIcon },
                    set: { visible in
                        store.settings.update { $0.showMenuBarIcon = visible }
                        store.menuBar.updateVisibility(visible)
                    }
                ))
                .help("Quick controls live in the menu bar; wallpapers run regardless.")
            } header: {
                Text("Startup")
            } footer: {
                if let loginStatus {
                    Text(loginStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            store.settings.update { $0.launchAtLogin = enabled }
            loginStatus = nil
        } catch {
            loginStatus = "Login item change failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Playback

private struct PlaybackTab: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: Binding(
                    get: { store.settings.values.performanceMode },
                    set: { mode in
                        store.settings.update { $0.performanceMode = mode }
                        store.resource.evaluate()
                    }
                )) {
                    ForEach(PerformanceMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()

                Text(store.settings.values.performanceMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Pause when the screen is locked", isOn: Binding(
                    get: { store.settings.values.pauseWhenLocked },
                    set: { v in
                        store.settings.update { $0.pauseWhenLocked = v }
                        store.resource.evaluate()
                    }
                ))

                Toggle("Pause in Low Power Mode", isOn: Binding(
                    get: { store.settings.values.pauseInLowPowerMode },
                    set: { v in
                        store.settings.update { $0.pauseInLowPowerMode = v }
                        store.resource.evaluate()
                    }
                ))

                Stepper(
                    "Pause on battery below \(store.settings.values.pauseOnBatteryBelowPercent)%",
                    value: Binding(
                        get: { store.settings.values.pauseOnBatteryBelowPercent },
                        set: { v in
                            store.settings.update { $0.pauseOnBatteryBelowPercent = v }
                            store.resource.evaluate()
                        }
                    ),
                    in: 0...100,
                    step: 5
                )
                .help("Set to 0% to never pause for battery level.")
            } header: {
                Text("Performance mode")
            }

            Section {
                Toggle("Wallpaper audio muted", isOn: Binding(
                    get: { store.settings.values.defaultMuted },
                    set: { muted in store.settings.update { $0.defaultMuted = muted } }
                ))
                .help("Wallpaper audio is off by default and never hijacks system audio.")

                Picker("Scaling", selection: Binding(
                    get: { store.settings.values.defaultScaling },
                    set: { mode in store.settings.update { $0.defaultScaling = mode } }
                )) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Storage

private struct StorageTab: View {
    @Environment(AppStore.self) private var store
    @State private var librarySize: Int = 0
    @State private var cacheSize: Int = 0
    @State private var didClearCache = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Location") {
                    HStack {
                        Text(store.paths.appSupport.lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button("Reveal") {
                            NSWorkspace.shared.open(store.paths.appSupport)
                        }
                    }
                }
                LabeledContent("Wallpapers") {
                    Text("\(store.library.wallpapers.count) items · \(ByteCountFormatter.string(fromByteCount: Int64(librarySize), countStyle: .file))")
                }
                LabeledContent("Thumbnail cache") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(cacheSize), countStyle: .file))
                }
                Button("Clear thumbnail cache") {
                    Task {
                        _ = await store.thumbnails.clearAll()
                        await refreshSizes()
                        didClearCache = true
                    }
                }
                if didClearCache {
                    Text("Thumbnails regenerate automatically as the library is browsed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Managed library")
            } footer: {
                Text("Imported videos are copied into the managed library; your original files are never touched. Referenced items stay in place.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await refreshSizes() }
    }

    private func refreshSizes() async {
        let videosDir = store.paths.videos
        librarySize = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: videosDir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
        cacheSize = await store.thumbnails.cacheSizeBytes()
    }
}

// MARK: - Advanced

private struct AdvancedTab: View {
    @Environment(AppStore.self) private var store
    @State private var confirmResetData = false
    @State private var confirmResetAssignments = false
    @State private var statusMessage: String?

    var body: some View {
        Form {
            Section {
                Button("Reindex library") {
                    store.library.revalidate()
                    statusMessage = "Reindexed \(store.library.wallpapers.count) wallpapers."
                }
                .help("Re-checks every wallpaper file and flags missing ones.")

                Button("Recreate wallpaper surfaces") {
                    store.engine.recreateAllSurfaces()
                    statusMessage = "Wallpaper windows recreated."
                }
                .help("Tears down and rebuilds every desktop-level window.")

                Button("Reset display assignments", role: .destructive) {
                    confirmResetAssignments = true
                }
            } header: {
                Text("Maintenance")
            }

            Section {
                Button("Reset all application data…", role: .destructive) {
                    confirmResetData = true
                }
                .help("Deletes wallpapers, thumbnails, playlists, and assignments. Imported source files are untouched.")
            } header: {
                Text("Danger zone")
            }

            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Reset display assignments?",
            isPresented: $confirmResetAssignments,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                store.engine.clearAllAssignments()
                statusMessage = "Display assignments cleared."
            }
        } message: {
            Text("All displays lose their wallpaper. Your library is untouched.")
        }
        .confirmationDialog(
            "Delete all Motionpaper data?",
            isPresented: $confirmResetData,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                store.resetAllData()
                statusMessage = "Application data cleared."
            }
        } message: {
            Text("Removes the managed wallpaper copies, thumbnails, playlists, favorites, and assignments. Original files you imported from are never touched.")
        }
    }
}

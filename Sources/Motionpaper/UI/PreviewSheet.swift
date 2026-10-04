import AVFoundation
import AVKit
import SwiftUI
import MotionpaperKit

// MARK: - AVPlayerLayer host

/// Bare AVPlayerLayer host — no AVKit chrome, our own controls on top.
struct PlayerLayerView: NSViewRepresentable {
    final class PlayerHostView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("unsupported") }

        override func makeBackingLayer() -> CALayer {
            AVPlayerLayer()
        }

        var playerLayer: AVPlayerLayer? {
            layer as? AVPlayerLayer
        }
    }

    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(frame: .zero)
        view.playerLayer?.player = player
        view.playerLayer?.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        nsView.playerLayer?.player = player
        nsView.playerLayer?.videoGravity = .resizeAspect
    }
}

// MARK: - Preview sheet

/// Large in-app preview: looping playback, scrubbing, mute, speed, full-screen,
/// and the complete info panel with apply actions.
struct PreviewSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let wallpaperID: UUID

    @State private var previewPlayer: AVQueuePlayer?
    @State private var previewLooper: AVPlayerLooper?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var isMuted = true
    @State private var volume: Double = 0.5
    @State private var speed: Float = 1
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var timeObserver: Any?
    @State private var statusObservation: NSKeyValueObservation?
    @State private var loadFailed = false
    @State private var fullscreenWindow: FullscreenPreviewWindow?

    private var wallpaper: Wallpaper? {
        store.library.wallpaper(id: wallpaperID)
    }

    var body: some View {
        Group {
            if let wallpaper {
                content(for: wallpaper)
            } else {
                EmptyStateView(icon: "questionmark.square.dashed", title: "Wallpaper unavailable", message: "This item is no longer in the library.")
            }
        }
        .frame(minWidth: 880, idealWidth: 1040, minHeight: 560, idealHeight: 640)
        .onAppear(perform: setUpPlayer)
        .onDisappear(perform: tearDownPlayer)
    }

    private func content(for wallpaper: Wallpaper) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                playerArea(wallpaper)
                infoPanel(wallpaper)
                    .frame(width: 260)
            }
            controlBar
        }
        .background(.black)
        .alert("Rename", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                store.library.rename(id: wallpaperID, to: renameText)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Player area

    private func playerArea(_ wallpaper: Wallpaper) -> some View {
        ZStack {
            Rectangle().fill(.black)
            if let player = previewPlayer {
                PlayerLayerView(player: player)
            }
            if loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.yellow)
                    Text("This video can't be played on your Mac.")
                        .font(.callout.weight(.semibold))
                    Text("The file may be missing, or the codec isn't supported by macOS.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(16)
    }

    // MARK: Controls

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                togglePlay()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 30)
            }
            .buttonStyle(.borderless)
            .disabled(previewPlayer == nil || loadFailed)

            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { newValue in
                        currentTime = newValue
                        if isScrubbing {
                            previewPlayer?.seek(to: CMTime(seconds: newValue, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                        }
                    }
                ),
                in: 0...max(duration, 0.1)
            ) { editing in
                isScrubbing = editing
                if !editing {
                    previewPlayer?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }
            }
            .disabled(duration <= 0)

            Text("\(timeString(currentTime)) / \(timeString(duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)

            Button {
                isMuted.toggle()
                previewPlayer?.isMuted = isMuted
            } label: {
                Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)

            Menu("\(String(format: "%g", speed))×") {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("\(String(format: "%g×", rate))") {
                        speed = Float(rate)
                        if isPlaying { previewPlayer?.rate = speed }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button {
                openFullscreen()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderless)
            .help("Full screen preview")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    /// Fullscreen preview via a dedicated borderless AppKit window.
    private func openFullscreen() {
        fullscreenWindow = FullscreenPreviewWindow()
        fullscreenWindow?.present(player: previewPlayer) {
            fullscreenWindow = nil
        }
    }

    // MARK: Info panel

    private func infoPanel(_ wallpaper: Wallpaper) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(wallpaper.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        store.library.toggleFavorite(id: wallpaperID)
                    } label: {
                        Image(systemName: wallpaper.isFavorite ? "star.fill" : "star")
                            .foregroundStyle(wallpaper.isFavorite ? .yellow : .secondary)
                    }
                    .buttonStyle(.borderless)
                }

                if let displaysUsing = displaysUsing(wallpaper), !displaysUsing.isEmpty {
                    Label("Active on \(displaysUsing.map(\.name).joined(separator: ", "))", systemImage: "display.2")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }

                applySection

                infoTable(wallpaper)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        if let url = store.library.fileURL(for: wallpaper) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button {
                        renameText = wallpaper.name
                        isRenaming = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        store.library.remove(id: wallpaperID, deleteManagedFile: true)
                        tearDownPlayer()
                        dismiss()
                    } label: {
                        Label("Remove from Library", systemImage: "trash")
                    }
                    .disabled(store.library.wallpaper(id: wallpaperID) == nil)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var applySection: some View {
        if wallpaper?.status == .ok {
            HStack {
                if store.engine.displays.count == 1, let only = store.engine.displays.first {
                    Button("Apply") {
                        store.engine.apply(wallpaperID: wallpaperID, toDisplay: only.id)
                    }
                    .controlSize(.large)
                } else {
                    Menu {
                        ForEach(store.engine.displays) { display in
                            Button(display.name) {
                                store.engine.apply(wallpaperID: wallpaperID, toDisplay: display.id)
                            }
                        }
                        Divider()
                        Button("All Displays") {
                            store.engine.applyToAllDisplays(wallpaperID: wallpaperID)
                        }
                    } label: {
                        Text("Apply")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                }
            }
        }
    }

    private func infoTable(_ wallpaper: Wallpaper) -> some View {
        let rows: [(String, String)] = [
            ("Resolution", wallpaper.metadata.resolutionLabel),
            ("Aspect", wallpaper.metadata.aspectRatioLabel),
            ("Duration", wallpaper.metadata.durationLabel),
            ("FPS", wallpaper.metadata.fps.map { String(format: "%.1f", $0) } ?? "—"),
            ("Codec", wallpaper.metadata.codec ?? "—"),
            ("Container", wallpaper.metadata.container ?? "—"),
            ("File size", wallpaper.metadata.fileSizeBytes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "—"),
            ("Orientation", wallpaper.metadata.orientation.rawValue.capitalized),
            ("Source", wallpaper.origin == .wallspaceMigration ? "Wallspace import" : (wallpaper.isManaged ? "Imported (managed copy)" : "Referenced in place")),
            ("Added", wallpaper.addedDateLabel),
            ("Last used", wallpaper.lastUsedDateLabel),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.0) { label, value in
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 82, alignment: .leading)
                    Text(value)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quinary))
    }

    private func displaysUsing(_ wallpaper: Wallpaper) -> [DisplayInfo]? {
        let keys = store.library.assignments
            .filter { $0.wallpaperID == wallpaperID }
            .map(\.displayKey)
        return store.engine.displays.filter { keys.contains($0.id) }
    }

    // MARK: Player lifecycle

    private func setUpPlayer() {
        guard let wallpaper, wallpaper.status == .ok,
              let url = store.library.fileURL(for: wallpaper) else {
            loadFailed = true
            return
        }

        // Reuse the live desktop player when this wallpaper is already active —
        // no duplicated decode for the active wallpaper.
        if let shared = store.engine.activePlayer(forDisplay: store.engine.displays.first(where: { store.engine.currentWallpaperIDs[$0.id] == wallpaperID })?.id ?? "") {
            previewPlayer = (shared as? AVQueuePlayer)
            isMuted = shared.isMuted
            duration = wallpaper.metadata.duration ?? 0
            attachObserver(to: shared)
            return
        }

        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        previewLooper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = isMuted
        player.volume = Float(volume)
        previewPlayer = player
        duration = wallpaper.metadata.duration ?? 0

        statusObservation = player.currentItem?.observe(\.status) { item, _ in
            Task { @MainActor in
                if item.status == .failed { loadFailed = true }
            }
        }
        attachObserver(to: player)
        player.play()
        isPlaying = true
    }

    private func attachObserver(to player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            isPlaying = player.timeControlStatus == .playing
        }
    }

    private func tearDownPlayer() {
        if let observer = timeObserver, let player = previewPlayer {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        previewLooper?.disableLooping()
        previewLooper = nil
        // Only stop players we created (engine-owned ones keep the wallpaper running).
        if previewPlayer !== enginePlayerIfShared() {
            previewPlayer?.pause()
        }
        previewPlayer = nil
    }

    private func enginePlayerIfShared() -> AVQueuePlayer? {
        for display in store.engine.displays {
            if store.engine.currentWallpaperIDs[display.id] == wallpaperID,
               let shared = store.engine.activePlayer(forDisplay: display.id) as? AVQueuePlayer {
                return shared
            }
        }
        return nil
    }

    private func togglePlay() {
        guard let player = previewPlayer else { return }
        if player.timeControlStatus == .playing {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            player.rate = speed
            isPlaying = true
        }
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Fullscreen preview window

/// Dedicated borderless full-screen window for immersive playback
/// (macOS has no SwiftUI fullScreenCover).
@MainActor
final class FullscreenPreviewWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    func present(player: AVPlayer?, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .black
        window.isOpaque = true
        window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: FullscreenPreviewContent(player: player, close: { [weak self] in
            self?.close()
        }))
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func close() {
        window?.orderOut(nil)
        window = nil
        onClose?()
        onClose = nil
    }

    nonisolated func windowDidResignKey(_ notification: Notification) {
        Task { @MainActor in
            close()
        }
    }
}

private struct FullscreenPreviewContent: View {
    let player: AVPlayer?
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                PlayerLayerView(player: player)
                    .ignoresSafeArea()
            }
            Button(action: close) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
            .padding(20)
            .keyboardShortcut(.cancelAction)
        }
    }
}

// MARK: - Date labels

extension Wallpaper {
    var addedDateLabel: String {
        DateFormatter.localizedString(from: addedAt, dateStyle: .medium, timeStyle: .none)
    }

    var lastUsedDateLabel: String {
        guard let lastUsedAt else { return "Never" }
        return DateFormatter.localizedString(from: lastUsedAt, dateStyle: .medium, timeStyle: .none)
    }
}

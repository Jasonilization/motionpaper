import SwiftUI
import MotionpaperKit

/// Dedicated multi-display configuration: one card per connected display with
/// its current wallpaper, playback state, and per-display controls.
struct DisplaysView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if store.library.wallpapers.isEmpty {
                    emptyLibraryHint
                } else {
                    ForEach(store.engine.displays) { display in
                        DisplayCard(display: display)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Displays")
                    .font(.largeTitle.weight(.bold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(store.engine.userPaused ? "Resume All" : "Pause All") {
                store.engine.toggleUserPause()
            }
        }
    }

    private var subtitle: String {
        let count = store.engine.displays.count
        return count == 1 ? "1 display connected" : "\(count) displays connected"
    }

    private var emptyLibraryHint: some View {
        EmptyStateView(
            icon: "display.trianglebadge.exclamationmark",
            title: "Nothing to show yet",
            message: "Import wallpapers first, then assign them to displays from here or from any wallpaper's context menu."
        )
    }
}

// MARK: - Display card

private struct DisplayCard: View {
    @Environment(AppStore.self) private var store
    let display: DisplayInfo
    @State private var isChoosing = false

    private var assignment: DisplayAssignment? {
        store.library.assignment(displayKey: display.id)
    }

    private var wallpaper: Wallpaper? {
        assignment?.wallpaperID.flatMap { store.library.wallpaper(id: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(display.name, systemImage: display.isPrimary ? "display" : "display.2")
                    .font(.headline)
                if display.isPrimary {
                    Text("Primary")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quinary, in: Capsule())
                }
                Spacer()
                Text("\(display.nativeWidth)×\(display.nativeHeight)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                stateBadge
            }

            HStack(spacing: 16) {
                currentWallpaperPreview
                controls
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.quinary))
        .sheet(isPresented: $isChoosing) {
            WallpaperPickerSheet(display: display)
        }
    }

    private var stateBadge: some View {
        let state = store.engine.states[display.id]
        return Group {
            switch state {
            case .playing:
                Label("Playing", systemImage: "play.circle.fill").foregroundStyle(.green)
            case .paused:
                Label("Paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            case .loading:
                Label("Loading…", systemImage: "arrow.triangle.2.circlepath.circle")
            case .failed:
                Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .idle, .none:
                Label("No wallpaper", systemImage: "moon.circle").foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .labelStyle(.titleAndIcon)
    }

    private var currentWallpaperPreview: some View {
        Group {
            if let wallpaper {
                WallpaperThumbnail(wallpaper: wallpaper)
                    .aspectRatio(16 / 10, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomLeading) {
                        Text(wallpaper.name)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .overlay {
                        if case .failed(let reason) = store.engine.states[display.id] {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(.black.opacity(0.6))
                                .overlay(
                                    VStack(spacing: 8) {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.title2)
                                        Text("Wallpaper failed to load")
                                            .font(.callout.weight(.semibold))
                                        Text(reason)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.center)
                                        Button("Retry") {
                                            store.engine.reapply(displayKey: display.id)
                                        }
                                        .controlSize(.small)
                                    }
                                    .padding()
                                )
                        }
                    }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary)
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("No wallpaper set")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                isChoosing = true
            } label: {
                Label(wallpaper == nil ? "Choose Wallpaper…" : "Change Wallpaper…", systemImage: "photo.on.rectangle.angled")
            }

            if wallpaper != nil {
                Picker("Scaling", selection: Binding(
                    get: { assignment?.scaling ?? .fill },
                    set: { store.engine.setScaling(displayKey: display.id, scaling: $0) }
                )) {
                    ForEach(ScalingMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(ScalingMode.allCases.map { "\($0.label): \($0.explanation)" }.joined(separator: "\n"))

                Toggle(isOn: Binding(
                    get: { !(assignment?.isMuted ?? true) },
                    set: { store.engine.setMuted(displayKey: display.id, muted: !$0) }
                )) {
                    Label("Audio", systemImage: assignment?.isMuted == false ? "speaker.wave.2" : "speaker.slash")
                }
                .disabled(store.settings.values.defaultMuted && (assignment?.volume ?? 0) == 0)

                Button(role: .destructive) {
                    store.engine.clear(displayKey: display.id)
                } label: {
                    Label("Remove from this Display", systemImage: "minus.circle")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Wallpaper picker

/// Sheet listing the library for assigning one wallpaper to a specific display.
struct WallpaperPickerSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let display: DisplayInfo

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Choose a wallpaper for “\(display.name)”")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(store.library.wallpapers.filter { $0.status == .ok }) { wallpaper in
                        Button {
                            store.engine.apply(wallpaperID: wallpaper.id, toDisplay: display.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                WallpaperThumbnail(wallpaper: wallpaper)
                                    .aspectRatio(16 / 10, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                Text(wallpaper.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(wallpaper.metadata.resolutionLabel)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
        .frame(minWidth: 720, minHeight: 480)
    }
}

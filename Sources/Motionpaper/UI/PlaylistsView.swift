import SwiftUI
import MotionpaperKit

/// Playlists home: create, edit, enable, and assign auto-changing playlists.
struct PlaylistsView: View {
    @Environment(AppStore.self) private var store
    @State private var editing: UUID?
    @State private var isCreating = false
    @State private var newName = ""

    var body: some View {
        Group {
            if store.library.playlists.isEmpty {
                VStack(spacing: 20) {
                    EmptyStateView(
                        icon: "arrow.triangle.2.circlepath",
                        title: "No playlists yet",
                        message: "Playlists auto-change your wallpaper every few minutes or hours. Create one, add wallpapers, and assign it to a display."
                    )
                    Button {
                        isCreating = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Playlists")
                                    .font(.largeTitle.weight(.bold))
                                Text("Auto-change wallpapers on a schedule")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                isCreating = true
                            } label: {
                                Label("New Playlist", systemImage: "plus")
                            }
                        }
                        ForEach(store.library.playlists) { playlist in
                            PlaylistRow(playlist: playlist, onEdit: { editing = playlist.id })
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 980, alignment: .leading)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .alert("New Playlist", isPresented: $isCreating) {
            TextField("Name", text: $newName)
            Button("Create") {
                let trimmed = newName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    store.library.createPlaylist(name: trimmed)
                }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
        .sheet(item: Binding(
            get: { editing.flatMap { store.library.playlist(id: $0) } },
            set: { editing = $0?.id }
        )) { playlist in
            PlaylistEditorSheet(playlistID: playlist.id)
        }
    }
}

// MARK: - Row

private struct PlaylistRow: View {
    @Environment(AppStore.self) private var store
    let playlist: Playlist
    var onEdit: () -> Void

    private var assignedDisplayNames: [String] {
        store.library.assignments
            .filter { $0.playlistID == playlist.id }
            .compactMap { assignment in store.engine.displays.first { $0.id == assignment.displayKey }?.name }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: playlist.isEnabled ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle")
                .font(.system(size: 26))
                .foregroundStyle(playlist.isEnabled ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(playlist.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("\(playlist.wallpaperIDs.count) wallpapers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(PlaylistAdvancer.intervalLabel(playlist.changeInterval))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quinary, in: Capsule())
                    Text(playlist.order.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !assignedDisplayNames.isEmpty {
                        Label(assignedDisplayNames.joined(separator: ", "), systemImage: "display.2")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            Toggle("Enabled", isOn: Binding(
                get: { playlist.isEnabled },
                set: { enabled in
                    var updated = playlist
                    updated.isEnabled = enabled
                    store.library.update(updated)
                    store.engine.refreshSchedules(for: playlist.id)
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .help("Enable or pause auto-changing")

            Button("Edit") { onEdit() }
            Menu {
                ForEach(store.engine.displays) { display in
                    Button("Assign to \(display.name)") {
                        store.engine.assign(playlistID: playlist.id, toDisplay: display.id)
                    }
                }
                Divider()
                Button(role: .destructive) {
                    var updated = playlist
                    updated.isEnabled = false
                    store.library.update(updated)
                    store.engine.refreshSchedules(for: playlist.id)
                    for assignment in store.library.assignments where assignment.playlistID == playlist.id {
                        var cleared = assignment
                        cleared.playlistID = nil
                        store.library.setAssignment(cleared)
                    }
                } label: {
                    Text("Unassign from all displays")
                }
                Divider()
                Button(role: .destructive) {
                    store.library.deletePlaylist(id: playlist.id)
                } label: {
                    Text("Delete Playlist")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
    }
}

// MARK: - Editor sheet

struct PlaylistEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID

    @State private var name: String = ""
    @State private var order: PlayOrder = .sequential
    @State private var interval: TimeInterval = 0
    @State private var librarySelection: UUID?

    private var playlist: Playlist? {
        store.library.playlist(id: playlistID)
    }

    private var playlistWallpapers: [Wallpaper] {
        (playlist?.wallpaperIDs ?? []).compactMap { store.library.wallpaper(id: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Playlist name", text: $name)
                    .font(.headline)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                Button("Done") {
                    persist()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            HStack(alignment: .top, spacing: 0) {
                // Left: picker for adding wallpapers
                VStack(alignment: .leading, spacing: 0) {
                    Text("Library")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(store.library.wallpapers.filter { $0.status == .ok }) { wallpaper in
                                Button {
                                    librarySelection = wallpaper.id
                                    add(wallpaper)
                                } label: {
                                    HStack {
                                        WallpaperThumbnail(wallpaper: wallpaper)
                                            .frame(width: 88, height: 50)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(wallpaper.name)
                                                .font(.callout)
                                                .lineLimit(1)
                                            Text(wallpaper.metadata.resolutionLabel)
                                                .font(.caption2.monospacedDigit())
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(.green)
                                    }
                                    .padding(6)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity)

                Divider()

                // Right: current contents + settings
                VStack(alignment: .leading, spacing: 12) {
                    Text("In this playlist (\(playlistWallpapers.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    List {
                        ForEach(playlistWallpapers) { wallpaper in
                            HStack {
                                WallpaperThumbnail(wallpaper: wallpaper)
                                    .frame(width: 88, height: 50)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(wallpaper.name)
                                    .font(.callout)
                                Spacer()
                                Button {
                                    remove(wallpaper)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                        .onMove { indices, destination in
                            move(indices, destination)
                        }
                    }
                    .listStyle(.inset)
                    .frame(minHeight: 180)

                    Picker("Order", selection: $order) {
                        ForEach(PlayOrder.allCases) { o in
                            Text(o.label).tag(o)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Change every", selection: $interval) {
                        Text("Manual only").tag(TimeInterval(0))
                        ForEach(PlaylistAdvancer.intervalChoices, id: \.self) { choice in
                            Text(PlaylistAdvancer.intervalLabel(choice)).tag(choice)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 900, idealWidth: 1000, minHeight: 520, idealHeight: 600)
        .onAppear {
            if let playlist {
                name = playlist.name
                order = playlist.order
                interval = playlist.changeInterval
            }
        }
    }

    private func persist() {
        guard var updated = playlist else { return }
        updated.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? updated.name : name
        updated.order = order
        updated.changeInterval = interval
        store.library.update(updated)
        store.engine.refreshSchedules(for: updated.id)
    }

    private func add(_ wallpaper: Wallpaper) {
        guard var updated = playlist else { return }
        guard !updated.wallpaperIDs.contains(wallpaper.id) else { return }
        updated.wallpaperIDs.append(wallpaper.id)
        store.library.update(updated)
    }

    private func remove(_ wallpaper: Wallpaper) {
        guard var updated = playlist else { return }
        updated.wallpaperIDs.removeAll { $0 == wallpaper.id }
        store.library.update(updated)
    }

    private func move(_ indices: IndexSet, _ destination: Int) {
        guard var updated = playlist else { return }
        updated.wallpaperIDs.move(fromOffsets: indices, toOffset: destination)
        store.library.update(updated)
    }
}

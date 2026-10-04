import SwiftUI
import MotionpaperKit

// MARK: - Thumbnail

/// Loads (and lazily generates) a wallpaper's cached JPEG thumbnail.
struct WallpaperThumbnail: View {
    let wallpaper: Wallpaper
    @Environment(AppStore.self) private var store
    @State private var imageData: Data?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor)) // solid background, never white flash
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .task(id: wallpaper.id) {
            guard wallpaper.status == .ok, let url = store.playableURL(for: wallpaper) else { return }
            let data = await store.thumbnails.thumbnail(for: wallpaper, sourceURL: url)
            withAnimation(.easeIn(duration: 0.15)) {
                imageData = data
            }
        }
    }

    @ViewBuilder private var placeholder: some View {
        switch wallpaper.status {
        case .ok:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .missing:
            Label(wallpaper.status.label, systemImage: "questionmark.square.dashed")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .corrupt, .unsupported:
            Label(wallpaper.status.label, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Card

/// Large visual card for one wallpaper in the grid.
struct WallpaperCard: View {
    let wallpaper: Wallpaper
    var isActive: Bool = false
    var onRemove: ((Wallpaper) -> Void)?

    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail
            infoRow
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quinary)
        )
        .overlay(alignment: .topLeading) { resolutionBadge }
        .overlay(alignment: .topTrailing) { favoriteButton }
        .overlay(alignment: .bottomTrailing) { activeBadge }
        .contextMenu { contextActions }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(wallpaper.name), \(wallpaper.metadata.resolutionLabel), \(wallpaper.metadata.durationLabel)")
    }

    private var thumbnail: some View {
        WallpaperThumbnail(wallpaper: wallpaper)
            .aspectRatio(16 / 10, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(6)
    }

    private var infoRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(wallpaper.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(wallpaper.metadata.durationLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let codec = wallpaper.metadata.codec { parts.append(codec) }
        parts.append(wallpaper.isManaged ? "Managed" : "Referenced")
        if wallpaper.status != .ok { parts.append(wallpaper.status.label) }
        return parts.joined(separator: " · ")
    }

    private var resolutionBadge: some View {
        Text(wallpaper.metadata.resolutionLabel)
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
    }

    private var favoriteButton: some View {
        Button {
            store.library.toggleFavorite(id: wallpaper.id)
        } label: {
            Image(systemName: wallpaper.isFavorite ? "star.fill" : "star")
                .foregroundStyle(wallpaper.isFavorite ? Color.yellow : Color.secondary)
        }
        .buttonStyle(.plain)
        .padding(10)
        .help(wallpaper.isFavorite ? "Remove from favorites" : "Add to favorites")
    }

    @ViewBuilder private var activeBadge: some View {
        if isActive {
            Label("Active", systemImage: "circle.fill")
                .font(.caption2.weight(.semibold))
                .labelStyle(.iconOnly)
                .foregroundStyle(.green)
                .help("Currently applied to a display")
                .padding(10)
        }
    }

    @ViewBuilder private var contextActions: some View {
        applyMenu
        Divider()
        Button("Reveal in Finder") {
            if let url = store.library.fileURL(for: wallpaper) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
        Button(wallpaper.isFavorite ? "Remove from Favorites" : "Add to Favorites") {
            store.library.toggleFavorite(id: wallpaper.id)
        }
        Divider()
        Button("Remove from Library…", role: .destructive) {
            onRemove?(wallpaper)
        }
    }

    @ViewBuilder private var applyMenu: some View {
        if wallpaper.status == .ok {
            Menu("Apply to Display") {
                ForEach(store.engine.displays) { display in
                    Button(display.name) {
                        store.engine.apply(wallpaperID: wallpaper.id, toDisplay: display.id)
                    }
                }
                Divider()
                Button("All Displays") {
                    store.engine.applyToAllDisplays(wallpaperID: wallpaper.id)
                }
            }
        } else {
            Button("Apply to Display") {}.disabled(true)
        }
    }
}

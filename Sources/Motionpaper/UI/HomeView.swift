import SwiftUI
import MotionpaperKit

/// Home: current wallpaper hero, recents, and favorites at a glance.
struct HomeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.library.wallpapers.isEmpty {
                VStack(spacing: 20) {
                    EmptyStateView(
                        icon: "film.stack",
                        title: "Welcome to Motionpaper",
                        message: "Add your first video wallpaper by dragging files into the window, importing from your Mac, or importing from Wallspace."
                    )
                    ImportMenu()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header
                        if !store.library.recentWallpapers.isEmpty {
                            strip(title: "Recently Used", items: store.library.recentWallpapers)
                        }
                        if !store.library.favoriteWallpapers.isEmpty {
                            strip(title: "Favorites", items: store.library.favoriteWallpapers)
                        }
                        if !store.library.wallpapers.isEmpty {
                            strip(title: "All Wallpapers", items: Array(store.library.wallpapers.sorted { $0.addedAt > $1.addedAt }.prefix(12)))
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .overlay(alignment: .top) { ImportStatusOverlay() }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { !$0.hasDirectoryPath }
            guard !files.isEmpty else { return false }
            Task { await store.importer.importFiles(files, into: store.library, mode: .copy) }
            return true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Home")
                .font(.largeTitle.weight(.bold))
            Text("\(store.library.wallpapers.count) wallpapers in your library")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func strip(title: String, items: [Wallpaper]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(items) { wallpaper in
                        VStack(alignment: .leading, spacing: 6) {
                            WallpaperThumbnail(wallpaper: wallpaper)
                                .frame(width: 260, height: 150)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text(wallpaper.name)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .padding(8)
                                        .frame(maxWidth: 252, alignment: .leading)
                                        .background(
                                            LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                                        )
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                            Text(wallpaper.metadata.resolutionLabel)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

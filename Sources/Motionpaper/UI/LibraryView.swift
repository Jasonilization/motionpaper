import SwiftUI
import MotionpaperKit

// MARK: - Filter models

enum ResolutionFilter: String, CaseIterable, Identifiable {
    case any, p1080, p1440, uhd4k
    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any resolution"
        case .p1080: "1080p+"
        case .p1440: "1440p+"
        case .uhd4k: "4K+"
        }
    }

    func matches(_ wallpaper: Wallpaper) -> Bool {
        switch self {
        case .any: true
        case .p1080: wallpaper.metadata.is1080pOrBetter
        case .p1440: wallpaper.metadata.is1440pOrBetter
        case .uhd4k: wallpaper.metadata.is4KOrBetter
        }
    }
}

enum OrientationFilter: String, CaseIterable, Identifiable {
    case any, landscape, portrait
    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "Any orientation"
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        }
    }

    func matches(_ wallpaper: Wallpaper) -> Bool {
        switch self {
        case .any: true
        case .landscape: wallpaper.metadata.orientation == .landscape
        case .portrait: wallpaper.metadata.orientation == .portrait
        }
    }
}

enum StateFilter: String, CaseIterable, Identifiable {
    case any, imported, recent
    var id: String { rawValue }

    var label: String {
        switch self {
        case .any: "All sources"
        case .imported: "Imported only"
        case .recent: "Recently used"
        }
    }

    func matches(_ wallpaper: Wallpaper, recents: Set<UUID>) -> Bool {
        switch self {
        case .any: true
        case .imported: wallpaper.origin == .imported || wallpaper.origin == .folderImport
        case .recent: recents.contains(wallpaper.id)
        }
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case dateAddedDesc
    case dateAddedAsc
    case nameAsc
    case durationDesc
    case resolutionDesc

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dateAddedDesc: "Newest"
        case .dateAddedAsc: "Oldest"
        case .nameAsc: "Name"
        case .durationDesc: "Longest"
        case .resolutionDesc: "Highest resolution"
        }
    }
}

// MARK: - Library view

struct LibraryView: View {
    enum Preset { case all, favorites }

    var preset: Preset = .all

    @Environment(AppStore.self) private var store
    @State private var searchText = ""
    @State private var resolution = ResolutionFilter.any
    @State private var orientation = OrientationFilter.any
    @State private var sourceState = StateFilter.any
    @State private var sort = SortOption.dateAddedDesc
    @State private var pendingRemoval: Wallpaper?
    @State private var showDropHighlight = false
    @State private var previewingWallpaperID: UUID?

    var body: some View {
        Group {
            if filtered.isEmpty {
                emptyState
            } else {
                grid
            }
        }
        .sheet(item: Binding(
            get: { previewingWallpaperID.flatMap { store.library.wallpaper(id: $0) } },
            set: { previewingWallpaperID = $0?.id }
        )) { wallpaper in
            PreviewSheet(wallpaperID: wallpaper.id)
        }
        .frame(minWidth: 640, minHeight: 420)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search wallpapers")
        .toolbar { toolbarContent }
        .overlay(alignment: .top) { ImportStatusOverlay() }
        .overlay {
            if showDropHighlight {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter { !$0.hasDirectoryPath }
            guard !files.isEmpty else { return false }
            Task { await store.importer.importFiles(files, into: store.library, mode: .copy) }
            return true
        } isTargeted: { hovering in
            showDropHighlight = hovering
        }
        .confirmationDialog(
            "Remove “\(pendingRemoval?.name ?? "")” from your library?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = pendingRemoval {
                    withAnimation {
                        store.library.remove(id: item.id, deleteManagedFile: true)
                    }
                }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if pendingRemoval?.isManaged == true {
                Text("The imported copy in your Motionpaper library will be deleted. Originals you imported from are never touched.")
            } else {
                Text("The file stays where it is — only the library entry is removed.")
            }
        }
    }

    // MARK: Data

    @MainActor private var filtered: [Wallpaper] {
        var items = store.library.wallpapers
        if preset == .favorites {
            items = items.filter(\.isFavorite)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !query.isEmpty {
            items = items.filter { wallpaper in
                wallpaper.name.lowercased().contains(query)
                    || wallpaper.tags.contains { $0.lowercased().contains(query) }
                    || wallpaper.metadata.resolutionLabel.lowercased().contains(query)
                    || (wallpaper.metadata.codec?.lowercased().contains(query) ?? false)
            }
        }
        let recents = Set(store.library.recents)
        items = items.filter { resolution.matches($0) && orientation.matches($0) && sourceState.matches($0, recents: recents) }
        return items.sorted(by: sort)
    }

    private var activeWallpaperIDs: Set<UUID> {
        Set(store.library.assignments.compactMap(\.wallpaperID))
    }

    private func sort(_ lhs: Wallpaper, _ rhs: Wallpaper) -> Bool {
        switch sort {
        case .dateAddedDesc: lhs.addedAt > rhs.addedAt
        case .dateAddedAsc: lhs.addedAt < rhs.addedAt
        case .nameAsc: lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .durationDesc: (lhs.metadata.duration ?? 0) > (rhs.metadata.duration ?? 0)
        case .resolutionDesc: lhs.metadata.shortEdge > rhs.metadata.shortEdge
        }
    }

    // MARK: Views

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], spacing: 16) {
                ForEach(filtered) { wallpaper in
                    WallpaperCard(wallpaper: wallpaper, isActive: activeWallpaperIDs.contains(wallpaper.id)) { item in
                        pendingRemoval = item
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { previewingWallpaperID = wallpaper.id }
                }
            }
            .padding(24)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if preset == .favorites && !store.library.wallpapers.isEmpty {
            EmptyStateView(
                icon: "star",
                title: "No favorites yet",
                message: "Star wallpapers in your library and they'll show up here."
            )
        } else if hasActiveFilters {
            EmptyStateView(
                icon: "line.3.horizontal.decrease.circle",
                title: "No matches",
                message: "No wallpapers match your search or filters. Try clearing them."
            )
        } else {
            VStack(spacing: 20) {
                EmptyStateView(
                    icon: "film.stack",
                    title: "Your library is empty",
                    message: "Drag videos anywhere onto this window, or import from your Mac. Motionpaper copies files into its own library so your originals stay untouched."
                )
                ImportMenu()
            }
        }
    }

    private var hasActiveFilters: Bool {
        !searchText.isEmpty
            || resolution != .any
            || orientation != .any
            || sourceState != .any
            || (preset == .favorites && !store.library.wallpapers.isEmpty)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Sort", selection: $sort) {
                ForEach(SortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.menu)

            Menu {
                Picker("Resolution", selection: $resolution) {
                    ForEach(ResolutionFilter.allCases) { f in Text(f.label).tag(f) }
                }
                Picker("Orientation", selection: $orientation) {
                    ForEach(OrientationFilter.allCases) { f in Text(f.label).tag(f) }
                }
                Picker("Source", selection: $sourceState) {
                    ForEach(StateFilter.allCases) { f in Text(f.label).tag(f) }
                }
            } label: {
                Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
            }

            ImportMenu()
        }
    }
}

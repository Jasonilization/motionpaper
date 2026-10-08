import SwiftUI

// MARK: - Navigation

enum SidebarSection: Hashable, Identifiable {
    case home
    case library
    case favorites
    case playlists
    case displays
    case collection(UUID)

    var id: String {
        switch self {
        case .home: "home"
        case .library: "library"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .displays: "displays"
        case .collection(let id): "collection-\(id.uuidString)"
        }
    }

    var label: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .favorites: "Favorites"
        case .playlists: "Playlists"
        case .displays: "Displays"
        case .collection: "Collection"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .favorites: "star"
        case .playlists: "arrow.triangle.2.circlepath"
        case .displays: "display.2"
        case .collection: "rectangle.stack"
        }
    }

    static var mainSections: [SidebarSection] {
        [.home, .library, .favorites, .playlists, .displays]
    }
}

// MARK: - Root

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var section: SidebarSection = .home

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $section)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            switch section {
            case .home:
                HomeView()
            case .library:
                LibraryView()
            case .favorites:
                LibraryView(preset: .favorites)
            case .playlists:
                PlaylistsView()
            case .displays:
                DisplaysView()
            case .collection(let id):
                LibraryView(collectionID: id)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

private struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: SidebarSection

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.mainSections) { section in
                Label(section.label, systemImage: section.icon)
                    .padding(.vertical, 3)
            }

            if !store.library.collections.isEmpty {
                Section("Collections") {
                    ForEach(store.library.collections) { collection in
                        Label(collection.name, systemImage: "rectangle.stack")
                            .padding(.vertical, 2)
                            .contextMenu {
                                Button("Add Selected Wallpapers…") {
                                    selection = .collection(collection.id)
                                }
                                Divider()
                                Button(role: .destructive) {
                                    store.library.deleteCollection(id: collection.id)
                                } label: {
                                    Text("Delete Collection")
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("Motionpaper")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
        }
    }
}

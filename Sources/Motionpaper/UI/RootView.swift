import SwiftUI

// MARK: - Navigation

enum SidebarSection: String, Hashable, CaseIterable, Identifiable {
    case home
    case library
    case favorites
    case displays

    var id: String { rawValue }

    var label: String {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .favorites: "Favorites"
        case .displays: "Displays"
        }
    }

    var icon: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .favorites: "star"
        case .displays: "display.2"
        }
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
            case .displays:
                DisplaysView()
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

private struct SidebarView: View {
    @Binding var selection: SidebarSection

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases) { section in
                Label(section.label, systemImage: section.icon)
                    .padding(.vertical, 3)
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

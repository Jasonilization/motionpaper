import SwiftUI
import MotionpaperKit

/// Opt-in online gallery: NASA (no key), Pixabay & Pexels (your own local keys).
///
/// The app is offline-first: nothing here runs until you open this section,
/// and the only network activity is the search you make and the file you add.
struct GalleryView: View {
    @Environment(AppStore.self) private var store

    @State private var source: GallerySource = .nasa
    @State private var query = ""
    @State private var results: [GalleryItem] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var adding: Set<String> = []
    @State private var added: Set<String> = []
    @State private var addError: String?

    private let service = GalleryService()
    private let columns = [GridItem(.adaptive(minimum: 260), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if results.isEmpty && !isSearching {
                emptyState
            } else {
                resultsGrid
            }
        }
        .frame(minWidth: 640, minHeight: 420)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker("Source", selection: $source) {
                    ForEach(GallerySource.allCases) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                TextField("Search wallpapers — e.g. aurora, ocean, city", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }

                Button {
                    search()
                } label: {
                    if isSearching {
                        ProgressView().controlSize(.small).frame(width: 34)
                    } else {
                        Text("Search").frame(width: 34)
                    }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
            }

            if source.requiresAPIKey {
                apiKeyRow
            }

            if let searchError {
                Text(searchError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let addError {
                Text(addError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder private var apiKeyRow: some View {
        HStack(spacing: 10) {
            Label("\(source.label) API key", systemImage: "key")
                .font(.caption)
                .foregroundStyle(.secondary)
            SecureField("Paste your free API key", text: Binding(
                get: {
                    switch source {
                    case .pixabay: store.settings.values.pixabayAPIKey
                    case .pexels: store.settings.values.pexelsAPIKey
                    case .nasa: ""
                    }
                },
                set: { newValue in
                    store.settings.update { settings in
                        switch source {
                        case .pixabay: settings.pixabayAPIKey = newValue
                        case .pexels: settings.pexelsAPIKey = newValue
                        case .nasa: break
                        }
                    }
                }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 280)

            Text("Stored locally on your Mac; only ever sent to \(source.host) as a query parameter. Get a free key at their developer pages.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: States

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Search the free wallpaper galleries")
                .font(.title3.weight(.semibold))
            Text("NASA needs no key. Pixabay and Pexels need your own free API key. The gallery only touches the network while you're using it — everything else in Motionpaper stays offline.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(results) { item in
                    GalleryCard(item: item,
                                 isAdding: adding.contains(item.id),
                                 isAdded: added.contains(item.id)) {
                        add(item)
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: Actions

    private func search() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        searchError = nil
        let pixabayKey = store.settings.values.pixabayAPIKey
        let pexelsKey = store.settings.values.pexelsAPIKey
        let currentSource = source
        let service = service
        let q = trimmed
        Task {
            do {
                let found = try await service.search(
                    source: currentSource, query: q,
                    pixabayKey: pixabayKey, pexelsKey: pexelsKey
                )
                results = found
                added = []
            } catch {
                searchError = error.localizedDescription
                results = []
            }
            isSearching = false
        }
    }

    private func add(_ item: GalleryItem) {
        guard !adding.contains(item.id) else { return }
        adding.insert(item.id)
        addError = nil
        let service = service
        Task {
            do {
                let tempURL = try await service.download(item)
                await store.importer.importFiles([tempURL], into: store.library, mode: .copy)
                try? FileManager.default.removeItem(at: tempURL)
                added.insert(item.id)
            } catch {
                addError = "Couldn't add “\(item.title)”: \(error.localizedDescription)"
            }
            adding.remove(item.id)
        }
    }
}

// MARK: - Card

private struct GalleryCard: View {
    let item: GalleryItem
    let isAdding: Bool
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.quaternary)
                if let thumbURL = item.thumbnailURL {
                    AsyncImage(url: thumbURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Image(systemName: "photo")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(height: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if let duration = item.durationLabel {
                    Text(duration)
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(6)
                }
                if isAdded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title)
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            .aspectRatio(16 / 10, contentMode: .fit)

            Text(item.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            HStack {
                Text(item.source.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let author = item.author {
                    Text(author)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    onAdd()
                } label: {
                    if isAdding {
                        ProgressView().controlSize(.small)
                    } else if isAdded {
                        Label("Added", systemImage: "checkmark")
                    } else {
                        Label("Add", systemImage: "plus")
                    }
                }
                .controlSize(.small)
                .disabled(isAdding || isAdded)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.quinary))
    }
}

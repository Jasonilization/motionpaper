import AppKit
import SwiftUI
import MotionpaperKit

// MARK: - Pickers

@MainActor
enum FilePickers {
    /// Multi-select video file picker. Returns chosen URLs (empty if cancelled).
    static func pickVideos() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Import Videos"
        panel.message = "Choose video files to add to your Motionpaper library"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.allowedContentTypes = [.movie, .video]
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    /// Folder picker for recursive import. Returns nil if cancelled.
    static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Import Folder"
        panel.message = "Motionpaper will scan this folder for supported videos"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }
}

// MARK: - Import menu

/// Reusable import actions (toolbar + empty states).
struct ImportMenu: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            Button("Import Videos…") { importFiles(mode: .copy) }
            Button("Import Without Copying…") {
                importFiles(mode: .reference)
            }
            Divider()
            Button("Import Folder…") { importFolder() }
        } label: {
            Label("Import", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(store.importer.isRunning)
    }

    private func importFiles(mode: ImportManager.Mode) {
        let urls = FilePickers.pickVideos()
        guard !urls.isEmpty else { return }
        Task {
            await store.importer.importFiles(urls, into: store.library, mode: mode)
        }
    }

    private func importFolder() {
        guard let folder = FilePickers.pickFolder() else { return }
        let urls = ImportManager.discoverVideos(in: folder)
        guard !urls.isEmpty else { return }
        Task {
            await store.importer.importFiles(urls, into: store.library, mode: .copy)
        }
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Import progress + outcomes

/// Slim progress bar + per-file outcome summary for import batches.
struct ImportStatusOverlay: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 8) {
            if store.importer.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Importing…", systemImage: "arrow.down.circle")
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text("\(store.importer.completedCount)/\(store.importer.totalCount)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(store.importer.completedCount), total: Double(max(store.importer.totalCount, 1)))
                }
                .padding(12)
                .frame(width: 300)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else if !store.importer.outcomes.isEmpty {
                outcomeSummary
            }
        }
        .padding(.top, 10)
        .animation(.snappy(duration: 0.2), value: store.importer.isRunning)
        .animation(.snappy(duration: 0.2), value: store.importer.outcomes)
    }

    private var outcomeSummary: some View {
        let outcomes = store.importer.outcomes
        let imported = outcomes.filter {
            if case .imported = $0.result { return true }
            return false
        }.count
        let skipped = outcomes.count - imported
        var parts = ["\(imported) imported"]
        if skipped > 0 { parts.append("\(skipped) skipped") }

        return HStack(spacing: 8) {
            Label(parts.joined(separator: " · "), systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
            Button {
                store.importer.resetOutcomes()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

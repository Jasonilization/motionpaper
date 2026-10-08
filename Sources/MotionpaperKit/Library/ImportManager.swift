import AppKit
import Foundation

/// Imports video files into the library.
///
/// Copy mode moves bytes into the managed `Videos/` directory (the original is
/// never touched); reference mode points at the file where it lives. Duplicate
/// detection uses SHA-256, so re-importing the same file never duplicates work.
@MainActor @Observable
public final class ImportManager {
    public enum Mode: String, Sendable {
        case copy
        case reference
    }

    public struct Outcome: Identifiable, Equatable, Sendable {
        public enum Result: Equatable, Sendable {
            case imported
            case duplicate
            case unsupported(String)
        }

        public let id = UUID()
        public let fileName: String
        public let result: Result
        public var description: String {
            switch result {
            case .imported: "Imported"
            case .duplicate: "Skipped — already in library"
            case .unsupported(let reason): "Skipped — \(reason)"
            }
        }
    }

    public private(set) var isRunning = false
    public private(set) var completedCount = 0
    public private(set) var totalCount = 0
    public private(set) var outcomes: [Outcome] = []
    /// Set when a real error interrupts a batch (individual failures become outcomes).
    public private(set) var lastError: String?

    public init() {}

    /// Imports a batch of file URLs. Always safe to call with mixed/invalid URLs —
    /// each file yields an individual outcome.
    public func importFiles(_ urls: [URL], into store: LibraryStore, mode: Mode = .copy) async {
        guard !isRunning else { return }
        let candidates = urls.filter { !$0.hasDirectoryPath }
        guard !candidates.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }
        completedCount = 0
        totalCount = candidates.count
        outcomes = []
        lastError = nil

        for url in candidates {
            await importOne(url, into: store, mode: mode)
            completedCount += 1
        }
        AppLog.importer.info("Import finished: \(self.completedCount)/\(self.totalCount)")
    }

    private func importOne(_ url: URL, into store: LibraryStore, mode: Mode) async {
        guard MetadataExtractor.isLikelyVideoFile(url: url) else {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .unsupported("not a video file")))
            return
        }

        // Probe with AVFoundation — authoritative support check.
        let metadata: VideoMetadata
        do {
            metadata = try await MetadataExtractor.probe(url: url)
        } catch let error as MetadataExtractor.ProbeError {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .unsupported(error.description)))
            return
        } catch {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .unsupported(error.localizedDescription)))
            return
        }

        // Content hash for de-duplication (streamed, off the main actor).
        let hash: String?
        do {
            hash = try await Task.detached(priority: .utility) {
                try FileHasher.sha256(url: url)
            }.value
        } catch {
            AppLog.importer.warning("Hashing failed (importing without dedupe check): \(error)")
            hash = nil
        }
        if let hash, store.wallpapers.contains(where: { $0.contentHash == hash }) {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .duplicate))
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()

        switch mode {
        case .copy:
            let id = UUID()
            let fileName = "\(id.uuidString).\(ext)"
            let destination = store.storagePaths.videoURL(for: fileName)
            do {
                let copied: Void = try await Task.detached(priority: .utility) {
                    let fm = FileManager.default
                    if fm.fileExists(atPath: destination.path) {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    try fm.copyItem(at: url, to: destination)
                }.value
                _ = copied
                let wallpaper = Wallpaper(
                    id: id,
                    name: name,
                    fileName: fileName,
                    isManaged: true,
                    origin: .imported,
                    metadata: metadata,
                    contentHash: hash,
                    originalLocation: url.path
                )
                store.add(wallpaper)
                outcomes.append(Outcome(fileName: name, result: .imported))
                AppLog.importer.info("Imported (copy): \(name, privacy: .public)")
            } catch {
                outcomes.append(Outcome(fileName: name, result: .unsupported("copy failed: \(error.localizedDescription)")))
                AppLog.importer.error("Copy failed for \(url.path, privacy: .public): \(error)")
            }

        case .reference:
            let wallpaper = Wallpaper(
                name: name,
                referencedPath: url.path,
                isManaged: false,
                origin: .imported,
                metadata: metadata,
                contentHash: hash,
                originalLocation: url.path
            )
            store.add(wallpaper)
            outcomes.append(Outcome(fileName: name, result: .imported))
            AppLog.importer.info("Imported (reference): \(name, privacy: .public)")
        }
    }

    /// Imports a PNG sprite sheet as an animated wallpaper. Copies the file
    /// into the managed library with a default 4×2 grid at 8 fps — the editor
    /// sheet lets the user correct the grid before applying.
    @discardableResult
    public func importSpriteSheet(_ url: URL, into store: LibraryStore) async -> Wallpaper? {
        guard !isRunning else { return nil }
        guard let nsImage = NSImage(contentsOf: url) else {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .unsupported("not a readable image")))
            return nil
        }
        let width = Int(nsImage.size.width)
        let height = Int(nsImage.size.height)

        let hash: String? = try? await Task.detached(priority: .utility) {
            try FileHasher.sha256(url: url)
        }.value
        if let hash, store.wallpapers.contains(where: { $0.contentHash == hash }) {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .duplicate))
            return nil
        }

        let id = UUID()
        let fileName = "\(id.uuidString).png"
        let destination = store.storagePaths.videoURL(for: fileName)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            outcomes.append(Outcome(fileName: url.lastPathComponent, result: .unsupported("copy failed: \(error.localizedDescription)")))
            return nil
        }

        let name = url.deletingPathExtension().lastPathComponent
        let metadata = VideoMetadata(
            width: width,
            height: height,
            duration: nil,
            fps: nil,
            fileSizeBytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil,
            codec: nil,
            container: "PNG"
        )
        let wallpaper = Wallpaper(
            id: id,
            name: name,
            fileName: fileName,
            isManaged: true,
            origin: .imported,
            metadata: metadata,
            contentHash: hash,
            originalLocation: url.path,
            kind: .spriteSheet,
            sprite: Wallpaper.SpriteMetadata(columns: 4, rows: 2, framesPerSecond: 8)
        )
        store.add(wallpaper)
        outcomes.append(Outcome(fileName: name, result: .imported))
        AppLog.importer.info("Imported sprite sheet: \(name, privacy: .public)")
        return wallpaper
    }

    /// Recursively discovers candidate video files inside a folder, skipping
    /// packages/bundles and hidden directories. Used by folder import and migration.
    public nonisolated static func discoverVideos(in folder: URL) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        guard let enumerator = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey], options: options) else {
            return []
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if let isDir = values?.isDirectory, isDir { continue }
            guard values?.isRegularFile == true else { continue }
            if MetadataExtractor.isLikelyVideoFile(url: url) {
                results.append(url)
            }
        }
        return results
    }

    public func resetOutcomes() {
        outcomes = []
    }
}

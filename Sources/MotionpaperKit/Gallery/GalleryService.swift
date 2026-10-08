import Foundation

/// Opt-in online wallpaper gallery.
///
/// Privacy model (mirrors the app's offline-first core): the gallery only
/// touches the network while the user is actively browsing it — a search hits
/// exactly one API host, and adding a wallpaper downloads exactly one file.
/// API keys are stored locally and only ever sent to their own service as
/// query parameters. Nothing else in Motionpaper makes any connection.

// MARK: - Sources

public enum GallerySource: String, CaseIterable, Identifiable, Sendable {
    case nasa
    case pixabay
    case pexels

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .nasa: "NASA"
        case .pixabay: "Pixabay"
        case .pexels: "Pexels"
        }
    }

    public var host: String {
        switch self {
        case .nasa: "images-api.nasa.gov"
        case .pixabay: "pixabay.com"
        case .pexels: "api.pexels.com"
        }
    }

    public var requiresAPIKey: Bool {
        self != .nasa
    }
}

// MARK: - Items

public struct GalleryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let source: GallerySource
    public let thumbnailURL: URL?
    public let downloadURL: URL
    public let durationSeconds: Double?
    public let author: String?

    public init(id: String, title: String, source: GallerySource,
                thumbnailURL: URL?, downloadURL: URL,
                durationSeconds: Double? = nil, author: String? = nil) {
        self.id = id
        self.title = title
        self.source = source
        self.thumbnailURL = thumbnailURL
        self.downloadURL = downloadURL
        self.durationSeconds = durationSeconds
        self.author = author
    }

    public var durationLabel: String? {
        guard let durationSeconds, durationSeconds > 0 else { return nil }
        let total = Int(durationSeconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Service

public struct GalleryService: Sendable {
    public enum GalleryError: Error, CustomStringConvertible, Sendable, Equatable {
        case badURL
        case http(Int)
        case missingAPIKey
        case noResults
        case downloadFailed(String)

        public var description: String {
            switch self {
            case .badURL: "Couldn't build the request URL."
            case .http(let code): "The service returned HTTP \(code)."
            case .missingAPIKey: "This source needs an API key (Gallery settings below)."
            case .noResults: "No videos found."
            case .downloadFailed(let reason): "Download failed: \(reason)"
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: Search

    public func search(
        source: GallerySource,
        query: String,
        pixabayKey: String = "",
        pexelsKey: String = ""
    ) async throws -> [GalleryItem] {
        switch source {
        case .nasa:
            return try await searchNASA(query: query)
        case .pixabay:
            guard !pixabayKey.isEmpty else { throw GalleryError.missingAPIKey }
            return try await searchPixabay(query: query, key: pixabayKey)
        case .pexels:
            guard !pexelsKey.isEmpty else { throw GalleryError.missingAPIKey }
            return try await searchPexels(query: query, key: pexelsKey)
        }
    }

    private func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GalleryError.downloadFailed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GalleryError.http(http.statusCode)
        }
        return (data, http)
    }

    // MARK: NASA (no key)

    private func searchNASA(query: String) async throws -> [GalleryItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let searchURL = URL(string: "https://images-api.nasa.gov/search?q=\(encoded)&media_type=video") else {
            throw GalleryError.badURL
        }
        let (data, _) = try await getJSON(searchURL)

        struct NASAResponse: Decodable {
            struct Collection: Decodable {
                struct Item: Decodable {
                    struct ItemData: Decodable {
                        let nasa_id: String
                        let title: String
                        let secondaryCreator: String?

                        enum CodingKeys: String, CodingKey {
                            case nasa_id
                            case title
                            case secondaryCreator = "secondary_creator"
                        }
                    }
                    let data: [ItemData]
                    let href: String?
                }
                let items: [Item]
            }
            let collection: Collection
        }

        let response = try JSONDecoder().decode(NASAResponse.self, from: data)
        let items = response.collection.items

        var results: [GalleryItem] = []
        for item in items {
            guard let info = item.data.first, let collectionURLString = item.href,
                  let collectionURL = URL(string: collectionURLString) else { continue }

            // The asset collection lists the actual files.
            let (assetData, _) = try await getJSON(collectionURL)
            guard let files = try? JSONDecoder().decode([String].self, from: assetData) else { continue }

            let mp4s = files.filter { $0.hasSuffix(".mp4") }
            // Prefer the ~mobile/~preview encodes (smaller) over originals.
            let preferredName = mp4s.first { $0.contains("~mobile") }
                ?? mp4s.first { $0.contains("~preview") }
                ?? mp4s.first

            // Asset lists sometimes contain full URLs, sometimes bare names.
            let downloadURL: URL
            if let preferredName, preferredName.hasPrefix("http"), let url = URL(string: preferredName) {
                downloadURL = url
            } else if let preferredName, let url = URL(string: collectionURLString + "/" + preferredName) {
                downloadURL = url
            } else {
                continue
            }

            let thumbName = files.first { $0.hasSuffix("~small.jpg") }
                ?? files.first { $0.hasSuffix(".jpg") }
            let thumbURL = thumbName.flatMap { URL(string: collectionURLString + "/" + $0) }

            results.append(GalleryItem(
                id: "nasa-\(info.nasa_id)",
                title: info.title,
                source: .nasa,
                thumbnailURL: thumbURL,
                downloadURL: downloadURL,
                author: info.secondaryCreator
            ))
            if results.count >= 20 { break }
        }
        guard !results.isEmpty else { throw GalleryError.noResults }
        return results
    }

    // MARK: Pixabay (user key)

    private func searchPixabay(query: String, key: String) async throws -> [GalleryItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://pixabay.com/api/videos/?key=\(key)&q=\(encoded)&per_page=24&safesearch=true") else {
            throw GalleryError.badURL
        }
        let (data, _) = try await getJSON(url)

        struct PixabayResponse: Decodable {
            struct VideoVariant: Decodable {
                let url: String
                let width: Int
                let size: Int
            }
            struct Hit: Decodable {
                let id: Int
                let tags: String
                let duration: Int
                let picture_id: String
                let user: String
                let videos: [String: VideoVariant]
            }
            let hits: [Hit]
        }

        let response = try JSONDecoder().decode(PixabayResponse.self, from: data)
        let items = response.hits.map { hit -> GalleryItem in
            let variant = hit.videos["large"] ?? hit.videos["medium"] ?? hit.videos["small"]
            return GalleryItem(
                id: "pixabay-\(hit.id)",
                title: hit.tags.replacingOccurrences(of: ",", with: " ·"),
                source: .pixabay,
                thumbnailURL: URL(string: "https://i.vimeocdn.com/video/\(hit.picture_id)_640x360.jpg"),
                downloadURL: URL(string: variant?.url ?? "")!,
                durationSeconds: Double(hit.duration),
                author: hit.user
            )
        }
        .filter { $0.downloadURL.scheme != nil }
        guard !items.isEmpty else { throw GalleryError.noResults }
        return items
    }

    // MARK: Pexels (user key)

    private func searchPexels(query: String, key: String) async throws -> [GalleryItem] {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://api.pexels.com/videos/search?query=\(encoded)&per_page=24&orientation=landscape") else {
            throw GalleryError.badURL
        }
        let (data, _) = try await getJSON(url, headers: ["Authorization": key])

        struct PexelsResponse: Decodable {
            struct VideoFile: Decodable {
                let quality: String?
                let file_type: String?
                let link: String
                let width: Int?
            }
            struct Video: Decodable {
                let id: Int
                let duration: Int
                let image: URL
                let user: User
                let video_files: [VideoFile]
                struct User: Decodable {
                    let name: String
                }
            }
            let videos: [Video]
        }

        let response = try JSONDecoder().decode(PexelsResponse.self, from: data)
        let items = response.videos.map { video -> GalleryItem in
            let file = video.video_files.first { $0.file_type == "video/mp4" && $0.quality == "hd" }
                ?? video.video_files.first { $0.file_type == "video/mp4" }
            return GalleryItem(
                id: "pexels-\(video.id)",
                title: "Video #\(video.id)",
                source: .pexels,
                thumbnailURL: video.image,
                downloadURL: URL(string: file?.link ?? "")!,
                durationSeconds: Double(video.duration),
                author: video.user.name
            )
        }
        .filter { $0.downloadURL.scheme != nil }
        guard !items.isEmpty else { throw GalleryError.noResults }
        return items
    }

    // MARK: Download

    /// Streams a gallery video to a temporary file and returns its URL.
    public func download(_ item: GalleryItem) async throws -> URL {
        let (bytes, response) = try await session.bytes(from: item.downloadURL)
        guard let http = response as? HTTPURLResponse else {
            throw GalleryError.downloadFailed("not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GalleryError.http(http.statusCode)
        }

        let ext = item.downloadURL.pathExtension.isEmpty ? "mp4" : item.downloadURL.pathExtension
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("motionpaper-gallery-\(item.id.sanitized())-\(UUID().uuidString).\(ext)")
        FileManager.default.createFile(atPath: destination.path, contents: nil)

        do {
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }

            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            for try await byte in bytes {
                buffer.append(byte)
                if buffer.count >= 1 << 20 {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try handle.write(contentsOf: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw GalleryError.downloadFailed(error.localizedDescription)
        }
        return destination
    }
}

private extension String {
    func sanitized() -> String {
        replacingOccurrences(of: "[^a-zA-Z0-9-]", with: "-", options: .regularExpression)
    }
}

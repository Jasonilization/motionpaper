import Foundation
import CryptoKit

/// Streaming SHA-256 for file de-duplication. Reads in 1 MiB chunks so multi-GB
/// videos never need to fit in memory.
public enum FileHasher {
    public static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        let chunkSize = 1 << 20
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

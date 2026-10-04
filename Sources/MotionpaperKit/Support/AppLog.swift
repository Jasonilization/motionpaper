import Foundation
import os

/// Central logging. Console logging is throttled by design: normal playback never logs,
/// so the only chatter is lifecycle events, imports, and errors.
public enum AppLog {
    public static let subsystem = "com.jasonilization.motionpaper"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let renderer = Logger(subsystem: subsystem, category: "renderer")
    public static let importer = Logger(subsystem: subsystem, category: "importer")
    public static let migration = Logger(subsystem: subsystem, category: "migration")
    public static let power = Logger(subsystem: subsystem, category: "power")

    // MARK: - In-memory ring buffer for diagnostics export

    private static let ring = LogRing()

    /// Records a diagnostic line into the in-memory ring (bounded, never spams the console).
    public static func diag(_ message: String) {
        let line = "\(Self.timestamp()) \(message)"
        ring.append(line)
    }

    /// Returns the retained diagnostic lines (most recent last), then clears them.
    public static func drainDiagnostics() -> [String] {
        ring.drain()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }
}

/// A small thread-safe bounded queue of diagnostic lines.
private final class LogRing: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let limit = 2_000

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
        if lines.count > limit {
            lines.removeFirst(lines.count - limit)
        }
    }

    func drain() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let copy = lines
        lines = []
        return copy
    }
}

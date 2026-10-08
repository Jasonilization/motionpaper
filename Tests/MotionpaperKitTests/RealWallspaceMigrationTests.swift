import Foundation
import Testing
@testable import MotionpaperKit

/// Runs against the REAL Wallspace installation on this machine.
/// Skipped unless MOTIONPAPER_REAL_MIGRATION=1 — the default test run must
/// stay hermetic. This is the acceptance test for the migration feature:
/// it imports the user's actual Wallspace wallpapers into the real library.
struct RealWallspaceMigrationTests {
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["MOTIONPAPER_REAL_MIGRATION"] == "1"

    @MainActor
    @Test(.enabled(if: isEnabled))
    func migrateRealWallspaceLibrary() async throws {
        // The running app owns the real library and would overwrite our import
        // with its stale in-memory state. Require it to be stopped.
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-x", "Motionpaper"]
        pgrep.standardOutput = FileHandle.nullDevice
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()
        #expect(pgrep.terminationStatus == 1, "Motionpaper must not be running during the real migration test (two writers on library.json)")

        let migrator = WallspaceMigrator.defaultMigrator()
        let store = LibraryStore(paths: .standard())

        let before = store.wallpapers.count
        let report = await migrator.scan(library: store)

        guard !report.items.isEmpty else {
            print("REAL-MIGRATION: no Wallspace data found on this machine")
            return
        }
        print("REAL-MIGRATION: found \(report.items.count), new \(report.newCount), already \(report.alreadyImportedCount), unsupported \(report.unsupportedCount)")

        let outcome = await migrator.importItems(report.items, into: store, importer: ImportManager())
        print("REAL-MIGRATION: imported \(outcome.imported), skipped \(outcome.skipped)")
        #expect(store.wallpapers.count == before + outcome.imported)

        // Every migrated item is playable in the library.
        for item in report.items where item.status == .imported {
            let match = store.wallpapers.first { $0.origin == .wallspaceMigration && $0.originalLocation == item.fileURL.path }
            #expect(match != nil)
            #expect(match?.status == .ok)
            #expect(store.fileExists(for: match!))
        }

        // Wallspace's originals remain untouched.
        for item in report.items {
            #expect(FileManager.default.fileExists(atPath: item.fileURL.path))
        }

        // Re-scan is stable: nothing new after a successful import.
        let report2 = await migrator.scan(library: store)
        #expect(report2.newCount == 0)
    }
}

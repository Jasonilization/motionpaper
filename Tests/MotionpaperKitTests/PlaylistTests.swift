import Foundation
import Testing
@testable import MotionpaperKit

struct PlaylistAdvancerTests {
    @Test func sequentialFollowsOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let playlist = Playlist(id: UUID(), name: "P", wallpaperIDs: [a, b, c], order: .sequential, changeInterval: 60, isEnabled: true)

        #expect(PlaylistAdvancer.nextWallpaper(in: playlist, after: nil) == a)
        #expect(PlaylistAdvancer.nextWallpaper(in: playlist, after: a) == b)
        #expect(PlaylistAdvancer.nextWallpaper(in: playlist, after: b) == c)
        // Wraps back to the start.
        #expect(PlaylistAdvancer.nextWallpaper(in: playlist, after: c) == a)
    }

    @Test func sequentialHandlesRemovedCurrent() {
        let a = UUID(), b = UUID()
        let playlist = Playlist(id: UUID(), name: "P", wallpaperIDs: [a, b], order: .sequential, changeInterval: 60, isEnabled: true)
        // Current wallpaper no longer in the playlist → start from the beginning.
        #expect(PlaylistAdvancer.nextWallpaper(in: playlist, after: UUID()) == a)
    }

    @Test func randomNeverRepeatsCurrent() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let playlist = Playlist(id: UUID(), name: "P", wallpaperIDs: [a, b, c, d], order: .random, changeInterval: 60, isEnabled: true)

        for _ in 0..<20 {
            let next = PlaylistAdvancer.nextWallpaper(in: playlist, after: a)
            #expect(next != a)
            #expect(next != nil)
        }

        // Single-item playlist: must return that item even if it's current.
        let single = Playlist(id: UUID(), name: "S", wallpaperIDs: [a], order: .random, changeInterval: 60, isEnabled: true)
        #expect(PlaylistAdvancer.nextWallpaper(in: single, after: a) == a)

        // Empty playlist: nothing to show.
        let empty = Playlist(id: UUID(), name: "E", wallpaperIDs: [], order: .random, changeInterval: 60, isEnabled: true)
        #expect(PlaylistAdvancer.nextWallpaper(in: empty, after: nil) == nil)
    }

    @Test func intervalLabels() {
        #expect(PlaylistAdvancer.intervalLabel(5 * 60) == "5 min")
        #expect(PlaylistAdvancer.intervalLabel(60 * 60) == "1 h")
        #expect(PlaylistAdvancer.intervalLabel(90 * 60) == "1 h 30 m")
        #expect(PlaylistAdvancer.intervalChoices.contains(30 * 60))
    }
}

@MainActor
struct PlaylistStoreTests {
    @Test func playlistCRUDAndReorder() {
        let store = LibraryStore(paths: AppPaths(appSupport: TestVideoFactory.tempDirectory()))
        let a = Wallpaper(name: "A", fileName: "a.mp4", isManaged: true, origin: .imported)
        let b = Wallpaper(name: "B", fileName: "b.mp4", isManaged: true, origin: .imported)
        store.add([a, b])

        var playlist = store.createPlaylist(name: "Evening")
        playlist.wallpaperIDs = [a.id, b.id]
        playlist.order = .random
        playlist.changeInterval = 300
        store.update(playlist)

        let loaded = store.playlist(id: playlist.id)
        #expect(loaded?.wallpaperIDs == [a.id, b.id])
        #expect(loaded?.order == .random)
        #expect(loaded?.changeInterval == 300)

        // Reorder manually (the UI uses SwiftUI's move(_:to:) on top of this list).
        var reordered = loaded!
        let moved = reordered.wallpaperIDs.remove(at: 1)
        reordered.wallpaperIDs.insert(moved, at: 0)
        store.update(reordered)
        #expect(store.playlist(id: playlist.id)?.wallpaperIDs == [b.id, a.id])

        // Deleting the playlist removes it and clears playlist references in assignments.
        var assignment = DisplayAssignment(displayKey: "Key_1920x1080")
        assignment.playlistID = playlist.id
        store.setAssignment(assignment)
        store.deletePlaylist(id: playlist.id)
        #expect(store.playlist(id: playlist.id) == nil)
        #expect(store.assignment(displayKey: "Key_1920x1080")?.playlistID == nil)
    }
}

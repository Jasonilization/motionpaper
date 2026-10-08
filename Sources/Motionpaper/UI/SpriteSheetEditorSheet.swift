import AppKit
import SwiftUI
import MotionpaperKit

// MARK: - Sprite sheet editor

/// Post-import editor for sprite-sheet wallpapers: adjust the frame grid and
/// playback speed with a live animated preview, then apply.
struct SpriteSheetEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let wallpaperID: UUID

    @State private var columns = 4
    @State private var rows = 2
    @State private var fps: Double = 8
    @State private var loadError: String?

    private var wallpaper: Wallpaper? {
        store.library.wallpaper(id: wallpaperID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sprite Sheet — \(wallpaper?.name ?? "")")
                    .font(.headline)
                Spacer()
                Button("Save") {
                    persistAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            if let url = store.library.fileURL(for: wallpaper ?? Wallpaper(name: "", isManaged: false, origin: .imported)) {
                AnimatedSpritePreview(url: url, columns: columns, rows: rows, framesPerSecond: fps, scaling: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(16)
                    .overlay(alignment: .bottom) {
                        if let loadError {
                            Text(loadError)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Capsule())
                                .padding(24)
                        }
                    }
            }

            HStack(spacing: 24) {
                Stepper("Columns: \(columns)", value: $columns, in: 1...32)
                Stepper("Rows: \(rows)", value: $rows, in: 1...32)
                Stepper("FPS: \(Int(fps))", value: $fps, in: 1...30)
                Spacer()
                Text("\(columns * rows) frames")
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.ultraThinMaterial)
        }
        .frame(minWidth: 680, minHeight: 520)
        .onAppear {
            if let sprite = wallpaper?.sprite {
                columns = sprite.columns
                rows = sprite.rows
                fps = sprite.framesPerSecond
            }
        }
    }

    private func persistAndDismiss() {
        guard let wallpaper else { return }
        var updated = wallpaper
        updated.sprite = Wallpaper.SpriteMetadata(columns: columns, rows: rows, framesPerSecond: fps)
        store.library.update(updated)
        // Refresh the thumbnail with the new grid (first frame).
        if let url = store.library.fileURL(for: updated) {
            Task {
                _ = await store.thumbnails.thumbnail(for: updated, sourceURL: url)
            }
        }
        // If it's currently applied somewhere, re-render with the new grid.
        for assignment in store.library.assignments where assignment.wallpaperID == wallpaper.id {
            store.engine.reapply(displayKey: assignment.displayKey)
        }
        dismiss()
    }
}

// MARK: - Animated sprite preview (AppKit host)

/// Hosts the looping sprite animation inside SwiftUI (editor + preview sheet).
struct AnimatedSpritePreview: NSViewRepresentable {
    let url: URL
    let columns: Int
    let rows: Int
    let framesPerSecond: Double
    let scaling: ScalingMode

    final class SpriteHostView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError("unsupported") }

        override func makeBackingLayer() -> CALayer {
            let layer = CALayer()
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.black.cgColor
            return layer
        }

        func play(frames: [CGImage], fps: Double, scaling: ScalingMode) {
            guard let layer else { return }
            layer.removeAnimation(forKey: "spriteLoop")
            layer.contents = frames.first
            layer.contentsGravity = scaling.spriteContentsGravity
            if let animation = SpriteSheetRenderer.loopingAnimation(frames: frames, framesPerSecond: fps) {
                layer.add(animation, forKey: "spriteLoop")
            }
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> SpriteHostView {
        SpriteHostView(frame: .zero)
    }

    func updateNSView(_ nsView: SpriteHostView, context: Context) {
        let cols = columns, rws = rows, rate = framesPerSecond, scale = scaling, src = url
        Task.detached(priority: .userInitiated) {
            do {
                let image = try SpriteSheetRenderer.loadImage(at: src)
                let frames = try SpriteSheetRenderer.slice(image: image, columns: cols, rows: rws)
                await MainActor.run {
                    nsView.play(frames: frames, fps: rate, scaling: scale)
                }
            } catch {
                AppLog.renderer.warning("Sprite preview failed: \(error)")
            }
        }
    }
}

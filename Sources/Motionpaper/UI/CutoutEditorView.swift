import AppKit
import MotionpaperKit
import UniformTypeIdentifiers
import SwiftUI

/// Interactive cutout editor: users drop their own lock screen screenshot,
/// then drag and resize the three cutout holes (clock, avatar circle, login)
/// directly on top of it. Positions save to lockscreen-cutout.json and apply
/// on the next lock — no rebuild needed.
struct CutoutEditorView: View {
    @Environment(AppStore.self) private var store

    @State private var backgroundImage: NSImage?
    @State private var config: LockScreenOverlay.CutoutConfig
    @State private var selectedHole: String = "clock"
    @State private var showDropZone = true

    init() {
        _config = State(initialValue: LockScreenOverlay.CutoutConfig.defaults())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let bg = backgroundImage {
                editorCanvas(bg)
            } else {
                dropZone
            }
            Divider()
            controls
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Lock Screen Cutout Editor", systemImage: "square.dashed")
                .font(.headline)
            Spacer()
            Button("Reset to Defaults") {
                config = LockScreenOverlay.CutoutConfig.defaults()
                save()
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    // MARK: - Drop Zone

    private var dropZone: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("Drop your lock screen screenshot here")
                .font(.title3.weight(.semibold))
            Text("Take a screenshot of your lock screen (⌃⇧⌘3 then lock), then drag the image here. You'll position the cutout holes on top of it.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button("Choose Screenshot…") {
                chooseImage()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.image], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in
                    if let data, let img = NSImage(data: data) {
                        backgroundImage = img
                        showDropZone = false
                    }
                }
            }
            return true
        }
    }

    // MARK: - Editor Canvas

    private func editorCanvas(_ bg: NSImage) -> some View {
        GeometryReader { geo in
            ZStack {
                // Background screenshot
                Image(nsImage: bg)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                // Cutout overlays (semi-transparent red/white to show hole positions)
                cutoutOverlays(geo)

                // Instructions
                VStack {
                    Spacer()
                    Text("Drag the shapes to reposition · Drag corners to resize")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(.bottom, 12)
                }
            }
        }
        .padding(12)
    }

    // MARK: - Cutout Overlays (draggable)

    private func cutoutOverlays(_ geo: GeometryProxy) -> some View {
        let screenW = geo.size.width
        let screenH = geo.size.height

        return ZStack {
            // Clock hole (rectangle, amber)
            let clockW = screenW * config.clock.widthFraction
            let clockH = screenH * config.clock.heightFraction
            let clockY = screenH * config.clock.centerYFraction
            DraggableHole(
                label: "Clock",
                color: .orange,
                x: screenW / 2 - clockW / 2,
                y: clockY - clockH / 2,
                width: clockW,
                height: clockH
            ) { newX, newY, newW, newH in
                config.clock.centerYFraction = (newY + newH / 2) / screenH
                config.clock.widthFraction = newW / screenW
                config.clock.heightFraction = newH / screenH
                save()
            }

            // Avatar hole (circle, green)
            if let avatar = config.avatar {
                let r = screenH * avatar.radiusFraction
                let cy = screenH * avatar.centerYFraction
                DraggableHole(
                    label: "Avatar",
                    color: .green,
                    x: screenW / 2 - r,
                    y: cy - r,
                    width: r * 2,
                    height: r * 2,
                    isCircle: true
                ) { newX, newY, newW, _ in
                    config.avatar?.centerYFraction = (newY + newW / 2) / screenH
                    config.avatar?.radiusFraction = (newW / 2) / screenH
                    save()
                }
            }

            // Login hole (rectangle, blue)
            let loginW = screenW * config.login.widthFraction
            let loginH = screenH * config.login.heightFraction
            let loginY = screenH * config.login.centerYFraction
            DraggableHole(
                label: "Login",
                color: .blue,
                x: screenW / 2 - loginW / 2,
                y: loginY - loginH / 2,
                width: loginW,
                height: loginH
            ) { newX, newY, newW, newH in
                config.login.centerYFraction = (newY + newH / 2) / screenH
                config.login.widthFraction = newW / screenW
                config.login.heightFraction = newH / screenH
                save()
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 16) {
            // Numeric controls for fine-tuning
            VStack(alignment: .leading, spacing: 4) {
                Text("Clock: Y=\(config.clock.centerYFraction, format: .number.precision(.fractionLength(3))) W=\(config.clock.widthFraction, format: .number.precision(.fractionLength(2))) H=\(config.clock.heightFraction, format: .number.precision(.fractionLength(2)))")
                    .font(.caption.monospacedDigit())
                Text("Avatar: Y=\(config.avatar?.centerYFraction ?? 0, format: .number.precision(.fractionLength(3))) R=\(config.avatar?.radiusFraction ?? 0, format: .number.precision(.fractionLength(3)))")
                    .font(.caption.monospacedDigit())
                Text("Login: Y=\(config.login.centerYFraction, format: .number.precision(.fractionLength(3))) W=\(config.login.widthFraction, format: .number.precision(.fractionLength(2))) H=\(config.login.heightFraction, format: .number.precision(.fractionLength(2)))")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(.secondary)

            Spacer()

            Button("Choose Different Screenshot…") {
                chooseImage()
            }
            .controlSize(.small)

            Button("Save & Apply") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.title = "Choose Lock Screen Screenshot"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let img = NSImage(contentsOf: url) {
            backgroundImage = img
        }
    }

    private func save() {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Motionpaper/lockscreen-cutout.json")
        if let data = try? JSONEncoder().encode(config) {
            try? data.write(to: path, options: .atomic)
        }
    }
}

// MARK: - Draggable Hole

/// A draggable, resizable hole overlay. Drag to move, drag edges to resize.
struct DraggableHole: View {
    let label: String
    let color: Color
    let isCircle: Bool

    @State private var currentX: CGFloat
    @State private var currentY: CGFloat
    @State private var currentW: CGFloat
    @State private var currentH: CGFloat

    let onMove: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void

    init(label: String, color: Color, x: CGFloat, y: CGFloat,
         width: CGFloat, height: CGFloat, isCircle: Bool = false,
         onMove: @escaping (CGFloat, CGFloat, CGFloat, CGFloat) -> Void) {
        self.label = label
        self.color = color
        self.isCircle = isCircle
        self.onMove = onMove
        _currentX = State(initialValue: x)
        _currentY = State(initialValue: y)
        _currentW = State(initialValue: width)
        _currentH = State(initialValue: height)
    }

    var body: some View {
        Group {
            if isCircle {
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .background(color.opacity(0.15))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(color, lineWidth: 2)
                    .background(color.opacity(0.15))
            }
        }
        .frame(width: currentW, height: currentH)
        .position(x: currentX + currentW / 2, y: currentY + currentH / 2)
        .overlay(alignment: .top) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color.opacity(0.8), in: Capsule())
                .offset(y: -12)
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    currentX += value.translation.width
                    currentY += value.translation.height
                    onMove(currentX, currentY, currentW, currentH)
                }
        )
        // Bottom-right resize handle
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            currentW = max(20, currentW + value.translation.width)
                            currentH = max(20, currentH + value.translation.height)
                            onMove(currentX, currentY, currentW, currentH)
                        }
                )
        }
    }
}

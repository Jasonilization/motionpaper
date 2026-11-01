import AppKit
import MotionpaperKit

// MARK: - Window controller

@MainActor
final class LockScreenCutEditorController: NSWindowController {
    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Cut Lock Screen"
        window.isOpaque = true
        window.backgroundColor = NSColor(white: 0.12, alpha: 1)
        window.level = .normal
        window.ignoresMouseEvents = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.minSize = NSSize(width: 760, height: 520)

        let editor = LockScreenCutEditorView(frame: NSRect(x: 0, y: 0, width: 980, height: 680))
        window.contentView = editor

        super.init(window: window)
        window.delegate = self

        editor.onSave = { [weak self] config in
            LockScreenOverlay.saveCutout(config)
            self?.close()
        }
        editor.onCancel = { [weak self] in
            self?.close()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func present() {
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if let editor = window?.contentView as? LockScreenCutEditorView {
            editor.captureLoginScreenAndLoad()
            window?.makeFirstResponder(editor)
        }
    }
}

extension LockScreenCutEditorController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {}
}

// MARK: - Login picture

enum LoginScreenCapture {
    /// The picture macOS shows behind the clock and password field.
    static func image(for screen: NSScreen?) -> NSImage? {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url),
           image.isValid {
            return image
        }
        return nil
    }
}

// MARK: - Root editor view

@MainActor
private final class LockScreenCutEditorView: NSView {
    var onSave: ((LockScreenOverlay.CutoutConfig) -> Void)?
    var onCancel: (() -> Void)?

    private let caption = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let rectChip = ShapeChip(kind: .rect, title: "Rectangle")
    private let circleChip = ShapeChip(kind: .circle, title: "Circle")
    private let canvas = CutoutCanvasView(frame: .zero)

    private var shapes: [CutoutEditorShapeView] = []
    private var selectedShape: CutoutEditorShapeView?
    private var pendingModels: [LockScreenOverlay.CutoutConfig.Shape] = []
    private var didPlaceShapes = false
    private var lastCanvasSize = NSSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        caption.stringValue = "Your lock screen picture. Drag a shape to move it. Drag Rectangle or Circle onto the picture to add one."
        caption.font = .systemFont(ofSize: 13, weight: .medium)
        caption.textColor = .white
        caption.alignment = .center
        caption.maximumNumberOfLines = 2
        caption.lineBreakMode = .byWordWrapping
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        for button in [saveButton, cancelButton, deleteButton] {
            button.bezelStyle = .rounded
            button.target = self
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        saveButton.action = #selector(saveClicked)
        cancelButton.action = #selector(cancelClicked)
        deleteButton.action = #selector(deleteClicked)

        rectChip.translatesAutoresizingMaskIntoConstraints = false
        circleChip.translatesAutoresizingMaskIntoConstraints = false
        rectChip.onClick = { [weak self] in self?.addShape(kind: .rect, at: nil) }
        circleChip.onClick = { [weak self] in self?.addShape(kind: .circle, at: nil) }
        addSubview(rectChip)
        addSubview(circleChip)

        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.onDrop = { [weak self] kind, point in
            self?.addShape(kind: kind, at: point)
        }
        canvas.onBackgroundClick = { [weak self] in
            self?.select(nil)
        }
        addSubview(canvas)

        NSLayoutConstraint.activate([
            saveButton.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            saveButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
            deleteButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            deleteButton.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),

            rectChip.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            rectChip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rectChip.widthAnchor.constraint(equalToConstant: 110),
            rectChip.heightAnchor.constraint(equalToConstant: 28),
            circleChip.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            circleChip.leadingAnchor.constraint(equalTo: rectChip.trailingAnchor, constant: 8),
            circleChip.widthAnchor.constraint(equalToConstant: 90),
            circleChip.heightAnchor.constraint(equalToConstant: 28),

            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            caption.centerXAnchor.constraint(equalTo: centerXAnchor),
            caption.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.9),

            canvas.topAnchor.constraint(equalTo: saveButton.bottomAnchor, constant: 12),
            canvas.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -10),
            canvas.centerXAnchor.constraint(equalTo: centerXAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            deleteClicked()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    func captureLoginScreenAndLoad() {
        let screen = window?.screen ?? NSScreen.main
        canvas.image = LoginScreenCapture.image(for: screen)
        pendingModels = Self.models(from: LockScreenOverlay.loadCutout())
        didPlaceShapes = false
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    override func layout() {
        super.layout()
        updateCanvasAspect()
        let size = canvas.bounds.size
        guard size.width > 20, size.height > 20 else { return }
        if !didPlaceShapes {
            place(pendingModels)
            didPlaceShapes = true
            lastCanvasSize = size
            return
        }
        guard lastCanvasSize.width > 1, lastCanvasSize != size else { return }
        let scaleX = size.width / lastCanvasSize.width
        let scaleY = size.height / lastCanvasSize.height
        for shape in shapes {
            shape.frame = NSRect(
                x: shape.frame.origin.x * scaleX,
                y: shape.frame.origin.y * scaleY,
                width: shape.frame.width * scaleX,
                height: shape.frame.height * scaleY
            )
        }
        lastCanvasSize = size
    }

    private func updateCanvasAspect() {
        let screen = window?.screen?.frame.size ?? NSScreen.main?.frame.size ?? CGSize(width: 16, height: 10)
        let aspect = screen.width / max(screen.height, 1)
        let fittedWidth = canvas.bounds.height * aspect
        // Width constraint is created once and updated.
        if canvasWidthConstraint == nil {
            let constraint = canvas.widthAnchor.constraint(equalToConstant: fittedWidth)
            constraint.isActive = true
            canvasWidthConstraint = constraint
        }
        canvasWidthConstraint?.constant = min(fittedWidth, bounds.width - 32)
    }

    private var canvasWidthConstraint: NSLayoutConstraint?

    private static func models(from config: LockScreenOverlay.CutoutConfig) -> [LockScreenOverlay.CutoutConfig.Shape] {
        if config.shapesExplicit {
            return config.shapes
        }
        var models = [
            LockScreenOverlay.CutoutConfig.Shape(
                kind: .rect,
                widthFraction: config.clock.widthFraction,
                heightFraction: config.clock.heightFraction,
                centerYFraction: config.clock.centerYFraction,
                centerXFraction: config.clock.centerXFraction
            ),
        ]
        if let avatar = config.avatar {
            let diameter = avatar.radiusFraction * 2
            models.append(
                LockScreenOverlay.CutoutConfig.Shape(
                    kind: .circle,
                    widthFraction: diameter,
                    heightFraction: diameter,
                    centerYFraction: avatar.centerYFraction,
                    centerXFraction: avatar.centerXFraction
                )
            )
        }
        models.append(
            LockScreenOverlay.CutoutConfig.Shape(
                kind: .rect,
                widthFraction: config.login.widthFraction,
                heightFraction: config.login.heightFraction,
                centerYFraction: config.login.centerYFraction,
                centerXFraction: config.login.centerXFraction
            )
        )
        return models
    }

    private func place(_ models: [LockScreenOverlay.CutoutConfig.Shape]) {
        for shape in shapes { shape.removeFromSuperview() }
        shapes.removeAll()
        for model in models {
            let shape = makeShape(kind: model.kind == .circle ? .circle : .rect)
            shape.frame = CutoutEditorGeometry.frame(for: model, in: canvas.bounds)
            canvas.addSubview(shape)
            shapes.append(shape)
        }
        select(shapes.first)
    }

    private func makeShape(kind: CutoutEditorShapeView.Kind) -> CutoutEditorShapeView {
        let shape = CutoutEditorShapeView(kind: kind, title: kind == .circle ? "Circle" : "Rect")
        shape.onMouseDown = { [weak self, weak shape] in
            guard let shape else { return }
            self?.select(shape)
        }
        return shape
    }

    private func addShape(kind: CutoutEditorShapeView.Kind, at point: NSPoint?) {
        let shape = makeShape(kind: kind)
        let side: CGFloat = kind == .circle ? 72 : 160
        let height: CGFloat = kind == .circle ? 72 : 90
        let center = point ?? NSPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        shape.frame = NSRect(x: center.x - side / 2, y: center.y - height / 2, width: side, height: height)
        shape.frame = shape.clampedToParent()
        canvas.addSubview(shape)
        shapes.append(shape)
        select(shape)
    }

    private func select(_ shape: CutoutEditorShapeView?) {
        selectedShape = shape
        for item in shapes {
            item.isChosen = item === shape
        }
    }

    @objc private func deleteClicked() {
        guard let selectedShape, let index = shapes.firstIndex(where: { $0 === selectedShape }) else { return }
        selectedShape.removeFromSuperview()
        shapes.remove(at: index)
        select(shapes.last)
    }

    @objc private func saveClicked() {
        let bounds = canvas.bounds
        guard bounds.width > 1, bounds.height > 1 else { return }
        let saved = shapes.map { CutoutEditorGeometry.shape(from: $0, in: bounds) }
        let rects = saved.filter { $0.kind == .rect }
        let circles = saved.filter { $0.kind == .circle }
        let clockSource = rects.first
        let loginSource = rects.dropFirst().first ?? rects.first
        let clock = clockSource.map { CutoutEditorGeometry.hole(from: $0) }
            ?? LockScreenOverlay.CutoutConfig.defaults().clock
        let login = loginSource.map { CutoutEditorGeometry.hole(from: $0) }
            ?? LockScreenOverlay.CutoutConfig.defaults().login
        let avatar = circles.first.map { CutoutEditorGeometry.circle(from: $0, in: bounds) }
        let config = LockScreenOverlay.CutoutConfig(
            clock: clock,
            avatar: avatar,
            login: login,
            shapes: saved,
            shapesExplicit: true
        )
        onSave?(config)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }
}

// MARK: - Canvas

@MainActor
private final class CutoutCanvasView: NSView {
    var onDrop: ((CutoutEditorShapeView.Kind, NSPoint) -> Void)?
    var onBackgroundClick: (() -> Void)?

    private var loginImage: NSImage?

    var image: NSImage? {
        get { loginImage }
        set {
            loginImage = newValue
            applyImage()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        registerForDraggedTypes([.string])
    }

    override func layout() {
        super.layout()
        applyImage()
    }

    private func applyImage() {
        guard let loginImage, let layer else { return }
        var proposed = NSRect(origin: .zero, size: loginImage.size)
        layer.contents = loginImage.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        layer.contentsScale = window?.backingScaleFactor ?? 2
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let raw = sender.draggingPasteboard.string(forType: .string) ?? ""
        let kind: CutoutEditorShapeView.Kind = raw == "circle" ? .circle : .rect
        let point = convert(sender.draggingLocation, from: nil)
        onDrop?(kind, point)
        return true
    }
}

// MARK: - Palette chip (click adds, drag drops)

@MainActor
private final class ShapeChip: NSView, NSDraggingSource {
    var onClick: (() -> Void)?
    let kind: CutoutEditorShapeView.Kind

    init(kind: CutoutEditorShapeView.Kind, title: String) {
        self.kind = kind
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.4).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    override func mouseDown(with event: NSEvent) {
        let start = event.locationInWindow
        guard let window else { return }
        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            if next.type == .leftMouseUp {
                onClick?()
                return
            }
            let dx = next.locationInWindow.x - start.x
            let dy = next.locationInWindow.y - start.y
            if hypot(dx, dy) > 4 {
                let item = NSPasteboardItem()
                item.setString(kind == .circle ? "circle" : "rect", forType: .string)
                let dragging = NSDraggingItem(pasteboardWriter: item)
                dragging.setDraggingFrame(bounds, contents: NSImage(size: bounds.size))
                beginDraggingSession(with: [dragging], event: next, source: self)
                return
            }
        }
    }
}

// MARK: - Fraction ↔ frame

private enum CutoutEditorGeometry {
    static func frame(for shape: LockScreenOverlay.CutoutConfig.Shape, in bounds: CGRect) -> CGRect {
        let centerFromTop = shape.centerYFraction * bounds.height
        let centerY = bounds.height - centerFromTop
        let centerX = bounds.width * shape.centerXFraction
        if shape.kind == .circle {
            let diameter = bounds.height * shape.heightFraction
            return CGRect(x: centerX - diameter / 2, y: centerY - diameter / 2, width: diameter, height: diameter)
        }
        let width = bounds.width * shape.widthFraction
        let height = bounds.height * shape.heightFraction
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
    }

    static func shape(from view: CutoutEditorShapeView, in bounds: CGRect) -> LockScreenOverlay.CutoutConfig.Shape {
        let frame = view.frame
        return LockScreenOverlay.CutoutConfig.Shape(
            kind: view.kind == .circle ? .circle : .rect,
            widthFraction: frame.width / bounds.width,
            heightFraction: frame.height / bounds.height,
            centerYFraction: (bounds.height - frame.midY) / bounds.height,
            centerXFraction: frame.midX / bounds.width
        )
    }

    static func hole(from shape: LockScreenOverlay.CutoutConfig.Shape) -> LockScreenOverlay.CutoutConfig.Hole {
        LockScreenOverlay.CutoutConfig.Hole(
            widthFraction: shape.widthFraction,
            heightFraction: shape.heightFraction,
            centerYFraction: shape.centerYFraction,
            centerXFraction: shape.centerXFraction
        )
    }

    static func circle(from shape: LockScreenOverlay.CutoutConfig.Shape, in bounds: CGRect) -> LockScreenOverlay.CutoutConfig.Circle {
        let radiusPoints = min(bounds.width * shape.widthFraction, bounds.height * shape.heightFraction) / 2
        return LockScreenOverlay.CutoutConfig.Circle(
            radiusFraction: radiusPoints / max(bounds.height, 1),
            centerYFraction: shape.centerYFraction,
            centerXFraction: shape.centerXFraction
        )
    }
}

// MARK: - Draggable shape

@MainActor
final class CutoutEditorShapeView: NSView {
    enum Kind { case rect, circle }

    var onMouseDown: (() -> Void)?
    let kind: Kind
    private let title: String
    private let handleSize: CGFloat = 18

    var isChosen = false {
        didSet {
            layer?.borderWidth = isChosen ? 3 : 2
            layer?.borderColor = (isChosen ? NSColor.white : NSColor.systemBlue).cgColor
        }
    }

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        layer?.cornerRadius = kind == .circle ? min(bounds.width, bounds.height) / 2 : 12
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let text = title as NSString
        let textSize = text.size(withAttributes: attrs)
        let textRect = NSRect(x: 8, y: bounds.midY - textSize.height / 2, width: max(textSize.width, 4), height: textSize.height)
        if textRect.width + 12 < bounds.width {
            text.draw(in: textRect, withAttributes: attrs)
        }

        let handle = resizeHandleRect
        NSColor.white.setFill()
        NSBezierPath(ovalIn: handle).fill()
        NSColor.systemBlue.setStroke()
        let outline = NSBezierPath(ovalIn: handle)
        outline.lineWidth = 1.5
        outline.stroke()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
        addCursorRect(resizeHandleRect.insetBy(dx: -6, dy: -6), cursor: .crosshair)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return bounds.insetBy(dx: -8, dy: -8).contains(local) ? self : nil
    }

    private var resizeHandleRect: NSRect {
        NSRect(x: bounds.width - handleSize, y: 0, width: handleSize, height: handleSize)
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        let local = convert(event.locationInWindow, from: nil)
        let resizing = resizeHandleRect.insetBy(dx: -10, dy: -10).contains(local)
        let startWindow = event.locationInWindow
        let startFrame = frame
        guard let window else { return }

        while true {
            guard let next = window.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }
            if next.type == .leftMouseUp { break }
            let dx = next.locationInWindow.x - startWindow.x
            let dy = next.locationInWindow.y - startWindow.y
            if resizing {
                frame = resizedFrame(dx: dx, dy: dy, from: startFrame)
            } else {
                frame.origin = NSPoint(x: startFrame.origin.x + dx, y: startFrame.origin.y + dy)
            }
            frame = clampedToParent()
            needsDisplay = true
            displayIfNeeded()
        }
        window.invalidateCursorRects(for: self)
    }

    private func resizedFrame(dx: CGFloat, dy: CGFloat, from start: NSRect) -> NSRect {
        let minSide: CGFloat = 36
        let top = start.maxY
        switch kind {
        case .circle:
            let side = max(minSide, max(start.width + dx, start.height - dy))
            return NSRect(x: start.origin.x, y: top - side, width: side, height: side)
        case .rect:
            let width = max(minSide, start.width + dx)
            let height = max(minSide, start.height - dy)
            return NSRect(x: start.origin.x, y: top - height, width: width, height: height)
        }
    }

    func clampedToParent() -> NSRect { clamped(frame) }

    private func clamped(_ rect: NSRect) -> NSRect {
        guard let parent = superview else { return rect }
        var result = rect
        let margin: CGFloat = 20
        if result.maxX < margin { result.origin.x = margin - result.width }
        if result.minX > parent.bounds.width - margin { result.origin.x = parent.bounds.width - margin }
        if result.maxY < margin { result.origin.y = margin - result.height }
        if result.minY > parent.bounds.height - margin { result.origin.y = parent.bounds.height - margin }
        return result
    }
}

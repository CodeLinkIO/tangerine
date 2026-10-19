import AppKit
import SwiftUI

/// SwiftUI wrapper around the AppKit canvas.
struct EditorCanvas: NSViewRepresentable {
    var image: CGImage?
    var showsCrop: Bool
    var crop: CGRect
    var cropRatio: CGFloat?
    var zoom: CGFloat
    var pan: CGSize
    var onCropChange: (CGRect, Bool) -> Void
    var onPanChange: (CGSize) -> Void
    var onZoomChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> EditorCanvasView {
        EditorCanvasView()
    }

    func updateNSView(_ view: EditorCanvasView, context: Context) {
        view.onCropChange = onCropChange
        view.onPanChange = onPanChange
        view.onZoomChange = onZoomChange
        view.cropRatio = cropRatio
        view.zoom = zoom
        view.pan = pan
        view.showsCrop = showsCrop
        if !view.isDraggingCrop { view.crop = crop }
        view.image = image
        view.refresh()
    }
}

/// Draws the preview on a checkerboard, with a crop overlay, pinch-zoom and scroll/drag panning.
final class EditorCanvasView: NSView {
    var image: CGImage? {
        didSet { if image !== oldValue { imageLayer.contents = image } }
    }
    var showsCrop = false
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    var cropRatio: CGFloat?
    var zoom: CGFloat = 1
    var pan: CGSize = .zero
    var onCropChange: ((CGRect, Bool) -> Void)?
    var onPanChange: ((CGSize) -> Void)?
    var onZoomChange: ((CGFloat) -> Void)?

    private(set) var isDraggingCrop = false
    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let gridLayer = CAShapeLayer()
    private let handlesLayer = CAShapeLayer()

    private var activeHandle: EditorCropHandle?
    private var dragStartPoint: CGPoint = .zero
    private var dragStartCrop: CGRect = .zero
    private var panStart: CGSize?
    private var lastFrame: CGRect = .zero

    private static let checkerColor: NSColor = {
        let tile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(white: 0.82, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 16, height: 16).fill()
            NSColor(white: 0.66, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 8, height: 8).fill()
            NSRect(x: 8, y: 8, width: 8, height: 8).fill()
            return true
        }
        return NSColor(patternImage: tile)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        let noAnimation: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                                               "path": NSNull(), "hidden": NSNull(), "opacity": NSNull()]
        imageLayer.actions = noAnimation
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.shadowColor = NSColor.black.cgColor
        imageLayer.shadowOpacity = 0.25
        imageLayer.shadowRadius = 8
        imageLayer.shadowOffset = CGSize(width: 0, height: -2)

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        borderLayer.lineWidth = 1
        gridLayer.fillColor = nil
        gridLayer.strokeColor = NSColor.white.withAlphaComponent(0.45).cgColor
        gridLayer.lineWidth = 0.5
        handlesLayer.fillColor = nil
        handlesLayer.strokeColor = NSColor.white.cgColor
        handlesLayer.lineWidth = 3.5
        handlesLayer.lineCap = .square
        for overlay in [dimLayer, borderLayer, gridLayer, handlesLayer] { overlay.actions = noAnimation }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let layer, imageLayer.superlayer == nil else { return }
        for sublayer in [imageLayer, dimLayer, borderLayer, gridLayer, handlesLayer] { layer.addSublayer(sublayer) }
        refresh()
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    // MARK: Layout

    private var imageFrame: CGRect {
        guard let image else { return .zero }
        return EditorCanvasLayout.imageFrame(imageSize: CGSize(width: image.width, height: image.height), bounds: bounds,
                                             padding: showsCrop ? 36 : 20, zoom: zoom, pan: pan)
    }

    private var mapping: EditorImageMapping { EditorImageMapping(frame: imageFrame) }

    /// Updates layer geometry and the crop overlay.
    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = imageFrame
        imageLayer.frame = frame
        imageLayer.isHidden = image == nil

        let overlayVisible = showsCrop && image != nil
        for overlay in [dimLayer, borderLayer, handlesLayer] { overlay.isHidden = !overlayVisible }
        gridLayer.isHidden = !(overlayVisible && isDraggingCrop)
        if overlayVisible { updateOverlay(cropRect: mapping.viewRect(crop), imageFrame: frame) }
        CATransaction.commit()
        if frame != lastFrame {
            lastFrame = frame
            needsDisplay = true
        }
        window?.invalidateCursorRects(for: self)
    }

    private func updateOverlay(cropRect r: CGRect, imageFrame: CGRect) {
        // Dim only the part of the image outside the crop.
        let dim = CGMutablePath()
        dim.addRect(imageFrame)
        dim.addRect(r.intersection(imageFrame))
        dimLayer.path = dim
        dimLayer.frame = bounds
        borderLayer.path = CGPath(rect: r, transform: nil)

        let grid = CGMutablePath()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        gridLayer.path = grid

        // Corner brackets and edge bars, drawn just outside the crop border.
        let handles = CGMutablePath()
        let length = min(20, r.width / 3, r.height / 3), o: CGFloat = 1.5
        let corners: [(CGPoint, CGFloat, CGFloat)] = [
            (CGPoint(x: r.minX - o, y: r.maxY + o), 1, -1), (CGPoint(x: r.maxX + o, y: r.maxY + o), -1, -1),
            (CGPoint(x: r.maxX + o, y: r.minY - o), -1, 1), (CGPoint(x: r.minX - o, y: r.minY - o), 1, 1),
        ]
        for (p, dx, dy) in corners {
            handles.move(to: CGPoint(x: p.x + dx * length, y: p.y))
            handles.addLine(to: p)
            handles.addLine(to: CGPoint(x: p.x, y: p.y + dy * length))
        }
        let bar = min(18, r.width / 4, r.height / 4)
        handles.move(to: CGPoint(x: r.midX - bar / 2, y: r.maxY + o)); handles.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.maxY + o))
        handles.move(to: CGPoint(x: r.midX - bar / 2, y: r.minY - o)); handles.addLine(to: CGPoint(x: r.midX + bar / 2, y: r.minY - o))
        handles.move(to: CGPoint(x: r.minX - o, y: r.midY - bar / 2)); handles.addLine(to: CGPoint(x: r.minX - o, y: r.midY + bar / 2))
        handles.move(to: CGPoint(x: r.maxX + o, y: r.midY - bar / 2)); handles.addLine(to: CGPoint(x: r.maxX + o, y: r.midY + bar / 2))
        handlesLayer.path = handles
    }

    override func draw(_ dirtyRect: NSRect) {
        // Checkerboard behind the image so transparency is visible.
        guard image != nil else { return }
        let frame = imageFrame
        Self.checkerColor.setFill()
        NSGraphicsContext.current?.patternPhase = frame.origin
        frame.fill()
    }

    // MARK: Mouse

    private var canPan: Bool {
        guard let image else { return false }
        let full = EditorCanvasLayout.imageFrame(imageSize: CGSize(width: image.width, height: image.height), bounds: bounds,
                                                 padding: showsCrop ? 36 : 20, zoom: zoom, pan: .zero)
        return full.width > bounds.width || full.height > bounds.height
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if showsCrop, image != nil, let handle = mapping.handle(at: point, crop: crop) {
            activeHandle = handle
            dragStartPoint = point
            dragStartCrop = crop
            isDraggingCrop = true
            if handle == .move { NSCursor.closedHand.set() }
            refresh()
        } else if canPan {
            panStart = pan
            dragStartPoint = point
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let handle = activeHandle {
            if handle == .move {
                let delta = mapping.normalizedDelta(CGSize(width: point.x - dragStartPoint.x, height: point.y - dragStartPoint.y))
                crop = EditorCropMath.moved(dragStartCrop, by: delta)
            } else {
                let minimum = CGSize(width: 24 / max(imageFrame.width, 1), height: 24 / max(imageFrame.height, 1))
                crop = EditorCropMath.resized(dragStartCrop, handle: handle, to: mapping.normalized(point),
                                              ratio: cropRatio, minSize: minimum)
            }
            refresh()
            onCropChange?(crop, false)
        } else if let panStart {
            pan = CGSize(width: panStart.width + point.x - dragStartPoint.x, height: panStart.height + point.y - dragStartPoint.y)
            refresh()
            onPanChange?(pan)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if activeHandle != nil {
            activeHandle = nil
            isDraggingCrop = false
            refresh()
            onCropChange?(crop, true)
        }
        panStart = nil
        window?.invalidateCursorRects(for: self)
    }

    override func magnify(with event: NSEvent) {
        zoom = min(8, max(0.25, zoom * (1 + event.magnification)))
        refresh()
        onZoomChange?(zoom)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let factor = 1 + (event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.scrollingDeltaY / 20)
            zoom = min(8, max(0.25, zoom * factor))
            refresh()
            onZoomChange?(zoom)
            return
        }
        guard canPan else { return super.scrollWheel(with: event) }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        pan = CGSize(width: pan.width + event.scrollingDeltaX * scale, height: pan.height - event.scrollingDeltaY * scale)
        refresh()
        onPanChange?(pan)
    }

    override func resetCursorRects() {
        guard image != nil else { return }
        if showsCrop {
            let r = mapping.viewRect(crop), t: CGFloat = 12
            addCursorRect(r.insetBy(dx: t, dy: t), cursor: .openHand)
            addCursorRect(CGRect(x: r.minX - t, y: r.minY + t, width: 2 * t, height: max(0, r.height - 2 * t)), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: r.maxX - t, y: r.minY + t, width: 2 * t, height: max(0, r.height - 2 * t)), cursor: .resizeLeftRight)
            addCursorRect(CGRect(x: r.minX + t, y: r.minY - t, width: max(0, r.width - 2 * t), height: 2 * t), cursor: .resizeUpDown)
            addCursorRect(CGRect(x: r.minX + t, y: r.maxY - t, width: max(0, r.width - 2 * t), height: 2 * t), cursor: .resizeUpDown)
            for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
                addCursorRect(CGRect(x: corner.x - t, y: corner.y - t, width: 2 * t, height: 2 * t), cursor: .crosshair)
            }
        } else if canPan {
            addCursorRect(bounds, cursor: .openHand)
        }
    }
}

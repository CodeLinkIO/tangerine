import CoreGraphics
import Foundation

// Pure editor logic (no AppKit/SwiftUI) so it can be verified in isolation.

// MARK: - Aspect presets

enum EditorAspect: String, CaseIterable, Identifiable {
    case free, original, square, r4x5, r3x2, r4x3, r16x9, r9x16

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "1:1"
        case .r4x5: "4:5"
        case .r3x2: "3:2"
        case .r4x3: "4:3"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        }
    }

    /// Width / height in pixels, or nil for a free crop.
    func pixelRatio(baseSize: CGSize, swapped: Bool) -> CGFloat? {
        let ratio: CGFloat
        switch self {
        case .free: return nil
        case .original: ratio = baseSize.height > 0 ? baseSize.width / baseSize.height : 1
        case .square: ratio = 1
        case .r4x5: ratio = 4.0 / 5.0
        case .r3x2: ratio = 3.0 / 2.0
        case .r4x3: ratio = 4.0 / 3.0
        case .r16x9: ratio = 16.0 / 9.0
        case .r9x16: ratio = 9.0 / 16.0
        }
        return swapped ? 1 / ratio : ratio
    }
}

// MARK: - Crop math (normalized, top-left origin, unit square = whole image)

enum EditorCropHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left, move

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }
}

enum EditorCropMath {
    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Converts a pixel aspect ratio (w/h) into normalized units for an image of `baseSize`.
    static func normalizedRatio(pixelRatio: CGFloat, baseSize: CGSize) -> CGFloat {
        guard baseSize.width > 0, baseSize.height > 0 else { return pixelRatio }
        return pixelRatio * baseSize.height / baseSize.width
    }

    /// The largest rect with `ratio` (normalized w/h) centered inside `rect`.
    static func fit(ratio: CGFloat, in rect: CGRect) -> CGRect {
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var width = rect.width, height = width / ratio
        if height > rect.height {
            height = rect.height
            width = height * ratio
        }
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    /// Moves `rect` by `delta`, keeping it inside the unit square.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var r = rect
        r.origin.x = min(max(0, rect.minX + delta.width), 1 - rect.width)
        r.origin.y = min(max(0, rect.minY + delta.height), 1 - rect.height)
        return r
    }

    /// Drags `handle` of `rect` to `point`, optionally keeping `ratio` (normalized w/h).
    static func resized(_ rect: CGRect, handle: EditorCropHandle, to point: CGPoint, ratio: CGFloat?,
                        minSize: CGSize = CGSize(width: 0.02, height: 0.02)) -> CGRect {
        let p = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        guard handle != .move else { return rect }
        if let ratio, ratio > 0 {
            return handle.isCorner ? resizeCorner(rect, handle, p, ratio, minSize) : resizeEdge(rect, handle, p, ratio, minSize)
        }
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch handle {
        case .topLeft: minX = p.x; minY = p.y
        case .top: minY = p.y
        case .topRight: maxX = p.x; minY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; maxY = p.y
        case .bottom: maxY = p.y
        case .bottomLeft: minX = p.x; maxY = p.y
        case .left: minX = p.x
        case .move: break
        }
        // Keep the opposite edge fixed and enforce the minimum size.
        if [.topLeft, .bottomLeft, .left].contains(handle) { minX = min(minX, maxX - minSize.width) }
        if [.topRight, .bottomRight, .right].contains(handle) { maxX = max(maxX, minX + minSize.width) }
        if [.topLeft, .topRight, .top].contains(handle) { minY = min(minY, maxY - minSize.height) }
        if [.bottomLeft, .bottomRight, .bottom].contains(handle) { maxY = max(maxY, minY + minSize.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(unit)
    }

    private static func resizeCorner(_ rect: CGRect, _ handle: EditorCropHandle, _ p: CGPoint, _ ratio: CGFloat,
                                     _ minSize: CGSize) -> CGRect {
        // Anchor is the opposite corner; sx/sy point from the anchor toward the dragged corner.
        let sx: CGFloat = (handle == .topLeft || handle == .bottomLeft) ? -1 : 1
        let sy: CGFloat = (handle == .topLeft || handle == .topRight) ? -1 : 1
        let anchor = CGPoint(x: sx > 0 ? rect.minX : rect.maxX, y: sy > 0 ? rect.minY : rect.maxY)
        let rawWidth = max(minSize.width, (p.x - anchor.x) * sx)
        let rawHeight = max(minSize.height, (p.y - anchor.y) * sy)
        var width = max(rawWidth, rawHeight * ratio)
        var height = width / ratio
        let maxWidth = sx > 0 ? 1 - anchor.x : anchor.x
        let maxHeight = sy > 0 ? 1 - anchor.y : anchor.y
        if width > maxWidth { width = maxWidth; height = width / ratio }
        if height > maxHeight { height = maxHeight; width = height * ratio }
        let x = sx > 0 ? anchor.x : anchor.x - width
        let y = sy > 0 ? anchor.y : anchor.y - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func resizeEdge(_ rect: CGRect, _ handle: EditorCropHandle, _ p: CGPoint, _ ratio: CGFloat,
                                   _ minSize: CGSize) -> CGRect {
        switch handle {
        case .left, .right:
            let anchorX = handle == .right ? rect.minX : rect.maxX
            let available = handle == .right ? 1 - anchorX : anchorX
            var width = min(max(minSize.width, abs(p.x - anchorX)), available)
            var height = width / ratio
            let maxHeight = 2 * min(rect.midY, 1 - rect.midY)
            if height > maxHeight { height = maxHeight; width = height * ratio }
            let x = handle == .right ? anchorX : anchorX - width
            return CGRect(x: x, y: rect.midY - height / 2, width: width, height: height)
        default:
            let anchorY = handle == .bottom ? rect.minY : rect.maxY
            let available = handle == .bottom ? 1 - anchorY : anchorY
            var height = min(max(minSize.height, abs(p.y - anchorY)), available)
            var width = height * ratio
            let maxWidth = 2 * min(rect.midX, 1 - rect.midX)
            if width > maxWidth { width = maxWidth; height = width / ratio }
            let y = handle == .bottom ? anchorY : anchorY - height
            return CGRect(x: rect.midX - width / 2, y: y, width: width, height: height)
        }
    }

    // MARK: Geometry changes

    /// Where a crop rect lands after the displayed image rotates 90°.
    static func rotated(_ rect: CGRect, clockwise: Bool) -> CGRect {
        clockwise
            ? CGRect(x: 1 - rect.minY - rect.height, y: rect.minX, width: rect.height, height: rect.width)
            : CGRect(x: rect.minY, y: 1 - rect.minX - rect.width, width: rect.height, height: rect.width)
    }

    /// Where a crop rect lands after the displayed image is mirrored.
    static func flipped(_ rect: CGRect, horizontally: Bool) -> CGRect {
        horizontally
            ? CGRect(x: 1 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
            : CGRect(x: rect.minX, y: 1 - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Pixel size of `crop` on an image of `baseSize`.
    static func pixelSize(of crop: CGRect?, baseSize: CGSize) -> CGSize {
        let r = crop ?? unit
        return CGSize(width: max(1, (r.width * baseSize.width).rounded()), height: max(1, (r.height * baseSize.height).rounded()))
    }

    /// True when `rect` is (almost) the whole image, i.e. no crop.
    static func isFull(_ rect: CGRect) -> Bool {
        abs(rect.minX) < 0.0005 && abs(rect.minY) < 0.0005 && abs(rect.width - 1) < 0.0005 && abs(rect.height - 1) < 0.0005
    }
}

// MARK: - Canvas layout (view coordinates, bottom-left origin like AppKit)

struct EditorCanvasLayout {
    /// The rect the image occupies for a given zoom (1 = fit) and pan offset.
    static func imageFrame(imageSize: CGSize, bounds: CGRect, padding: CGFloat, zoom: CGFloat, pan: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: padding, dy: padding)
        let fit = min(available.width / imageSize.width, available.height / imageSize.height)
        let scale = max(fit, 0.0001) * zoom
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let pan = clampedPan(pan, imageDisplaySize: size, bounds: bounds)
        return CGRect(x: bounds.midX - size.width / 2 + pan.width, y: bounds.midY - size.height / 2 + pan.height,
                      width: size.width, height: size.height)
    }

    /// Keeps the image from being dragged entirely off screen; centered when it fits.
    static func clampedPan(_ pan: CGSize, imageDisplaySize size: CGSize, bounds: CGRect) -> CGSize {
        let maxX = max(0, (size.width - bounds.width) / 2 + 40)
        let maxY = max(0, (size.height - bounds.height) / 2 + 40)
        return CGSize(width: size.width <= bounds.width ? 0 : min(max(pan.width, -maxX), maxX),
                      height: size.height <= bounds.height ? 0 : min(max(pan.height, -maxY), maxY))
    }
}

/// Maps between normalized image coordinates (top-left origin) and view points (bottom-left origin).
struct EditorImageMapping {
    let frame: CGRect

    func viewPoint(_ n: CGPoint) -> CGPoint {
        CGPoint(x: frame.minX + n.x * frame.width, y: frame.maxY - n.y * frame.height)
    }

    func normalized(_ p: CGPoint) -> CGPoint {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGPoint(x: (p.x - frame.minX) / frame.width, y: (frame.maxY - p.y) / frame.height)
    }

    func viewRect(_ n: CGRect) -> CGRect {
        CGRect(x: frame.minX + n.minX * frame.width, y: frame.maxY - n.maxY * frame.height,
               width: n.width * frame.width, height: n.height * frame.height)
    }

    /// Converts a view-space drag delta into normalized units (y flips).
    func normalizedDelta(_ d: CGSize) -> CGSize {
        guard frame.width > 0, frame.height > 0 else { return .zero }
        return CGSize(width: d.width / frame.width, height: -d.height / frame.height)
    }

    /// The handle under `p` (within `tolerance` points) for a crop rect, or nil.
    func handle(at p: CGPoint, crop: CGRect, tolerance: CGFloat = 12) -> EditorCropHandle? {
        let r = viewRect(crop)
        let nearLeft = abs(p.x - r.minX) <= tolerance, nearRight = abs(p.x - r.maxX) <= tolerance
        let nearTop = abs(p.y - r.maxY) <= tolerance, nearBottom = abs(p.y - r.minY) <= tolerance
        let withinX = p.x >= r.minX - tolerance && p.x <= r.maxX + tolerance
        let withinY = p.y >= r.minY - tolerance && p.y <= r.maxY + tolerance
        guard withinX, withinY else { return nil }
        switch (nearLeft, nearRight, nearTop, nearBottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        case (true, _, _, _): return .left
        case (_, true, _, _): return .right
        case (_, _, true, _): return .top
        case (_, _, _, true): return .bottom
        default: return r.contains(p) ? .move : nil
        }
    }
}

// MARK: - History

/// Undo/redo over value snapshots.
struct EditorHistory<Value: Equatable> {
    private(set) var undoStack: [Value] = []
    private(set) var redoStack: [Value] = []
    let limit: Int

    init(limit: Int = 200) { self.limit = limit }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records the state before a change. Ignored when nothing changed.
    mutating func record(before: Value, after: Value) {
        guard before != after else { return }
        undoStack.append(before)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    mutating func undo(from current: Value) -> Value? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(from current: Value) -> Value? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

// MARK: - Formatting

enum EditorFormatting {
    static func pixels(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) px"
    }

    static func estimate(bytes: Int64) -> String {
        "≈ " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "+12", "−5", "0" for a −1…1 slider shown as −100…100.
    static func signedValue(_ value: Double, scale: Double = 100) -> String {
        let n = Int((value * scale).rounded())
        if n > 0 { return "+\(n)" }
        if n < 0 { return "−\(-n)" }
        return "0"
    }

    static func degrees(_ value: Double) -> String {
        let n = (value * 10).rounded() / 10
        if n == 0 { return "0°" }
        return (n > 0 ? "+" : "−") + String(format: "%.1f°", abs(n))
    }
}

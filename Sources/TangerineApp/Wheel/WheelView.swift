import AppKit
import TangerineKit

/// One petal on the wheel.
enum WheelItem: Equatable {
    case convert(FileFormat)
    case tool(ToolID)
    case more

    var label: String {
        switch self {
        case let .convert(format): format.shortName
        case let .tool(tool): tool.title
        case .more: "More…"
        }
    }

    var symbol: String? {
        switch self {
        case .convert: nil
        case let .tool(tool): tool.symbol
        case .more: "ellipsis.circle"
        }
    }

    /// Shown in the center while the petal is highlighted.
    var centerTitle: String {
        switch self {
        case let .convert(format): format == .txt ? "Extract text" : "Convert to \(format.displayName)"
        case let .tool(tool): tool.detail
        case .more: "All formats and tools"
        }
    }
}

/// Draws the wheel and turns pointer, drag and keyboard input into a selection.
/// Coordinates are y-up; the wheel sits at the top, the key legend below it.
final class WheelView: NSView {
    static let size = CGSize(width: 300, height: 336)

    var items: [WheelItem] = [] { didSet { highlighted = nil; needsDisplay = true; updateMask() } }
    var mode: WheelMode = .convert { didSet { needsDisplay = true } }
    var keys: [(ModifierKey, WheelMode)] = [] { didSet { needsDisplay = true; updateMask() } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var emptyMessage = "" { didSet { needsDisplay = true } }
    private(set) var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true; hapticTick() } } }

    /// Called with the chosen petal and, for drops, the dropped files.
    var onChoose: ((WheelItem, [URL]?) -> Void)?
    var onCancel: (() -> Void)?
    var onModeKey: ((ModifierKey) -> Void)?

    /// Blur shown behind the petals; a sibling placed below this view (subviews would draw on top).
    weak var glass: NSVisualEffectView? { didSet { updateMask() } }
    private var trackingArea: NSTrackingArea?
    private var previousFlags: NSEvent.ModifierFlags = []

    var wheelCenter: CGPoint { CGPoint(x: bounds.midX, y: bounds.maxY - 14 - WheelGeometry.diameter / 2) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Drawing

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private static let orange = NSColor(srgbRed: 1, green: 0x52 / 255, blue: 0, alpha: 1)

    private func petalPaths() -> [CGPath] {
        items.indices.map { WheelGeometry.petalPath(index: $0, count: items.count, center: wheelCenter) }
    }

    /// Masks the blur to the petals, the center disk and the legend so the rest stays clear.
    private func updateMask() {
        guard let glass else { return }
        let paths = petalPaths()
        let center = wheelCenter
        let legend = legendRect
        let empty = items.isEmpty
        let message = messageRect
        glass.maskImage = NSImage(size: bounds.size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            if empty {
                context.addPath(CGPath(roundedRect: message, cornerWidth: 18, cornerHeight: 18, transform: nil))
            } else {
                paths.forEach(context.addPath)
                context.addEllipse(in: CGRect(x: center.x - 40, y: center.y - 40, width: 80, height: 80))
            }
            context.addPath(CGPath(roundedRect: legend, cornerWidth: legend.height / 2, cornerHeight: legend.height / 2, transform: nil))
            context.fillPath()
            return true
        }
    }

    override func layout() {
        super.layout()
        updateMask()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private var legendRect: CGRect {
        let width: CGFloat = keys.count > 1 ? 196 : 120
        return CGRect(x: bounds.midX - width / 2, y: 6, width: width, height: 30)
    }

    private var messageRect: CGRect {
        CGRect(x: bounds.midX - 120, y: wheelCenter.y - 44, width: 240, height: 88)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let dark = isDark
        let label = dark ? NSColor.white : NSColor(white: 0.08, alpha: 1)
        let muted = dark ? NSColor(white: 1, alpha: 0.6) : NSColor(white: 0, alpha: 0.5)
        let stroke = dark ? NSColor(white: 1, alpha: 0.14) : NSColor(srgbRed: 0x5D / 255, green: 0x66 / 255, blue: 0x66 / 255, alpha: 0.22)

        if items.isEmpty {
            drawBubble(context, rect: messageRect, stroke: stroke, dark: dark)
            drawText(emptyMessage, in: messageRect.insetBy(dx: 18, dy: 14), font: .systemFont(ofSize: 12, weight: .medium), color: label)
        } else {
            let paths = petalPaths()
            // Soft shadow under the whole flower.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10,
                              color: NSColor(srgbRed: 0.15, green: 0.2, blue: 0.22, alpha: dark ? 0.45 : 0.18).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for (index, path) in paths.enumerated() {
                context.addPath(path)
                context.setFillColor(fill(for: index, dark: dark).cgColor)
                context.fillPath()
            }
            context.endTransparencyLayer()
            context.restoreGState()

            for (index, path) in paths.enumerated() {
                context.addPath(path)
                let isOn = index == highlighted
                context.setStrokeColor(isOn ? NSColor(srgbRed: 0.76, green: 0.4, blue: 0.2, alpha: 0.45).cgColor : stroke.cgColor)
                context.setLineWidth(0.75)
                context.strokePath()
                drawPetalContent(items[index], at: WheelGeometry.labelPoint(index: index, count: items.count, center: wheelCenter),
                                 color: isOn ? .white : label)
            }

            // Center disk with the current hint.
            let disk = CGRect(x: wheelCenter.x - 40, y: wheelCenter.y - 40, width: 80, height: 80)
            context.addEllipse(in: disk)
            context.setFillColor((dark ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.55)).cgColor)
            context.fillPath()
            context.addEllipse(in: disk)
            context.setStrokeColor(stroke.cgColor)
            context.strokePath()
            if let highlighted, items.indices.contains(highlighted) {
                drawText(items[highlighted].centerTitle, in: disk.insetBy(dx: 8, dy: 18),
                         font: .rounded(10.5, weight: .semibold), color: label)
            } else {
                drawText(mode.title, in: disk.insetBy(dx: 6, dy: 24).offsetBy(dx: 0, dy: 7),
                         font: .rounded(13, weight: .bold), color: label)
                drawText(subtitle, in: disk.insetBy(dx: 8, dy: 26).offsetBy(dx: 0, dy: -9),
                         font: .rounded(9.5, weight: .medium), color: muted)
            }
        }
        drawLegend(context, label: label, muted: muted, stroke: stroke, dark: dark)
    }

    private func fill(for index: Int, dark: Bool) -> NSColor {
        if index == highlighted { return Self.orange }
        return dark ? NSColor(white: 0.16, alpha: 0.55) : NSColor(white: 1, alpha: 0.62)
    }

    private func drawBubble(_ context: CGContext, rect: CGRect, stroke: NSColor, dark: Bool) {
        let path = CGPath(roundedRect: rect, cornerWidth: 18, cornerHeight: 18, transform: nil)
        context.addPath(path)
        context.setFillColor((dark ? NSColor(white: 0.16, alpha: 0.55) : NSColor(white: 1, alpha: 0.62)).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.strokePath()
    }

    private func drawPetalContent(_ item: WheelItem, at point: CGPoint, color: NSColor) {
        if let symbol = item.symbol,
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.label)?
               .withSymbolConfiguration(.init(pointSize: 16, weight: .medium).applying(.init(paletteColors: [color]))) {
            let size = image.size
            image.draw(in: CGRect(x: point.x - size.width / 2, y: point.y - 1, width: size.width, height: size.height))
            drawText(item.label, in: CGRect(x: point.x - 34, y: point.y - 17, width: 68, height: 14),
                     font: .rounded(9, weight: .semibold), color: color)
        } else {
            drawText(item.label, in: CGRect(x: point.x - 34, y: point.y - 9, width: 68, height: 18),
                     font: .rounded(item.label.count > 4 ? 12.5 : 14, weight: .semibold), color: color)
        }
    }

    private func drawLegend(_ context: CGContext, label: NSColor, muted: NSColor, stroke: NSColor, dark: Bool) {
        let rect = legendRect
        let path = CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil)
        context.addPath(path)
        context.setFillColor((dark ? NSColor(white: 0.16, alpha: 0.55) : NSColor(white: 1, alpha: 0.62)).cgColor)
        context.fillPath()
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.strokePath()

        let segment = rect.width / CGFloat(max(keys.count, 1))
        for (i, (key, keyMode)) in keys.enumerated() {
            let active = keyMode == mode
            let x = rect.minX + CGFloat(i) * segment
            let cap = CGRect(x: x + 12, y: rect.minY + 6, width: 18, height: 18)
            let capPath = CGPath(roundedRect: cap, cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.addPath(capPath)
            context.setFillColor((active ? Self.orange : (dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.07))).cgColor)
            context.fillPath()
            drawText(key.symbol, in: cap.offsetBy(dx: 0, dy: -1), font: .rounded(11, weight: .bold), color: active ? .white : label)
            let title = CGRect(x: cap.maxX + 6, y: rect.minY + 7, width: segment - 42, height: 16)
            drawText(keyMode.title, in: title, font: .rounded(12, weight: active ? .bold : .medium),
                     color: active ? label : muted, alignment: .left)
        }
    }

    private func drawText(_ text: String, in rect: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .center) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        let bounding = attributed.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin])
        let y = rect.minY + (rect.height - min(bounding.height, rect.height)) / 2
        attributed.draw(with: CGRect(x: rect.minX, y: y, width: rect.width, height: min(bounding.height, rect.height) + 1),
                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func hapticTick() {
        guard highlighted != nil else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Selection

    func select(at point: CGPoint) {
        highlighted = WheelGeometry.index(at: point, center: wheelCenter, count: items.count)
    }

    func clearSelection() { highlighted = nil }

    // MARK: Drag destination (drag mode)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragUpdate(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { highlighted != nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let index = highlighted, items.indices.contains(index) else { return false }
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        onChoose?(items[index], urls)
        return true
    }

    private func dragUpdate(_ sender: NSDraggingInfo) -> NSDragOperation {
        select(at: convert(sender.draggingLocation, from: nil))
        guard highlighted != nil else { return [] }
        let mask = sender.draggingSourceOperationMask
        return mask.contains(.copy) ? .copy : (mask.contains(.generic) ? .generic : mask)
    }

    // MARK: Pointer and keyboard (click mode)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { select(at: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) {
        select(at: convert(event.locationInWindow, from: nil))
        if let index = highlighted, items.indices.contains(index) {
            onChoose?(items[index], nil)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        let count = items.count
        switch event.keyCode {
        case 53: // Escape
            onCancel?()
        case 36, 76, 49: // Return, Enter, Space
            if let index = highlighted ?? (count > 0 ? 0 : nil) { onChoose?(items[index], nil) }
        case 124, 125: // Right, Down → clockwise
            guard count > 0 else { return }
            highlighted = ((highlighted ?? -1) + 1) % count
        case 123, 126: // Left, Up → counter-clockwise
            guard count > 0 else { return }
            highlighted = ((highlighted ?? 0) - 1 + count) % count
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option])
        let pressed = flags.subtracting(previousFlags)
        previousFlags = flags
        for key in ModifierKey.allCases where pressed.contains(key.flag) { onModeKey?(key) }
    }
}

extension NSFont {
    static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

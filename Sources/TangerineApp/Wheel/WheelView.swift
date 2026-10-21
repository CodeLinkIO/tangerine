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

    var items: [WheelItem] = [] { didSet { highlighted = nil; needsDisplay = true } }
    var mode: WheelMode = .convert { didSet { needsDisplay = true } }
    var keys: [(ModifierKey, WheelMode)] = [] { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var emptyMessage = "" { didSet { needsDisplay = true } }
    private(set) var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true; hapticTick() } } }

    /// Called with the chosen petal and, for drops, the dropped files.
    var onChoose: ((WheelItem, [URL]?) -> Void)?
    var onCancel: (() -> Void)?
    var onModeKey: ((ModifierKey) -> Void)?

    /// Thumbnail of the dragged file, shown in the center while nothing is highlighted.
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
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
        let label = dark ? NSColor.white : NSColor(srgbRed: 0x29 / 255, green: 0x29 / 255, blue: 0x29 / 255, alpha: 1)
        let muted = dark ? NSColor(white: 1, alpha: 0.55) : NSColor(white: 0, alpha: 0.47)
        let stroke = dark ? NSColor(white: 1, alpha: 0.1) : NSColor(srgbRed: 0x5D / 255, green: 0x66 / 255, blue: 0x66 / 255, alpha: 0.2)
        let surface = dark ? NSColor(white: 0.16, alpha: 0.97) : NSColor(white: 1, alpha: 0.97)

        if items.isEmpty {
            drawSurface(context, path: CGPath(roundedRect: messageRect, cornerWidth: 20, cornerHeight: 20, transform: nil),
                        fill: surface, stroke: stroke, dark: dark)
            drawText(emptyMessage, in: messageRect.insetBy(dx: 18, dy: 14), font: .systemFont(ofSize: 12.5, weight: .medium), color: label)
        } else {
            let paths = petalPaths()
            // One soft shadow under the whole flower, like the website's drop-shadow.
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
                              color: NSColor(srgbRed: 0.15, green: 0.2, blue: 0.22, alpha: dark ? 0.55 : 0.2).cgColor)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            for path in paths {
                context.addPath(path)
                context.setFillColor(surface.cgColor)
                context.fillPath()
            }
            context.endTransparencyLayer()
            context.restoreGState()

            for (index, path) in paths.enumerated() {
                let isOn = index == highlighted
                if isOn {
                    context.addPath(path)
                    context.setFillColor(Theme.nsOrangeHot.cgColor)
                    context.fillPath()
                } else if !dark {
                    // Subtle glass sheen: lighter toward the rim.
                    context.saveGState()
                    context.addPath(path)
                    context.clip()
                    let colors = [NSColor(srgbRed: 0.95, green: 0.96, blue: 0.965, alpha: 1).cgColor, NSColor.white.cgColor] as CFArray
                    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
                        context.drawRadialGradient(gradient, startCenter: wheelCenter, startRadius: WheelGeometry.inner,
                                                   endCenter: wheelCenter, endRadius: WheelGeometry.outer, options: [])
                    }
                    context.restoreGState()
                }
                context.addPath(path)
                context.setStrokeColor(isOn ? NSColor(srgbRed: 0.76, green: 0.4, blue: 0.2, alpha: 0.44).cgColor : stroke.cgColor)
                context.setLineWidth(0.75)
                context.strokePath()
                drawPetalContent(items[index], at: WheelGeometry.labelPoint(index: index, count: items.count, center: wheelCenter),
                                 color: isOn ? .white : label)
            }
            drawCenter(context, label: label, muted: muted, stroke: stroke, surface: surface)
        }
        drawLegend(context, label: label, muted: muted, stroke: stroke, surface: surface, dark: dark)
    }

    /// Center disk: the file's thumbnail, or what the highlighted petal will do.
    private func drawCenter(_ context: CGContext, label: NSColor, muted: NSColor, stroke: NSColor, surface: NSColor) {
        let disk = CGRect(x: wheelCenter.x - 38, y: wheelCenter.y - 38, width: 76, height: 76)
        context.addEllipse(in: disk)
        context.setFillColor(surface.cgColor)
        context.fillPath()
        if let highlighted, items.indices.contains(highlighted) {
            drawText(items[highlighted].centerTitle, in: disk.insetBy(dx: 7, dy: 16), font: .rounded(10.5, weight: .semibold), color: label)
        } else if let thumbnail {
            context.saveGState()
            context.addEllipse(in: disk.insetBy(dx: 4, dy: 4))
            context.clip()
            let inner = disk.insetBy(dx: 4, dy: 4)
            let size = thumbnail.size
            let scale = max(inner.width / max(size.width, 1), inner.height / max(size.height, 1))
            let drawSize = CGSize(width: size.width * scale, height: size.height * scale)
            thumbnail.draw(in: CGRect(x: inner.midX - drawSize.width / 2, y: inner.midY - drawSize.height / 2,
                                      width: drawSize.width, height: drawSize.height))
            context.restoreGState()
        } else {
            drawText(mode.title, in: disk.insetBy(dx: 6, dy: 22).offsetBy(dx: 0, dy: 7), font: .rounded(13, weight: .bold), color: label)
            drawText(subtitle, in: disk.insetBy(dx: 8, dy: 24).offsetBy(dx: 0, dy: -9), font: .rounded(9.5, weight: .medium), color: muted)
        }
        context.addEllipse(in: disk)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(0.75)
        context.strokePath()
    }

    private func drawSurface(_ context: CGContext, path: CGPath, fill: NSColor, stroke: NSColor, dark: Bool) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -4), blur: 14,
                          color: NSColor(srgbRed: 0.15, green: 0.2, blue: 0.22, alpha: dark ? 0.5 : 0.16).cgColor)
        context.addPath(path)
        context.setFillColor(fill.cgColor)
        context.fillPath()
        context.restoreGState()
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(0.75)
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

    /// "⇧ Convert  ⌘ Edit" with keyboard-key caps; the active wheel's key is orange.
    private func drawLegend(_ context: CGContext, label: NSColor, muted: NSColor, stroke: NSColor, surface: NSColor, dark: Bool) {
        let rect = legendRect
        drawSurface(context, path: CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil),
                    fill: surface, stroke: stroke, dark: dark)
        let segment = rect.width / CGFloat(max(keys.count, 1))
        for (i, (key, keyMode)) in keys.enumerated() {
            let active = keyMode == mode
            let x = rect.minX + CGFloat(i) * segment
            let cap = CGRect(x: x + 12, y: rect.minY + 5, width: 20, height: 20)
            let capPath = CGPath(roundedRect: cap, cornerWidth: 5, cornerHeight: 5, transform: nil)
            context.saveGState()
            if !active {
                context.setShadow(offset: CGSize(width: 0, height: -1.5), blur: 0, color: NSColor(white: 0, alpha: dark ? 0.5 : 0.1).cgColor)
            }
            context.addPath(capPath)
            context.setFillColor((active ? Theme.nsOrangeHot : (dark ? NSColor(white: 0.24, alpha: 1) : .white)).cgColor)
            context.fillPath()
            context.restoreGState()
            if !active {
                context.addPath(capPath)
                context.setStrokeColor(stroke.cgColor)
                context.setLineWidth(0.75)
                context.strokePath()
            }
            drawText(key.symbol, in: cap.offsetBy(dx: 0, dy: -1), font: .rounded(11, weight: .bold), color: active ? .white : label)
            let title = CGRect(x: cap.maxX + 7, y: rect.minY + 7, width: segment - 44, height: 16)
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

    #if DEBUG
    /// Highlights a petal without pointer events, for screenshots (TANGERINE_DEMO_PETAL).
    func highlight(_ index: Int) { highlighted = items.indices.contains(index) ? index : nil }
    #endif

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

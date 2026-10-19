import AppKit
import QuartzCore
import TangerineKit

/// Borderless, non-activating panel that floats above everything, including full-screen apps.
final class WheelPanel: NSPanel {
    var allowsKey = false

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: WheelView.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .popUpMenu
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Shows the wheel for dragged or selected files and reports the chosen petal.
@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    static let shared = WheelController()

    enum Interaction {
        /// Opened mid-drag; the user drops onto a petal.
        case drag
        /// Opened from the menu bar, a service or the Finder shortcut; pick with pointer or keyboard.
        case click
    }

    /// Called after the wheel hides with the chosen item and the files it applies to.
    var onChoose: ((WheelItem, [URL]) -> Void)?

    private let panel = WheelPanel()
    private let wheel = WheelView(frame: CGRect(origin: .zero, size: WheelView.size))
    private var files: [URL] = []
    private(set) var interaction: Interaction = .drag
    private(set) var mode: WheelMode = .convert
    private var hideWorkItem: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    override init() {
        super.init()
        let container = NSView(frame: CGRect(origin: .zero, size: WheelView.size))
        container.wantsLayer = true
        container.addSubview(wheel)
        panel.contentView = container
        panel.delegate = self

        wheel.onChoose = { [weak self] item, dropped in self?.choose(item, dropped: dropped) }
        wheel.onCancel = { [weak self] in self?.hide() }
        wheel.onModeKey = { [weak self] key in
            guard let self, let mode = Preferences.shared.mode(for: key) else { return }
            self.setMode(mode)
        }
    }

    // MARK: Showing

    /// Opens the wheel centered at `point` (screen coordinates; defaults to the mouse).
    func show(files: [URL], mode: WheelMode, interaction: Interaction, at point: CGPoint? = nil) {
        hideWorkItem?.cancel()
        self.files = files
        self.interaction = interaction
        let wasVisible = panel.isVisible
        setMode(mode, animated: wasVisible)

        let prefs = Preferences.shared
        wheel.keys = WheelMode.allCases.map { (prefs.key(for: $0), $0) }
        wheel.subtitle = Self.summary(of: files)
        loadThumbnail(for: files)

        if !wasVisible {
            let origin = Self.frameOrigin(centeredAt: point ?? NSEvent.mouseLocation, wheelCenter: wheel.wheelCenter)
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.allowsKey = interaction == .click
            if interaction == .click {
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                panel.makeFirstResponder(wheel)
            } else {
                panel.orderFrontRegardless()
            }
            bloom()
        } else if interaction == .click, !panel.isKeyWindow {
            panel.allowsKey = true
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(wheel)
        }
    }

    private var thumbnailFor: URL?

    /// Shows the first file's Quick Look thumbnail in the center of the wheel.
    private func loadThumbnail(for files: [URL]) {
        guard let first = files.first, first != thumbnailFor else { return }
        thumbnailFor = first
        wheel.thumbnail = nil
        Task { @MainActor in
            let image = await FileThumbnail.thumbnail(for: first, size: 76)
            if self.thumbnailFor == first { self.wheel.thumbnail = image }
        }
    }

    func setMode(_ newMode: WheelMode, animated: Bool = true) {
        mode = newMode
        wheel.mode = newMode
        let items = Self.items(for: newMode, files: files)
        wheel.items = items
        if items.isEmpty {
            let other = Preferences.shared.key(for: newMode == .convert ? .tools : .convert)
            wheel.emptyMessage = newMode == .convert
                ? "No conversions for this file.\nTap \(other.symbol) for edits and tools."
                : "No edits or tools for this file.\nTap \(other.symbol) to convert it."
        }
        if animated, panel.isVisible { pop() }
    }

    /// The drag ended. If it didn't end on a petal, close the wheel shortly after (a drop may still be in flight).
    func dragEnded() {
        guard interaction == .drag, panel.isVisible else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func hide() {
        hideWorkItem?.cancel()
        guard panel.isVisible else { return }
        wheel.clearSelection()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            MainActor.assumeIsolated {
                panel.orderOut(nil)
                panel.allowsKey = false
            }
        })
    }

    private func choose(_ item: WheelItem, dropped: [URL]?) {
        let targets = (dropped?.isEmpty == false ? dropped : nil) ?? files
        hide()
        onChoose?(item, targets)
    }

    func windowDidResignKey(_ notification: Notification) {
        if interaction == .click { hide() }
    }

    // MARK: Items

    static func items(for mode: WheelMode, files: [URL]) -> [WheelItem] {
        let engine = Engine.shared
        switch mode {
        case .convert:
            let available = engine.targets(for: files)
            guard !available.isEmpty else { return [] }
            let category = engine.expand(files).lazy.compactMap(FileFormat.detect).first?.category ?? .image
            let shown = Preferences.shared.wheelTargets(category: category, available: available)
            return shown.map(WheelItem.convert) + [.more]
        case .tools:
            let tools = engine.tools(for: files)
            let capacity = TargetCatalog.wheelCapacity
            guard tools.count > capacity else { return tools.map(WheelItem.tool) }
            return tools.prefix(capacity).map(WheelItem.tool) + [.more]
        }
    }

    static func summary(of files: [URL]) -> String {
        if files.count == 1 {
            let url = files[0]
            if let format = FileFormat.detect(url) { return format.displayName }
            return url.hasDirectoryPath ? "Folder" : url.pathExtension.uppercased()
        }
        return "\(files.count) items"
    }

    // MARK: Placement and animation

    private static func frameOrigin(centeredAt point: CGPoint, wheelCenter: CGPoint) -> CGPoint {
        var origin = CGPoint(x: point.x - wheelCenter.x, y: point.y - wheelCenter.y)
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - WheelView.size.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - WheelView.size.height)
        }
        return origin
    }

    private func bloom() {
        guard let layer = panel.contentView?.layer else {
            panel.alphaValue = 1
            return
        }
        let center = wheel.wheelCenter
        let start = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(center.x, center.y, 0), 0.45, 0.45, 1),
                                           -center.x, -center.y, 0)
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.2
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.24, 1)
        layer.add(animation, forKey: "bloom")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func pop() {
        guard let layer = panel.contentView?.layer else { return }
        let center = wheel.wheelCenter
        let start = CATransform3DTranslate(CATransform3DScale(CATransform3DMakeTranslation(center.x, center.y, 0), 0.9, 0.9, 1),
                                           -center.x, -center.y, 0)
        let animation = CABasicAnimation(keyPath: "sublayerTransform")
        animation.fromValue = NSValue(caTransform3D: start)
        animation.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.24, 1)
        layer.add(animation, forKey: "pop")
    }
}

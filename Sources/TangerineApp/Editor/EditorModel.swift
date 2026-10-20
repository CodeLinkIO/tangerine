import AppKit
import ImageIO
import SwiftUI
import TangerineKit

/// The four editing tools.
enum EditorTool: String, CaseIterable, Identifiable {
    case crop, rotate, flip, resize

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .crop: "crop"
        case .rotate: "rotate.right"
        case .flip: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .resize: "arrow.up.left.and.arrow.down.right"
        }
    }
}

/// Everything undo/redo restores: the geometry recipe plus the resize choice.
struct EditorState: Equatable {
    var recipe = EditRecipe()
    var resize: EditorResize = .original
}

/// State and actions for one editor window.
@MainActor
final class EditorModel: ObservableObject {
    enum Estimate: Equatable {
        case unknown, working, bytes(Int64), failed
    }

    let url: URL
    let sourceFormat: FileFormat
    let options: ConversionOptions
    let onSaved: (URL) -> Void
    let primaryFormats: [FileFormat]
    let moreFormats: [FileFormat]

    // MARK: Loading

    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var isFullResolutionReady = false
    /// Oriented pixel size of the source at full resolution.
    @Published private(set) var sourceSize: CGSize = .zero
    private var pipeline: EditorPipeline?

    // MARK: Edits

    @Published private(set) var state = EditorState()
    @Published private(set) var savedState = EditorState()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var history = EditorHistory<EditorState>()
    private var dragStart: EditorState?
    private var cropEntryState: EditorState?

    /// Unsaved edits. A resize that gives the same pixels (e.g. just opening Custom) doesn't count.
    var isDirty: Bool {
        state.recipe != savedState.recipe || finalSize != (savedState.resize.outputSize(for: croppedSize) ?? croppedSize)
    }
    var recipe: EditRecipe { state.recipe }

    // MARK: UI state

    @Published private(set) var tool: EditorTool?
    @Published private(set) var aspect: EditorAspect = .free
    @Published private(set) var aspectSwapped = false
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero
    @Published var isComparing = false
    @Published private(set) var previewImage: CGImage?
    /// Whether `previewImage` was rendered without the crop (crop mode).
    @Published private(set) var previewIsUncropped = false
    @Published private(set) var originalImage: CGImage?

    // MARK: Export

    @Published var exportFormat: FileFormat { didSet { if exportFormat != oldValue { scheduleEstimate() } } }
    @Published var qualityPreset: QualityPreset { didSet { if qualityPreset != oldValue { scheduleEstimate() } } }
    @Published private(set) var estimate: Estimate = .unknown
    @Published private(set) var isSaving = false
    @Published private(set) var justSaved = false
    @Published var errorMessage: String?

    private var renderInFlight = false
    private var renderPending = false
    private var estimateTask: Task<Void, Never>?

    init(url: URL, options: ConversionOptions, onSaved: @escaping (URL) -> Void) {
        self.url = url
        self.options = options
        self.onSaved = onSaved
        let format = FileFormat.detect(url) ?? .png
        sourceFormat = format
        (primaryFormats, moreFormats) = Self.formatChoices(for: format)
        exportFormat = primaryFormats.first ?? .png
        qualityPreset = Preferences.shared.quality
    }

    /// Four everyday formats (the source's first) as chips; the rest go in "More".
    static func formatChoices(for source: FileFormat) -> (primary: [FileFormat], more: [FileFormat]) {
        let writable = ImageCodec.writableFormats
        var primary: [FileFormat] = []
        for format in [ImageEngine.editOutputFormat(for: source), .jpg, .png, .heic, .webp]
            where writable.contains(format) && !primary.contains(format) && primary.count < 4 {
            primary.append(format)
        }
        var more: [FileFormat] = []
        for format in [FileFormat.webp, .avif, .tiff, .gif, .bmp, .pdf, .jp2, .tga, .exr, .psd, .ico, .icns, .jpg, .png, .heic]
            where writable.contains(format) && !primary.contains(format) && !more.contains(format) {
            more.append(format)
        }
        return (primary, more)
    }

    var isLossy: Bool { [.jpg, .heic, .avif, .webp, .jp2].contains(exportFormat) }

    // MARK: Loading

    func load() {
        let url = self.url
        Task {
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    try ImageCodec.load(url, maxPixelSize: 2000)
                }.value
                let pipeline = EditorPipeline(preview: preview)
                self.pipeline = pipeline
                self.sourceSize = Self.metadataSize(of: url) ?? preview.pixelSize
                self.isLoading = false
                self.scheduleRender()
                self.originalImage = await Task.detached { pipeline.renderOriginal() }.value

                let full = try await Task.detached(priority: .utility) { try ImageCodec.load(url) }.value
                pipeline.setFull(full)
                self.sourceSize = full.pixelSize
                self.isFullResolutionReady = true
                self.scheduleEstimate()
            } catch {
                if self.pipeline == nil {
                    self.isLoading = false
                    self.loadError = error.localizedDescription
                } else {
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    /// Oriented pixel size from metadata, without decoding.
    private static func metadataSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    // MARK: Sizes

    /// Full-resolution size of the image the crop is drawn on (after quarter turns).
    var baseSize: CGSize {
        recipe.quarterTurns % 2 == 0 ? sourceSize : CGSize(width: sourceSize.height, height: sourceSize.width)
    }

    var cropRect: CGRect { recipe.crop ?? EditorCropMath.unit }
    var croppedSize: CGSize { EditorCropMath.pixelSize(of: recipe.crop, baseSize: baseSize) }
    var finalSize: CGSize { state.resize.outputSize(for: croppedSize) ?? croppedSize }

    /// The recipe written on save: geometry plus the resolved output size.
    var exportRecipe: EditRecipe {
        var r = state.recipe
        r.outputSize = state.resize.outputSize(for: croppedSize)
        return r
    }

    /// Crop constraint in normalized units, or nil for a free crop.
    var normalizedCropRatio: CGFloat? {
        aspect.pixelRatio(baseSize: baseSize, swapped: aspectSwapped)
            .map { EditorCropMath.normalizedRatio(pixelRatio: $0, baseSize: baseSize) }
    }

    // MARK: Editing primitives

    /// A discrete change, recorded as one undo step.
    private func apply(_ mutate: (inout EditorState) -> Void) {
        var next = state
        mutate(&next)
        guard next != state else { return }
        let before = state
        setState(next)
        if dragStart == nil {
            history.record(before: before, after: next)
            updateUndoState()
        }
    }

    func undo() {
        finishDrag()
        guard let previous = history.undo(from: state) else { return }
        restore(previous)
    }

    func redo() {
        finishDrag()
        guard let next = history.redo(from: state) else { return }
        restore(next)
    }

    /// Undo/redo target. A portrait/landscape aspect preset turns with the image, as in `rotate`.
    private func restore(_ snapshot: EditorState) {
        if aspect.canSwap, (snapshot.recipe.quarterTurns - state.recipe.quarterTurns) % 2 != 0 { aspectSwapped.toggle() }
        setState(snapshot)
        updateUndoState()
    }

    func resetAll() {
        aspect = .free
        aspectSwapped = false
        apply { $0 = EditorState() }
    }

    private func updateUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func setState(_ next: EditorState) {
        let geometryChanged = next.recipe != state.recipe
        state = next
        if geometryChanged { scheduleRender() }
        scheduleEstimate()
    }

    private func finishDrag() {
        guard let start = dragStart else { return }
        dragStart = nil
        history.record(before: start, after: state)
        updateUndoState()
    }

    // MARK: Tools

    /// Tool buttons: Crop and Resize toggle their options; Rotate and Flip act immediately.
    /// With ⌥, Rotate turns counter-clockwise and Flip mirrors vertically.
    func tap(_ tapped: EditorTool, alternate: Bool = false) {
        switch tapped {
        case .crop, .resize:
            setTool(tool == tapped ? nil : tapped)
        case .rotate:
            setTool(.rotate)
            rotate(clockwise: !alternate)
        case .flip:
            setTool(.flip)
            flip(horizontal: !alternate)
        }
    }

    private func setTool(_ next: EditorTool?) {
        guard next != tool else { return }
        let wasCropping = tool == .crop
        tool = next
        if next == .crop {
            cropEntryState = state
            applyAspectConstraint()
        }
        if wasCropping != (next == .crop) { scheduleRender() }
    }

    /// Return: keep the crop and leave crop mode.
    func commitCrop() {
        guard tool == .crop else { return }
        setTool(nil)
    }

    /// Escape: undo crop changes made since entering crop mode.
    func cancelCrop() {
        guard tool == .crop else { return }
        if let entry = cropEntryState, entry != state { apply { $0 = entry } }
        setTool(nil)
    }

    // MARK: Crop

    func setAspect(_ newAspect: EditorAspect) {
        aspect = newAspect
        if !newAspect.canSwap { aspectSwapped = false }
        applyAspectConstraint()
    }

    func swapAspect() {
        guard aspect.canSwap else { return }
        aspectSwapped.toggle()
        applyAspectConstraint()
    }

    private func applyAspectConstraint() {
        guard let ratio = normalizedCropRatio else { return }
        let fitted = EditorCropMath.fit(ratio: ratio, in: cropRect)
        apply { $0.recipe.crop = EditorCropMath.isFull(fitted) ? nil : fitted }
    }

    /// Called by the canvas while dragging crop handles; one drag is one undo step.
    func updateCrop(_ rect: CGRect, ended: Bool) {
        if dragStart == nil { dragStart = state }
        var next = state
        next.recipe.crop = EditorCropMath.isFull(rect) ? nil : rect
        if next != state { setState(next) }
        if ended { finishDrag() }
    }

    // MARK: Rotate & flip

    func rotate(clockwise: Bool) {
        apply { s in
            // With exactly one mirror applied, a visual clockwise turn is a counter-clockwise quarter turn.
            let mirrored = s.recipe.flipHorizontal != s.recipe.flipVertical
            s.recipe.quarterTurns = ((s.recipe.quarterTurns + (clockwise != mirrored ? 1 : -1)) % 4 + 4) % 4
            if let crop = s.recipe.crop { s.recipe.crop = EditorCropMath.rotated(crop, clockwise: clockwise) }
            s.resize = s.resize.rotated
        }
        if aspect.canSwap { aspectSwapped.toggle() }
    }

    func flip(horizontal: Bool) {
        apply { s in
            if horizontal { s.recipe.flipHorizontal.toggle() } else { s.recipe.flipVertical.toggle() }
            if let crop = s.recipe.crop { s.recipe.crop = EditorCropMath.flipped(crop, horizontally: horizontal) }
        }
    }

    // MARK: Resize

    func setResize(_ resize: EditorResize) {
        apply { $0.resize = resize }
    }

    /// Switches to a custom size, starting from the current result.
    func startCustomSize() {
        guard !state.resize.isCustom else { return }
        let size = finalSize
        setResize(.custom(width: Int(size.width), height: Int(size.height), locked: true))
    }

    /// The custom size as shown in the fields (a locked height follows the crop's aspect).
    var customSize: (width: Int, height: Int, locked: Bool)? {
        guard case let .custom(_, _, locked) = state.resize else { return nil }
        return (Int(finalSize.width), Int(finalSize.height), locked)
    }

    func setCustomWidth(_ width: Int) {
        guard let current = customSize else { return }
        let w = min(max(1, width), Self.maxCustomSide)
        let h = current.locked ? max(1, Int((CGFloat(w) * croppedSize.height / croppedSize.width).rounded())) : current.height
        setResize(Self.clampedCustom(width: w, height: h, locked: current.locked))
    }

    func setCustomHeight(_ height: Int) {
        guard let current = customSize else { return }
        let h = min(max(1, height), Self.maxCustomSide)
        let w = current.locked ? max(1, Int((CGFloat(h) * croppedSize.width / croppedSize.height).rounded())) : current.width
        setResize(Self.clampedCustom(width: w, height: h, locked: current.locked))
    }

    private static let maxCustomSide = 30_000

    /// Scales a custom size down, keeping its proportions, so neither side passes `maxCustomSide` and the area
    /// stays within the renderer's pixel budget (with room for rounding). A locked side derived from a big value
    /// would otherwise ask for e.g. 30000×53333 and exhaust memory on the next size estimate.
    private static func clampedCustom(width: Int, height: Int, locked: Bool) -> EditorResize {
        var scale = min(1, CGFloat(maxCustomSide) / CGFloat(max(width, height)))
        let budget = CGFloat(ImageCodec.maxPixelCount) * 0.99
        let area = CGFloat(width) * CGFloat(height) * scale * scale
        if area > budget { scale *= (budget / area).squareRoot() }
        guard scale < 1 else { return .custom(width: width, height: height, locked: locked) }
        return .custom(width: max(1, Int((CGFloat(width) * scale).rounded(.down))),
                       height: max(1, Int((CGFloat(height) * scale).rounded(.down))), locked: locked)
    }

    func toggleCustomLock() {
        guard let current = customSize else { return }
        setResize(.custom(width: current.width, height: current.height, locked: !current.locked))
    }

    // MARK: Zoom

    func zoomIn() { zoom = min(8, zoom * 1.25) }
    func zoomOut() { zoom = max(0.25, zoom / 1.25) }

    func zoomToFit() {
        zoom = 1
        pan = .zero
    }

    // MARK: Rendering

    private func scheduleRender() {
        renderPending = true
        guard !renderInFlight, let pipeline else { return }
        renderPending = false
        renderInFlight = true
        let recipe = self.recipe, cropMode = tool == .crop
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                pipeline.renderPreview(recipe, cropMode: cropMode)
            }.value
            if let image {
                self.previewImage = image
                self.previewIsUncropped = cropMode
            }
            self.renderInFlight = false
            if self.renderPending { self.scheduleRender() }
        }
    }

    private func scheduleEstimate() {
        estimateTask?.cancel()
        guard let pipeline, isFullResolutionReady else { return }
        estimate = .working
        let recipe = exportRecipe, format = exportFormat, quality = self.quality, options = self.options
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            do {
                let bytes = try await pipeline.estimateSize(recipe, format: format, quality: quality, options: options)
                guard !Task.isCancelled else { return }
                self.estimate = .bytes(bytes)
            } catch {
                guard !Task.isCancelled else { return }
                self.estimate = .failed
            }
        }
    }

    // MARK: Saving

    private var quality: Double { qualityPreset.imageQuality }

    /// Shown when the chosen format would drop the image's transparency.
    var transparencyHint: String? {
        guard pipeline?.sourceHasAlpha == true, !ImageCodec.supportsAlpha(exportFormat) else { return nil }
        let fill = options.flattenBackground == .black ? "black" : "white"
        return "\(exportFormat.displayName) has no transparency, so see-through areas become \(fill)."
    }

    /// Whether the file holds more than the one frame or page being edited (animated GIF, multi-page TIFF).
    private var hasOtherFrames: Bool { (pipeline?.frameCount ?? 1) > 1 }

    /// Replacing keeps the original's format, so it needs that format selected. Files with several frames
    /// would lose all but the first.
    var canReplaceOriginal: Bool {
        exportFormat == sourceFormat && ImageCodec.writableFormats.contains(sourceFormat)
            && ![.ico, .icns, .pdf].contains(sourceFormat) && !hasOtherFrames
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    var replaceHelp: String {
        if canReplaceOriginal { return "Overwrite “\(url.lastPathComponent)”" }
        if hasOtherFrames { return "Only the first frame is edited, so save a copy instead" }
        return "Choose \(sourceFormat.displayName) to replace the original"
    }

    /// Writes "<name> edited.<ext>" next to the original. Returns true on success.
    @discardableResult
    func saveCopy() async -> Bool {
        guard !isSaving, let pipeline else { return false }
        guard isFullResolutionReady else {
            errorMessage = "The full-resolution image is still loading. Try again in a moment."
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let directory = Engine.outputDirectory(for: url, preferred: nil)
        let destination = OutputPlan(for: url, directory: directory).file(extension: exportFormat.fileExtension, suffix: "edited")
        do {
            try await pipeline.export(exportRecipe, format: exportFormat, quality: quality, options: options, to: destination)
            savedState = state
            onSaved(destination)
            flashSaved()
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the original file, then reloads it as the new starting point.
    func replaceOriginal() async {
        guard !isSaving, canReplaceOriginal, let pipeline, isFullResolutionReady else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let fm = FileManager.default
            let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fm.removeItem(at: scratch) }
            let temp = scratch.appendingPathComponent(url.lastPathComponent)
            try await pipeline.export(exportRecipe, format: sourceFormat, quality: quality, options: options, to: temp)
            _ = try fm.replaceItemAt(url, withItemAt: temp)
            onSaved(url)
            reloadAfterReplace()
            flashSaved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func flashSaved() {
        justSaved = true
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            self.justSaved = false
        }
    }

    private func reloadAfterReplace() {
        history.clear()
        updateUndoState()
        state = EditorState()
        savedState = EditorState()
        tool = nil
        aspect = .free
        aspectSwapped = false
        previewImage = nil
        isFullResolutionReady = false
        estimate = .unknown
        pipeline = nil
        isLoading = true
        load()
    }
}

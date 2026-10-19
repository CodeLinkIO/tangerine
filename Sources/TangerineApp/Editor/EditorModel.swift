import AppKit
import Combine
import ImageIO
import SwiftUI
import TangerineKit

enum EditorSection: String, CaseIterable, Identifiable {
    case crop, adjust, filters, background, resize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: "Crop"
        case .adjust: "Adjust"
        case .filters: "Filters"
        case .background: "Background"
        case .resize: "Resize"
        }
    }

    var symbol: String {
        switch self {
        case .crop: "crop.rotate"
        case .adjust: "slider.horizontal.3"
        case .filters: "camera.filters"
        case .background: "person.crop.rectangle"
        case .resize: "arrow.up.left.and.arrow.down.right"
        }
    }
}

enum EditorFill: String, CaseIterable, Identifiable {
    case transparent, white, black, custom

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum EditorResizeUnit: String, CaseIterable, Identifiable {
    case pixels, percent

    var id: String { rawValue }
    var title: String { self == .pixels ? "Pixels" : "Percent" }
}

/// State and actions for one editor window.
@MainActor
final class EditorModel: ObservableObject {
    enum Status: Equatable {
        case idle, working, failed(String)
    }

    enum Estimate: Equatable {
        case unknown, working, bytes(Int64), failed
    }

    let url: URL
    let sourceFormat: FileFormat
    let defaults: ConversionOptions
    let onSaved: (URL) -> Void

    // MARK: Loading

    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?
    @Published private(set) var isFullResolutionReady = false
    /// Oriented pixel size of the source at full resolution.
    @Published private(set) var sourceSize: CGSize = .zero
    private(set) var pipeline: EditorPipeline?

    // MARK: Edits

    @Published private(set) var recipe = EditRecipe()
    @Published private(set) var savedRecipe = EditRecipe()
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var history = EditorHistory<EditRecipe>()
    private var continuousStart: EditRecipe?
    private var lastCoalesceKey: String?
    private var lastCoalesceTime = Date.distantPast

    var isDirty: Bool { recipe != savedRecipe }

    // MARK: UI state

    @Published var section: EditorSection = .adjust {
        didSet {
            guard section != oldValue else { return }
            if (oldValue == .crop) != (section == .crop) { scheduleRender() }
            if section == .filters { scheduleThumbnails(immediately: true) }
        }
    }
    @Published var aspect: EditorAspect = .free
    @Published var aspectSwapped = false
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero
    @Published var isComparing = false
    @Published var resizeUnit: EditorResizeUnit = .pixels
    @Published var resizeLocked = true
    @Published var customFill = Color(.sRGB, red: 0.95, green: 0.36, blue: 0.16, opacity: 1)

    @Published private(set) var previewImage: CGImage?
    /// Whether `previewImage` was rendered without the crop (crop mode).
    @Published private(set) var previewIsUncropped = false
    @Published private(set) var originalImage: CGImage?
    @Published private(set) var filterThumbnails: [FilterPreset: CGImage] = [:]
    @Published private(set) var cutoutStatus: Status = .idle

    // MARK: Export

    @Published var exportFormat: FileFormat { didSet { if exportFormat != oldValue { scheduleEstimate() } } }
    @Published var quality: Double { didSet { if quality != oldValue { scheduleEstimate() } } }
    @Published var stripMetadata: Bool { didSet { if stripMetadata != oldValue { scheduleEstimate() } } }
    @Published private(set) var estimate: Estimate = .unknown
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    let exportFormats: [FileFormat]

    private var renderInFlight = false
    private var renderPending = false
    private var estimateTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?

    init(url: URL, options: ConversionOptions, onSaved: @escaping (URL) -> Void) {
        self.url = url
        self.defaults = options
        self.onSaved = onSaved
        let format = FileFormat.detect(url) ?? .png
        sourceFormat = format
        exportFormats = Self.exportFormats(for: format)
        exportFormat = exportFormats.first ?? .png
        quality = options.imageQuality
        stripMetadata = options.stripImageMetadata
    }

    static func exportFormats(for source: FileFormat) -> [FileFormat] {
        let order: [FileFormat] = [ImageEngine.editOutputFormat(for: source), .jpg, .png, .heic, .webp, .avif, .tiff,
                                   .gif, .bmp, .pdf, .jp2, .tga, .exr, .psd, .ico, .icns]
        let writable = ImageCodec.writableFormats
        var result: [FileFormat] = []
        for format in order where writable.contains(format) && !result.contains(format) { result.append(format) }
        return result
    }

    static func isLossy(_ format: FileFormat) -> Bool {
        [.jpg, .heic, .avif, .webp, .jp2].contains(format)
    }

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
    var finalSize: CGSize { recipe.outputSize ?? croppedSize }

    /// Crop constraint in normalized units, or nil for a free crop.
    var normalizedCropRatio: CGFloat? {
        aspect.pixelRatio(baseSize: baseSize, swapped: aspectSwapped)
            .map { EditorCropMath.normalizedRatio(pixelRatio: $0, baseSize: baseSize) }
    }

    var canSwapAspect: Bool { ![.free, .square, .original].contains(aspect) }

    // MARK: Editing primitives

    /// A discrete change: recorded as one undo step (or merged with the previous step for the same key within 1 s).
    func change(coalescing key: String? = nil, _ mutate: (inout EditRecipe) -> Void) {
        var next = recipe
        mutate(&next)
        guard next != recipe else { return }
        let before = recipe
        setRecipe(next)
        guard continuousStart == nil else { return }
        let now = Date()
        if let key, key == lastCoalesceKey, now.timeIntervalSince(lastCoalesceTime) < 1 {
            lastCoalesceTime = now
            return
        }
        lastCoalesceKey = key
        lastCoalesceTime = now
        history.record(before: before, after: next)
        updateUndoState()
    }

    /// Starts a drag-style edit; everything until `endContinuousEdit` becomes one undo step.
    func beginContinuousEdit() {
        if continuousStart == nil { continuousStart = recipe }
    }

    func endContinuousEdit() {
        guard let start = continuousStart else { return }
        continuousStart = nil
        lastCoalesceKey = nil
        history.record(before: start, after: recipe)
        updateUndoState()
    }

    /// Live update during a continuous edit (no undo step on its own).
    func update(_ mutate: (inout EditRecipe) -> Void) {
        beginContinuousEdit()
        var next = recipe
        mutate(&next)
        if next != recipe { setRecipe(next) }
    }

    func undo() {
        endContinuousEdit()
        guard let previous = history.undo(from: recipe) else { return }
        lastCoalesceKey = nil
        setRecipe(previous)
        updateUndoState()
    }

    func redo() {
        endContinuousEdit()
        guard let next = history.redo(from: recipe) else { return }
        lastCoalesceKey = nil
        setRecipe(next)
        updateUndoState()
    }

    func resetAll() {
        aspect = .free
        aspectSwapped = false
        cutoutStatus = .idle
        change { $0 = EditRecipe() }
    }

    private func updateUndoState() {
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func setRecipe(_ next: EditRecipe) {
        let old = recipe
        recipe = next
        scheduleRender()
        scheduleEstimate()
        var oldNoFilter = old, newNoFilter = next
        oldNoFilter.filter = .none
        newNoFilter.filter = .none
        if section == .filters, oldNoFilter != newNoFilter { scheduleThumbnails(immediately: false) }
    }

    // MARK: Crop & geometry

    func setAspect(_ newAspect: EditorAspect) {
        aspect = newAspect
        if !canSwapAspect { aspectSwapped = false }
        applyAspectConstraint()
    }

    func swapAspect() {
        guard canSwapAspect else { return }
        aspectSwapped.toggle()
        applyAspectConstraint()
    }

    private func applyAspectConstraint() {
        guard let ratio = normalizedCropRatio else { return }
        let fitted = EditorCropMath.fit(ratio: ratio, in: cropRect)
        change { $0.crop = EditorCropMath.isFull(fitted) ? nil : fitted; Self.syncOutputSize(&$0, locked: self.resizeLocked, base: self.baseSize) }
    }

    /// Called by the canvas while dragging crop handles.
    func updateCrop(_ rect: CGRect, ended: Bool) {
        update { recipe in
            recipe.crop = EditorCropMath.isFull(rect) ? nil : rect
            Self.syncOutputSize(&recipe, locked: resizeLocked, base: baseSize)
        }
        if ended { endContinuousEdit() }
    }

    /// Keeps a locked output size proportional to a changed crop (width wins).
    private static func syncOutputSize(_ recipe: inout EditRecipe, locked: Bool, base: CGSize) {
        guard locked, let size = recipe.outputSize else { return }
        let cropped = EditorCropMath.pixelSize(of: recipe.crop, baseSize: base)
        recipe.outputSize = CGSize(width: size.width, height: max(1, (size.width * cropped.height / cropped.width).rounded()))
    }

    func rotate(clockwise: Bool) {
        change { r in
            // With exactly one mirror applied, a visual clockwise turn is a counter-clockwise quarter turn.
            let mirrored = r.flipHorizontal != r.flipVertical
            r.quarterTurns = ((r.quarterTurns + (clockwise != mirrored ? 1 : -1)) % 4 + 4) % 4
            if let crop = r.crop { r.crop = EditorCropMath.rotated(crop, clockwise: clockwise) }
            if let size = r.outputSize { r.outputSize = CGSize(width: size.height, height: size.width) }
        }
        if canSwapAspect { aspectSwapped.toggle() }
    }

    func flip(horizontal: Bool) {
        change { r in
            if horizontal { r.flipHorizontal.toggle() } else { r.flipVertical.toggle() }
            // Mirroring reverses the straighten direction.
            r.straighten = -r.straighten
            if let crop = r.crop { r.crop = EditorCropMath.flipped(crop, horizontally: horizontal) }
        }
    }

    func resetGeometry() {
        aspect = .free
        aspectSwapped = false
        change { r in
            r.crop = nil
            r.straighten = 0
            r.quarterTurns = 0
            r.flipHorizontal = false
            r.flipVertical = false
            Self.syncOutputSize(&r, locked: resizeLocked, base: sourceSize)
        }
    }

    var hasGeometryEdits: Bool {
        recipe.crop != nil || recipe.straighten != 0 || recipe.quarterTurns != 0 || recipe.flipHorizontal || recipe.flipVertical
    }

    // MARK: Adjustments

    var hasColorEdits: Bool {
        var colorOnly = EditRecipe()
        colorOnly.filter = recipe.filter
        var current = recipe
        current.quarterTurns = 0; current.flipHorizontal = false; current.flipVertical = false
        current.straighten = 0; current.crop = nil; current.outputSize = nil
        current.removeBackground = false; current.backgroundFill = nil
        return current != colorOnly
    }

    func resetAdjustments() {
        change { r in
            r.autoEnhance = false
            r.exposure = 0; r.brightness = 0; r.contrast = 0; r.highlights = 0; r.shadows = 0
            r.saturation = 0; r.vibrance = 0; r.temperature = 0; r.tint = 0; r.sharpness = 0; r.vignette = 0
        }
    }

    // MARK: Background

    func setRemoveBackground(_ on: Bool) {
        guard on else {
            cutoutStatus = .idle
            change { $0.removeBackground = false }
            return
        }
        guard let pipeline else { return }
        cutoutStatus = .working
        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) { try pipeline.preparePreviewCutout() }.value
                self.cutoutStatus = .idle
                self.change { $0.removeBackground = true }
            } catch {
                self.cutoutStatus = .failed(error.localizedDescription)
            }
        }
    }

    var fill: EditorFill {
        guard let fill = recipe.backgroundFill else { return .transparent }
        if fill == .white { return .white }
        if fill == .black { return .black }
        return .custom
    }

    func setFill(_ choice: EditorFill) {
        change { r in
            switch choice {
            case .transparent: r.backgroundFill = nil
            case .white: r.backgroundFill = .white
            case .black: r.backgroundFill = .black
            case .custom: r.backgroundFill = Self.solid(customFill)
            }
        }
    }

    func setCustomFill(_ color: Color) {
        customFill = color
        change(coalescing: "fill") { $0.backgroundFill = Self.solid(color) }
    }

    static func solid(_ color: Color) -> SolidColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        return SolidColor(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    // MARK: Resize

    func setResizeEnabled(_ on: Bool) {
        change { $0.outputSize = on ? self.croppedSize : nil }
    }

    func setOutputWidth(_ width: Double) {
        let w = max(1, min(width.rounded(), 30_000))
        change(coalescing: "resize") { r in
            let current = r.outputSize ?? croppedSize
            let h = resizeLocked ? max(1, (w * croppedSize.height / croppedSize.width).rounded()) : current.height
            r.outputSize = CGSize(width: w, height: h)
        }
    }

    func setOutputHeight(_ height: Double) {
        let h = max(1, min(height.rounded(), 30_000))
        change(coalescing: "resize") { r in
            let current = r.outputSize ?? croppedSize
            let w = resizeLocked ? max(1, (h * croppedSize.width / croppedSize.height).rounded()) : current.width
            r.outputSize = CGSize(width: w, height: h)
        }
    }

    var scalePercent: Double {
        guard croppedSize.width > 0 else { return 100 }
        return (finalSize.width / croppedSize.width * 100).rounded()
    }

    func setScalePercent(_ percent: Double) {
        let p = max(1, min(percent, 400)) / 100
        change(coalescing: "resize") { r in
            r.outputSize = CGSize(width: max(1, (croppedSize.width * p).rounded()), height: max(1, (croppedSize.height * p).rounded()))
        }
    }

    func fitLongestEdge(_ pixels: Double) {
        let longest = max(croppedSize.width, croppedSize.height)
        guard longest > 0 else { return }
        setScalePercent(min(100, pixels / longest * 100))
    }

    // MARK: Zoom

    func zoomIn() { zoom = min(8, zoom * 1.25) }
    func zoomOut() { zoom = max(0.25, zoom / 1.25) }

    func zoomToFit() {
        zoom = 1
        pan = .zero
    }

    // MARK: Rendering

    func scheduleRender() {
        renderPending = true
        guard !renderInFlight, let pipeline else { return }
        renderPending = false
        renderInFlight = true
        let recipe = self.recipe, cropMode = section == .crop
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

    private func scheduleThumbnails(immediately: Bool) {
        thumbnailTask?.cancel()
        guard let pipeline else { return }
        let recipe = self.recipe
        thumbnailTask = Task {
            if !immediately { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            let thumbnails = await Task.detached(priority: .utility) { pipeline.renderFilterThumbnails(recipe) }.value
            guard !Task.isCancelled else { return }
            self.filterThumbnails = thumbnails
        }
    }

    private func scheduleEstimate() {
        estimateTask?.cancel()
        guard let pipeline, isFullResolutionReady else { return }
        estimate = .working
        let recipe = self.recipe, format = exportFormat, quality = self.quality, strip = stripMetadata
        let background = defaults.flattenBackground
        estimateTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            do {
                let bytes = try await pipeline.estimateSize(recipe, format: format, quality: quality,
                                                            stripMetadata: strip, background: background)
                guard !Task.isCancelled else { return }
                self.estimate = .bytes(bytes)
            } catch {
                guard !Task.isCancelled else { return }
                self.estimate = .failed
            }
        }
    }

    // MARK: Saving

    var transparencyWarning: String? {
        guard recipe.removeBackground, recipe.backgroundFill == nil, !ImageCodec.supportsAlpha(exportFormat) else { return nil }
        return "\(exportFormat.displayName) can't store transparency, so the background will be white."
    }

    var canOverwrite: Bool {
        ImageCodec.writableFormats.contains(sourceFormat) && ![.ico, .icns, .pdf].contains(sourceFormat)
            && FileManager.default.isWritableFile(atPath: url.path)
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
            try await pipeline.export(recipe, format: exportFormat, quality: quality, stripMetadata: stripMetadata,
                                      background: defaults.flattenBackground, to: destination)
            savedRecipe = recipe
            onSaved(destination)
            return true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Replaces the original file (same format), then reloads it as the new starting point.
    func overwrite() async {
        guard !isSaving, canOverwrite, let pipeline, isFullResolutionReady else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let fm = FileManager.default
            let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
            defer { try? fm.removeItem(at: scratch) }
            let temp = scratch.appendingPathComponent(url.lastPathComponent)
            try await pipeline.export(recipe, format: sourceFormat, quality: quality, stripMetadata: stripMetadata,
                                      background: defaults.flattenBackground, to: temp)
            _ = try fm.replaceItemAt(url, withItemAt: temp)
            onSaved(url)
            reloadAfterOverwrite()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadAfterOverwrite() {
        history.clear()
        updateUndoState()
        recipe = EditRecipe()
        savedRecipe = EditRecipe()
        aspect = .free
        aspectSwapped = false
        cutoutStatus = .idle
        filterThumbnails = [:]
        previewImage = nil
        isFullResolutionReady = false
        estimate = .unknown
        pipeline = nil
        isLoading = true
        load()
    }
}

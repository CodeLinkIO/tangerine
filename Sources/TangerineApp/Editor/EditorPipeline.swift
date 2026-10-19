import CoreImage
import Foundation
import TangerineKit

/// Renders the editor's preview, thumbnails and exports off the main thread.
/// Background removal is expensive (Vision), so cutouts are computed once per source and reused.
final class EditorPipeline: @unchecked Sendable {
    let previewSource: CIImage
    /// Color space previews and exports render in (the source's RGB space, else sRGB).
    let colorSpace: CGColorSpace

    private let lock = NSLock()
    private var previewCutout: CIImage?
    private var fullCutout: CIImage?
    private var fullImage: LoadedImage?

    private var renderer: RecipeRenderer { .shared }

    init(preview: LoadedImage) {
        previewSource = CIImage(cgImage: preview.image)
        if let space = preview.image.colorSpace, space.model == .rgb {
            colorSpace = space
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    // MARK: Sources

    func setFull(_ image: LoadedImage) {
        lock.lock(); fullImage = image; lock.unlock()
    }

    var full: LoadedImage? {
        lock.lock(); defer { lock.unlock() }
        return fullImage
    }

    /// Computes (or returns the cached) preview cutout. Throws when no subject is found.
    func preparePreviewCutout() throws -> CIImage {
        lock.lock()
        if let previewCutout { lock.unlock(); return previewCutout }
        lock.unlock()
        let cutout = try RecipeRenderer.foregroundCutout(previewSource)
        lock.lock(); previewCutout = cutout; lock.unlock()
        return cutout
    }

    private func fullCutoutImage(for source: CIImage) throws -> CIImage {
        lock.lock()
        if let fullCutout { lock.unlock(); return fullCutout }
        lock.unlock()
        let cutout = try RecipeRenderer.foregroundCutout(source)
        lock.lock(); fullCutout = cutout; lock.unlock()
        return cutout
    }

    // MARK: Pipeline

    /// Applies `recipe` using a pre-computed cutout instead of running Vision on every frame.
    private func pipeline(_ source: CIImage, cutout: CIImage?, recipe: EditRecipe) -> CIImage {
        var input = source
        var recipe = recipe
        if recipe.removeBackground, let cutout {
            input = cutout
            if let fill = recipe.backgroundFill {
                input = cutout.composited(over: CIImage(color: CIColor(red: fill.red, green: fill.green, blue: fill.blue))
                    .cropped(to: cutout.extent))
            }
        }
        recipe.removeBackground = false
        recipe.backgroundFill = nil
        return renderer.apply(recipe, to: input)
    }

    /// The canvas image. In crop mode the crop is not applied so the overlay can show the whole frame.
    func renderPreview(_ recipe: EditRecipe, cropMode: Bool) -> CGImage? {
        var recipe = recipe
        recipe.outputSize = nil
        if cropMode { recipe.crop = nil }
        let cutout = recipe.removeBackground ? (try? preparePreviewCutout()) : nil
        return try? renderer.render(pipeline(previewSource, cutout: cutout, recipe: recipe), colorSpace: colorSpace)
    }

    /// The untouched preview, shown while comparing.
    func renderOriginal() -> CGImage? {
        try? renderer.render(previewSource, colorSpace: colorSpace)
    }

    /// Small live thumbnails of every filter applied to the current edit.
    func renderFilterThumbnails(_ recipe: EditRecipe, maxPixel: CGFloat = 180) -> [FilterPreset: CGImage] {
        var base = recipe
        base.filter = .none
        base.outputSize = nil
        let cutout = base.removeBackground ? (try? preparePreviewCutout()) : nil
        var image = pipeline(previewSource, cutout: cutout, recipe: base)
        let e = image.extent
        let scale = min(1, maxPixel / max(e.width, e.height, 1))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let small = try? renderer.render(image, colorSpace: colorSpace) else { return [:] }
        let smallImage = CIImage(cgImage: small)

        var result: [FilterPreset: CGImage] = [:]
        for preset in FilterPreset.allCases {
            var only = EditRecipe()
            only.filter = preset
            result[preset] = preset == .none ? small : try? renderer.render(renderer.apply(only, to: smallImage), colorSpace: colorSpace)
        }
        return result
    }

    // MARK: Export

    /// Full-resolution render of `recipe` (needs the full image to be loaded).
    func renderFull(_ recipe: EditRecipe) throws -> (CGImage, LoadedImage) {
        guard let full else { throw ConversionError.failed("The image is still loading.") }
        let source = CIImage(cgImage: full.image)
        let cutout = recipe.removeBackground ? try fullCutoutImage(for: source) : nil
        let image = try renderer.render(pipeline(source, cutout: cutout, recipe: recipe), colorSpace: colorSpace)
        return (image, full)
    }

    static func writeOptions(for loaded: LoadedImage, quality: Double, stripMetadata: Bool,
                             background: SolidColor) -> ImageCodec.WriteOptions {
        ImageCodec.WriteOptions(quality: quality, background: background,
                                properties: stripMetadata ? nil : loaded.properties, dpi: loaded.dpi)
    }

    /// Encoded size of the full-resolution result in `format`.
    func estimateSize(_ recipe: EditRecipe, format: FileFormat, quality: Double, stripMetadata: Bool,
                      background: SolidColor) async throws -> Int64 {
        let (image, loaded) = try renderFull(recipe)
        try Task.checkCancellation()
        let options = Self.writeOptions(for: loaded, quality: quality, stripMetadata: stripMetadata, background: background)
        if format == .webp || format == .pdf {
            let temp = try TemporaryDirectory()
            let url = temp.file("estimate.\(format.fileExtension)")
            try await ImageCodec.write(image, as: format, to: url, options: options)
            return url.fileSize
        }
        return Int64(try ImageCodec.encode(image, as: format, options: options).count)
    }

    /// Renders and writes the result to `url`.
    func export(_ recipe: EditRecipe, format: FileFormat, quality: Double, stripMetadata: Bool,
                background: SolidColor, to url: URL) async throws {
        let (image, loaded) = try renderFull(recipe)
        let options = Self.writeOptions(for: loaded, quality: quality, stripMetadata: stripMetadata, background: background)
        try await ImageCodec.write(image, as: format, to: url, options: options)
    }
}

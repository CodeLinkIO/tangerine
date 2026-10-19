import CoreImage
import Foundation
import TangerineKit

/// Renders the editor's preview and exports off the main thread.
final class EditorPipeline: @unchecked Sendable {
    let previewSource: CIImage
    /// Color space previews and exports render in (the source's RGB space, else sRGB).
    let colorSpace: CGColorSpace
    let sourceHasAlpha: Bool

    private let lock = NSLock()
    private var fullImage: LoadedImage?
    private var renderer: RecipeRenderer { .shared }

    init(preview: LoadedImage) {
        previewSource = CIImage(cgImage: preview.image)
        sourceHasAlpha = preview.hasAlpha
        if let space = preview.image.colorSpace, space.model == .rgb {
            colorSpace = space
        } else {
            colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        }
    }

    func setFull(_ image: LoadedImage) {
        lock.lock(); fullImage = image; lock.unlock()
    }

    private var full: LoadedImage? {
        lock.lock(); defer { lock.unlock() }
        return fullImage
    }

    /// The canvas image. In crop mode the crop is not applied so the overlay can show the whole frame.
    func renderPreview(_ recipe: EditRecipe, cropMode: Bool) -> CGImage? {
        var recipe = recipe
        recipe.outputSize = nil
        if cropMode { recipe.crop = nil }
        return try? renderer.render(renderer.apply(recipe, to: previewSource), colorSpace: colorSpace)
    }

    /// The untouched preview, shown while holding Space.
    func renderOriginal() -> CGImage? {
        try? renderer.render(previewSource, colorSpace: colorSpace)
    }

    /// Full-resolution render of `recipe` (needs the full image to be loaded).
    private func renderFull(_ recipe: EditRecipe) throws -> (CGImage, LoadedImage) {
        guard let full else { throw ConversionError.failed("The image is still loading.") }
        let image = try renderer.render(renderer.apply(recipe, to: CIImage(cgImage: full.image)), colorSpace: colorSpace)
        return (image, full)
    }

    private static func writeOptions(for loaded: LoadedImage, quality: Double, options: ConversionOptions) -> ImageCodec.WriteOptions {
        ImageCodec.WriteOptions(quality: quality, background: options.flattenBackground,
                                properties: options.stripImageMetadata ? nil : loaded.properties, dpi: loaded.dpi)
    }

    /// Encoded size of the full-resolution result in `format`.
    func estimateSize(_ recipe: EditRecipe, format: FileFormat, quality: Double, options: ConversionOptions) async throws -> Int64 {
        let (image, loaded) = try renderFull(recipe)
        try Task.checkCancellation()
        let writeOptions = Self.writeOptions(for: loaded, quality: quality, options: options)
        if format == .webp || format == .pdf {
            let temp = try TemporaryDirectory()
            let url = temp.file("estimate.\(format.fileExtension)")
            try await ImageCodec.write(image, as: format, to: url, options: writeOptions)
            return url.fileSize
        }
        return Int64(try ImageCodec.encode(image, as: format, options: writeOptions).count)
    }

    /// Renders and writes the result to `url`.
    func export(_ recipe: EditRecipe, format: FileFormat, quality: Double, options: ConversionOptions, to url: URL) async throws {
        let (image, loaded) = try renderFull(recipe)
        try await ImageCodec.write(image, as: format, to: url, options: Self.writeOptions(for: loaded, quality: quality, options: options))
    }
}

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import TangerineCore
import Vision

public enum FilterPreset: String, CaseIterable, Codable, Sendable {
    case none, mono, noir, chrome, fade, instant, process, tonal, transfer, sepia

    public var title: String {
        self == .none ? "Original" : rawValue.capitalized
    }

    fileprivate func apply(to image: CIImage) -> CIImage {
        let name: String
        switch self {
        case .none: return image
        case .sepia:
            let filter = CIFilter.sepiaTone()
            filter.inputImage = image
            filter.intensity = 0.85
            return filter.outputImage ?? image
        case .mono: name = "CIPhotoEffectMono"
        case .noir: name = "CIPhotoEffectNoir"
        case .chrome: name = "CIPhotoEffectChrome"
        case .fade: name = "CIPhotoEffectFade"
        case .instant: name = "CIPhotoEffectInstant"
        case .process: name = "CIPhotoEffectProcess"
        case .tonal: name = "CIPhotoEffectTonal"
        case .transfer: name = "CIPhotoEffectTransfer"
        }
        guard let filter = CIFilter(name: name) else { return image }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage ?? image
    }
}

/// A non-destructive list of edits. The editor mutates it; `ImageRenderer` turns it into pixels.
/// Adjustment values are normalized to -1...1 (0 = unchanged) unless noted.
public struct EditRecipe: Codable, Equatable, Sendable {
    // Geometry, applied in this order: background removal, quarter turns, flips, straighten, crop, resize.
    public var quarterTurns = 0               // clockwise 90° steps
    public var flipHorizontal = false
    public var flipVertical = false
    public var straighten = 0.0               // degrees, -45...45
    /// Crop in normalized coordinates of the rotated/straightened image, top-left origin.
    public var crop: CGRect? = nil
    /// Output size in pixels, applied last.
    public var outputSize: CGSize? = nil

    // Light and color
    public var autoEnhance = false
    public var exposure = 0.0
    public var brightness = 0.0
    public var contrast = 0.0
    public var highlights = 0.0
    public var shadows = 0.0
    public var saturation = 0.0
    public var vibrance = 0.0
    public var temperature = 0.0
    public var tint = 0.0
    public var sharpness = 0.0                // 0...1
    public var vignette = 0.0                 // 0...1
    public var filter: FilterPreset = .none

    public var removeBackground = false
    /// Fill behind a removed background; nil keeps transparency.
    public var backgroundFill: SolidColor? = nil

    public init() {}

    public var isIdentity: Bool { self == EditRecipe() }

    /// True when only geometry changes (lets exports skip color processing).
    var hasColorAdjustments: Bool {
        autoEnhance || exposure != 0 || brightness != 0 || contrast != 0 || highlights != 0 || shadows != 0
            || saturation != 0 || vibrance != 0 || temperature != 0 || tint != 0 || sharpness != 0
            || vignette != 0 || filter != .none
    }
}

/// Renders `EditRecipe`s with Core Image on the GPU.
public final class ImageRenderer: @unchecked Sendable {
    public static let shared = ImageRenderer()

    public let context = CIContext(options: [.cacheIntermediates: false, .name: "Tangerine"])

    // MARK: Pipeline

    /// Applies everything except crop and resize, i.e. the image the crop overlay is drawn on.
    public func geometryBase(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        var image = input
        if recipe.removeBackground, let cutout = try? Self.foregroundCutout(image) {
            image = cutout
            if let fill = recipe.backgroundFill {
                image = image.composited(over: CIImage(color: CIColor(red: fill.red, green: fill.green, blue: fill.blue))
                    .cropped(to: image.extent))
            }
        }
        image = rotated(image, quarterTurns: recipe.quarterTurns)
        if recipe.flipHorizontal || recipe.flipVertical {
            let e = image.extent
            let t = CGAffineTransform(translationX: recipe.flipHorizontal ? e.maxX + e.minX : 0,
                                      y: recipe.flipVertical ? e.maxY + e.minY : 0)
                .scaledBy(x: recipe.flipHorizontal ? -1 : 1, y: recipe.flipVertical ? -1 : 1)
            image = image.transformed(by: t)
        }
        if recipe.straighten != 0 {
            image = straightened(image, degrees: recipe.straighten)
        }
        return moveToOrigin(image)
    }

    /// Full pipeline: geometry, crop, color, filter, resize.
    public func apply(_ recipe: EditRecipe, to input: CIImage) -> CIImage {
        var image = geometryBase(input, recipe: recipe)
        if let crop = recipe.crop {
            let e = image.extent
            // Convert top-left normalized rect to Core Image's bottom-left pixel space.
            let rect = CGRect(x: e.minX + crop.minX * e.width,
                              y: e.minY + (1 - crop.maxY) * e.height,
                              width: crop.width * e.width,
                              height: crop.height * e.height).integral.intersection(e)
            if !rect.isEmpty { image = moveToOrigin(image.cropped(to: rect)) }
        }
        if recipe.hasColorAdjustments {
            image = colorAdjusted(image, recipe: recipe)
        }
        if let size = recipe.outputSize, size.width >= 1, size.height >= 1 {
            let e = image.extent
            let sx = size.width / e.width, sy = size.height / e.height
            let filter = CIFilter.lanczosScaleTransform()
            filter.inputImage = image
            filter.scale = Float(sy)
            filter.aspectRatio = Float(sx / sy)
            image = moveToOrigin(filter.outputImage ?? image)
            image = image.cropped(to: CGRect(origin: .zero, size: CGSize(width: size.width.rounded(), height: size.height.rounded())))
        }
        return image
    }

    private func colorAdjusted(_ input: CIImage, recipe: EditRecipe) -> CIImage {
        let extent = input.extent
        var image = input.clampedToExtent()

        if recipe.autoEnhance {
            for filter in input.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(image, forKey: kCIInputImageKey)
                image = filter.outputImage ?? image
            }
        }
        if recipe.exposure != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(recipe.exposure * 2)
            image = f.outputImage ?? image
        }
        if recipe.highlights != 0 || recipe.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = image
            f.highlightAmount = Float(1 + min(recipe.highlights, 0))   // CI only darkens highlights
            f.shadowAmount = Float(recipe.shadows)
            image = f.outputImage ?? image
            if recipe.highlights > 0 {
                // Brighten highlights with a gentle tone curve lift at the top end.
                let curve = CIFilter.toneCurve()
                curve.inputImage = image
                curve.point0 = CGPoint(x: 0, y: 0)
                curve.point1 = CGPoint(x: 0.25, y: 0.25)
                curve.point2 = CGPoint(x: 0.5, y: 0.5)
                curve.point3 = CGPoint(x: 0.75, y: 0.75 + 0.15 * recipe.highlights)
                curve.point4 = CGPoint(x: 1, y: 1)
                image = curve.outputImage ?? image
            }
        }
        if recipe.brightness != 0 || recipe.contrast != 0 || recipe.saturation != 0 {
            let f = CIFilter.colorControls()
            f.inputImage = image
            f.brightness = Float(recipe.brightness * 0.35)
            f.contrast = Float(1 + recipe.contrast * 0.5)
            f.saturation = Float(1 + recipe.saturation)
            image = f.outputImage ?? image
        }
        if recipe.vibrance != 0 {
            let f = CIFilter.vibrance()
            f.inputImage = image
            f.amount = Float(recipe.vibrance)
            image = f.outputImage ?? image
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = image
            f.neutral = CIVector(x: 6500, y: 0)
            // Positive temperature warms the image.
            f.targetNeutral = CIVector(x: 6500 - recipe.temperature * 3000, y: recipe.tint * 100)
            image = f.outputImage ?? image
        }
        if recipe.sharpness > 0 {
            let f = CIFilter.sharpenLuminance()
            f.inputImage = image
            f.sharpness = Float(recipe.sharpness * 1.5)
            f.radius = 1.7
            image = f.outputImage ?? image
        }
        image = recipe.filter.apply(to: image)
        if recipe.vignette > 0 {
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(max(extent.width, extent.height) * 0.6)
            f.intensity = Float(recipe.vignette)
            f.falloff = 0.5
            image = f.outputImage ?? image
        }
        return image.cropped(to: extent)
    }

    // MARK: Geometry helpers

    func rotated(_ image: CIImage, quarterTurns: Int) -> CIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        // CIImage orientations: .right rotates 90° clockwise.
        let orientation: CGImagePropertyOrientation = [.up, .right, .down, .left][turns]
        return image.oriented(orientation)
    }

    /// Rotates by `degrees` and zooms so no empty corners show, keeping the original frame size.
    func straightened(_ image: CIImage, degrees: Double) -> CIImage {
        let e = image.extent
        let theta = degrees * .pi / 180
        let c = abs(cos(theta)), s = abs(sin(theta))
        let scale = max((e.width * c + e.height * s) / e.width, (e.width * s + e.height * c) / e.height)
        let t = CGAffineTransform(translationX: e.midX, y: e.midY)
            .rotated(by: -theta)   // positive degrees rotate clockwise, like Photos
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -e.midX, y: -e.midY)
        return image.clampedToExtent().transformed(by: t).cropped(to: e)
    }

    func moveToOrigin(_ image: CIImage) -> CIImage {
        let e = image.extent
        guard e.origin != .zero, !e.isInfinite else { return image }
        return image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
    }

    // MARK: Rendering

    /// Renders to a CGImage in `colorSpace` (defaults to sRGB), 8 bits per channel.
    public func render(_ image: CIImage, colorSpace: CGColorSpace? = nil) throws -> CGImage {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let output = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: space) else {
            throw ConversionError.failed("Couldn't render the image.")
        }
        return output
    }

    /// Applies `recipe` to a decoded image and returns pixels in the source color space.
    public func render(_ recipe: EditRecipe, on loaded: LoadedImage) throws -> CGImage {
        let input = CIImage(cgImage: loaded.image)
        return try render(apply(recipe, to: input), colorSpace: ImageCodec.rgbSpace(of: loaded.image))
    }

    // MARK: Background removal

    /// Whether on-device subject lifting is available (macOS 14+).
    public static var canRemoveBackground: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Returns `image` with everything except the detected subject made transparent.
    public static func foregroundCutout(_ image: CIImage) throws -> CIImage {
        guard #available(macOS 14.0, *) else {
            throw ConversionError.failed("Background removal needs macOS 14 or later.")
        }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ConversionError.failed("No subject found to cut out.")
        }
        let mask = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        var maskImage = CIImage(cvPixelBuffer: mask)
        // The mask matches the input's pixel size; align it with the input extent.
        let e = image.extent
        maskImage = maskImage.transformed(by: CGAffineTransform(scaleX: e.width / maskImage.extent.width,
                                                                y: e.height / maskImage.extent.height)
            .translatedBy(x: e.minX, y: e.minY))
        let blend = CIFilter.blendWithMask()
        blend.inputImage = image
        blend.backgroundImage = CIImage.empty()
        blend.maskImage = maskImage
        guard let output = blend.outputImage?.cropped(to: e) else {
            throw ConversionError.failed("Couldn't remove the background.")
        }
        return output
    }
}

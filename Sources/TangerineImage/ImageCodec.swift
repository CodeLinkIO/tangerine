import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TangerineCore
import UniformTypeIdentifiers

/// A decoded image with its orientation already applied.
public struct LoadedImage: @unchecked Sendable {
    public var image: CGImage
    /// Source metadata (EXIF, GPS, TIFF, IPTC…) with orientation reset to "up".
    public var properties: [CFString: Any]
    /// Physical resolution, used to size PDF pages.
    public var dpi: CGFloat
    /// Number of frames (animated GIF/HEICS); only the first frame is decoded.
    public var frameCount: Int

    public var pixelSize: CGSize { CGSize(width: image.width, height: image.height) }
    public var hasAlpha: Bool { image.hasAlpha }
}

extension CGImage {
    var hasAlpha: Bool {
        switch alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }
}

public enum ImageCodec {
    // MARK: Reading

    /// Decodes the first frame of `url`, applying EXIF orientation. `maxPixelSize` downsamples on decode.
    public static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> LoadedImage {
        if FileFormat.detect(url) == .svg { return try loadVector(url, maxPixelSize: maxPixelSize) }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0
        else { throw ConversionError.unreadable(url) }

        var properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let longest = max(width, height)
        let needsResize = maxPixelSize.map { $0 < longest } ?? false

        let image: CGImage?
        if (orientation == 1 && !needsResize) || longest == 0 {
            // Full-fidelity decode keeps 16-bit/HDR sources intact.
            image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        } else {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: needsResize ? maxPixelSize! : longest,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        guard let image else { throw ConversionError.unreadable(url) }

        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).map { CGFloat($0) } ?? 72
        properties = normalized(properties)
        return LoadedImage(image: image, properties: properties, dpi: dpi > 0 ? dpi : 72,
                           frameCount: CGImageSourceGetCount(source))
    }

    /// SVG and other vector inputs rendered through AppKit at their natural size (or `maxPixelSize`).
    private static func loadVector(_ url: URL, maxPixelSize: Int?) throws -> LoadedImage {
        guard let nsImage = NSImage(contentsOf: url), nsImage.size.width > 0, nsImage.size.height > 0 else {
            throw ConversionError.unreadable(url)
        }
        var size = nsImage.size
        // Render small vector art at 2x so it stays crisp, or fit the requested size.
        let longest = max(size.width, size.height)
        let target = CGFloat(maxPixelSize ?? Int(max(longest * 2, 1024).rounded()))
        let scale = target / longest
        size = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.unreadable(url) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        nsImage.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ConversionError.unreadable(url) }
        return LoadedImage(image: image, properties: [:], dpi: 72 * scale, frameCount: 1)
    }

    /// Resets orientation and drops stale size fields so metadata can be re-attached after edits.
    static func normalized(_ properties: [CFString: Any]) -> [CFString: Any] {
        var result = properties
        result[kCGImagePropertyOrientation] = 1
        if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            result[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = result[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            result[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName] {
            result.removeValue(forKey: key)
        }
        return result
    }

    // MARK: Writing

    /// Formats ImageIO can encode on this Mac (queried at runtime, e.g. AVIF needs a recent macOS).
    public static let nativeWritableFormats: Set<FileFormat> = {
        let identifiers = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return Set(FileFormat.allCases.filter { format in
            guard let id = typeIdentifier(for: format) else { return false }
            return identifiers.contains(id)
        })
    }()

    /// Formats this engine can write, natively or through libwebp/ffmpeg.
    public static var writableFormats: Set<FileFormat> {
        var formats = nativeWritableFormats
        if WebPTools.canEncode { formats.insert(.webp) }
        return formats
    }

    static func typeIdentifier(for format: FileFormat) -> String? {
        switch format {
        case .jpg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        case .heic: UTType.heic.identifier
        case .avif: "public.avif"
        case .tiff: UTType.tiff.identifier
        case .bmp: UTType.bmp.identifier
        case .gif: UTType.gif.identifier
        case .ico: UTType.ico.identifier
        case .icns: UTType.icns.identifier
        case .jp2: "public.jpeg-2000"
        case .tga: "com.truevision.tga-image"
        case .exr: "com.ilm.openexr-image"
        case .psd: "com.adobe.photoshop-image"
        case .pdf: UTType.pdf.identifier
        case .webp: "org.webmproject.webp"
        default: nil
        }
    }

    /// Whether the format can store transparency.
    public static func supportsAlpha(_ format: FileFormat) -> Bool {
        switch format {
        case .jpg, .bmp, .jp2: false
        default: true
        }
    }

    public struct WriteOptions: @unchecked Sendable {
        public var quality: Double = 0.85
        public var background: SolidColor = .white
        /// Metadata to embed; nil writes none.
        public var properties: [CFString: Any]? = nil
        public var dpi: CGFloat = 72

        public init(quality: Double = 0.85, background: SolidColor = .white, properties: [CFString: Any]? = nil, dpi: CGFloat = 72) {
            self.quality = quality
            self.background = background
            self.properties = properties
            self.dpi = dpi
        }
    }

    /// Encodes `image` as `format` at `url`.
    public static func write(_ image: CGImage, as format: FileFormat, to url: URL, options: WriteOptions) async throws {
        switch format {
        case .webp:
            try await writeWebP(image, to: url, quality: options.quality)
        case .pdf:
            try writePDF([(image, options.dpi)], to: url)
        default:
            let data = try encode(image, as: format, options: options)
            try data.write(to: url, options: .atomic)
        }
    }

    /// Encodes `image` in memory (used for size estimates). WebP and PDF go through `write`.
    public static func encode(_ image: CGImage, as format: FileFormat, options: WriteOptions) throws -> Data {
        guard let identifier = typeIdentifier(for: format), nativeWritableFormats.contains(format) else {
            throw ConversionError.unsupported(from: nil, to: format.displayName)
        }
        let frames: [CGImage]
        switch format {
        case .ico: frames = iconFrames(image, sizes: [256, 48, 32, 16])
        case .icns: frames = iconFrames(image, sizes: [1024, 512, 256, 128, 64, 32, 16])
        default: frames = [supportsAlpha(format) ? image : flattened(image, background: options.background)]
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, identifier as CFString, frames.count, nil) else {
            throw ConversionError.failed("Couldn't create a \(format.displayName) encoder.")
        }
        var properties = options.properties ?? [:]
        properties[kCGImageDestinationLossyCompressionQuality] = options.quality
        if format == .gif || format == .bmp || format == .ico || format == .icns || format == .tga {
            // These containers can't carry EXIF/GPS; passing it can make ImageIO fail.
            properties = [kCGImageDestinationLossyCompressionQuality: options.quality]
        }
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.failed("Couldn't encode \(format.displayName).")
        }
        return data as Data
    }

    /// Writes one page per image, sized from each image's resolution.
    public static func writePDF(_ pages: [(CGImage, CGFloat)], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw ConversionError.failed("Couldn't create the PDF.") }
        for (image, dpi) in pages {
            let scale = 72 / max(dpi, 1)
            var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    private static func writeWebP(_ image: CGImage, to url: URL, quality: Double) async throws {
        let temp = try TemporaryDirectory()
        let png = temp.file("frame.png")
        try encode(image, as: .png, options: WriteOptions()).write(to: png)
        try await WebPTools.encode(png, to: url, quality: quality)
    }

    // MARK: Pixel helpers

    /// Draws `image` over a solid background, removing transparency.
    public static func flattened(_ image: CGImage, background: SolidColor) -> CGImage {
        guard image.hasAlpha else { return image }
        let space = rgbSpace(of: image)
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        context.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// Resamples `image` so its longest edge is `maxPixel` (never upscales unless `allowUpscale`).
    public static func resized(_ image: CGImage, longestEdge maxPixel: Int, allowUpscale: Bool = false) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > 0, allowUpscale || maxPixel < longest else { return image }
        let scale = CGFloat(maxPixel) / CGFloat(longest)
        return resized(image, to: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
    }

    public static func resized(_ image: CGImage, to size: CGSize) -> CGImage {
        let width = max(1, Int(size.width.rounded())), height = max(1, Int(size.height.rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: rgbSpace(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Square, padded frames for icon containers.
    static func iconFrames(_ image: CGImage, sizes: [Int]) -> [CGImage] {
        let square = padded(toSquare: image, background: nil)
        return sizes.map { resized(square, longestEdge: $0, allowUpscale: true) }
    }

    /// Centers `image` on a square canvas; nil background keeps it transparent.
    public static func padded(toSquare image: CGImage, background: SolidColor?) -> CGImage {
        let side = max(image.width, image.height)
        guard image.width != image.height,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: rgbSpace(of: image),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        if let background {
            context.setFillColor(CGColor(srgbRed: background.red, green: background.green, blue: background.blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        }
        context.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2,
                                       width: image.width, height: image.height))
        return context.makeImage() ?? image
    }

    /// The image's RGB color space, or sRGB for gray/indexed/CMYK sources.
    static func rgbSpace(of image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }
}

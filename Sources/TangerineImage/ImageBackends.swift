import CoreImage
import Foundation
import ImageIO
import TangerineCore

/// Entry point used by TangerineKit to register this engine's backends.
public enum ImageEngine {
    public static let conversionBackends: [any ConversionBackend] = [ImageConversionBackend()]
    public static let toolBackends: [any ToolBackend] = [ImageToolBackend()]

    /// Image formats this engine can decode.
    public static let readableFormats: Set<FileFormat> = [
        .jpg, .png, .heic, .webp, .avif, .tiff, .bmp, .gif, .svg, .ico, .icns, .psd, .tga, .jp2, .jxl, .exr, .raw,
    ]

    /// The format edits are saved in: the source format when it can be written, otherwise a sensible substitute.
    public static func editOutputFormat(for source: FileFormat) -> FileFormat {
        if ImageCodec.writableFormats.contains(source), source != .ico, source != .icns { return source }
        switch source {
        case .raw: return .jpg
        default: return .png
        }
    }
}

// MARK: - Conversion

struct ImageConversionBackend: ConversionBackend {
    let id = "image"

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard ImageEngine.readableFormats.contains(from), from != to else { return false }
        switch to {
        case .txt: return true   // OCR
        case .mp4: return from == .gif && (FFmpeg.shared.hasEncoder("h264_videotoolbox") || FFmpeg.shared.hasEncoder("libx264"))
        default: return ImageCodec.writableFormats.contains(to)
        }
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL] {
        let options = context.options
        let destination = output.file(extension: to.fileExtension)

        // Animated GIFs keep their animation when going to WebP or MP4.
        if from == .gif, to == .mp4 || (to == .webp && WebPTools.canEncodeAnimation) {
            try await convertAnimatedGIF(input, to: to, destination: destination, quality: options.imageQuality)
            return [destination]
        }

        let loaded = try ImageCodec.load(input, maxPixelSize: options.imageMaxPixelSize)
        context.progress(0.5)
        if to == .txt {
            let text = try TextRecognition.recognize(loaded.image)
            try text.write(to: destination, atomically: true, encoding: .utf8)
            return [destination]
        }
        try await ImageCodec.write(loaded.image, as: to, to: destination, options: .init(
            quality: options.imageQuality,
            background: options.flattenBackground,
            properties: options.stripImageMetadata ? nil : loaded.properties,
            dpi: loaded.dpi
        ))
        return [destination]
    }

    private func convertAnimatedGIF(_ input: URL, to: FileFormat, destination: URL, quality: Double) async throws {
        if to == .webp {
            try await WebPTools.encodeAnimatedGIF(input, to: destination, quality: quality)
            return
        }
        let encoder = FFmpeg.shared.hasEncoder("h264_videotoolbox") ? "h264_videotoolbox" : "libx264"
        // Even dimensions are required by H.264.
        var arguments = ["-i", input.path, "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", encoder,
                         "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        arguments += encoder == "h264_videotoolbox" ? ["-q:v", "65"] : ["-crf", "20"]
        try await FFmpeg.shared.run(arguments + [destination.path])
    }
}

// MARK: - Quick edits

struct ImageToolBackend: ToolBackend {
    let id = "image-tools"

    private static let tools: Set<ToolID> = [
        .compress, .resizeHalf, .resizeLong2048, .resizeLong1080, .rotateLeft, .rotateRight,
        .flipHorizontal, .flipVertical, .removeBackground, .autoEnhance, .grayscale, .stripMetadata,
        .trimTransparent, .makeSquare, .copyText, .makeIcon,
    ]

    func supports(_ tool: ToolID, format: FileFormat) -> Bool {
        guard ImageEngine.readableFormats.contains(format), Self.tools.contains(tool) else { return false }
        switch tool {
        case .removeBackground: return ImageRenderer.canRemoveBackground
        case .compress: return format != .gif && format != .svg && format != .ico && format != .icns
        default: return true
        }
    }

    func run(_ tool: ToolID, inputs: [URL], output: OutputPlan, context: ConversionContext) async throws -> ToolOutput {
        guard let input = inputs.first, let format = FileFormat.detect(input) else {
            throw ConversionError.unsupported(from: nil, to: tool.title)
        }
        let options = context.options

        switch tool {
        case .copyText:
            let text = try TextRecognition.recognize(ImageCodec.load(input).image)
            return ToolOutput(text: text, note: text.isEmpty ? "No text found" : nil)

        case .compress:
            return try await ImageCompressor.compress(input, format: format, output: output, options: options)

        case .makeIcon:
            let destination = output.file(extension: "icns")
            try await ImageCodec.write(ImageCodec.load(input).image, as: .icns, to: destination, options: .init())
            return ToolOutput(files: [destination])

        case .stripMetadata:
            return ToolOutput(files: [try await stripMetadata(input, format: format, output: output, options: options)])

        case .rotateLeft, .rotateRight, .flipHorizontal, .flipVertical:
            if let lossless = try losslessOrientationEdit(tool, input: input, format: format, output: output) {
                return ToolOutput(files: [lossless])
            }
        default:
            break
        }

        // Everything else is a recipe rendered through Core Image.
        let loaded = try ImageCodec.load(input)
        var recipe = EditRecipe()
        var outputFormat = ImageEngine.editOutputFormat(for: format)
        let suffix: String
        switch tool {
        case .rotateLeft: recipe.quarterTurns = 3; suffix = "rotated"
        case .rotateRight: recipe.quarterTurns = 1; suffix = "rotated"
        case .flipHorizontal: recipe.flipHorizontal = true; suffix = "flipped"
        case .flipVertical: recipe.flipVertical = true; suffix = "flipped"
        case .autoEnhance: recipe.autoEnhance = true; suffix = "enhanced"
        case .grayscale: recipe.filter = .mono; suffix = "mono"
        case .removeBackground:
            recipe.removeBackground = true
            outputFormat = .png
            suffix = "cutout"
        case .resizeHalf:
            recipe.outputSize = CGSize(width: max(1, loaded.image.width / 2), height: max(1, loaded.image.height / 2))
            suffix = "50%"
        case .resizeLong2048, .resizeLong1080:
            let limit = tool == .resizeLong2048 ? 2048 : 1080
            let longest = max(loaded.image.width, loaded.image.height)
            guard longest > limit else { return ToolOutput(note: "Already within \(limit) px") }
            let scale = Double(limit) / Double(longest)
            recipe.outputSize = CGSize(width: (Double(loaded.image.width) * scale).rounded(),
                                       height: (Double(loaded.image.height) * scale).rounded())
            suffix = "\(limit)px"
        case .trimTransparent:
            guard let bounds = OpaqueBounds.find(in: loaded.image) else {
                return ToolOutput(note: "No transparent edges")
            }
            let w = Double(loaded.image.width), h = Double(loaded.image.height)
            recipe.crop = CGRect(x: bounds.minX / w, y: bounds.minY / h, width: bounds.width / w, height: bounds.height / h)
            suffix = "trimmed"
        case .makeSquare:
            guard loaded.image.width != loaded.image.height else { return ToolOutput(note: "Already square") }
            let background: SolidColor? = ImageCodec.supportsAlpha(outputFormat) ? nil : options.flattenBackground
            let square = ImageCodec.padded(toSquare: loaded.image, background: background)
            let destination = output.file(extension: outputFormat.fileExtension, suffix: "square")
            try await ImageCodec.write(square, as: outputFormat, to: destination,
                                       options: writeOptions(options, loaded: loaded))
            return ToolOutput(files: [destination])
        default:
            throw ConversionError.unsupported(from: format, to: tool.title)
        }

        context.progress(0.3)
        let rendered = try ImageRenderer.shared.render(recipe, on: loaded)
        let destination = output.file(extension: outputFormat.fileExtension, suffix: suffix)
        try await ImageCodec.write(rendered, as: outputFormat, to: destination, options: writeOptions(options, loaded: loaded))
        return ToolOutput(files: [destination])
    }

    private func writeOptions(_ options: ConversionOptions, loaded: LoadedImage) -> ImageCodec.WriteOptions {
        // Edits re-encode, so use a high quality floor to avoid visible generation loss.
        .init(quality: max(options.imageQuality, 0.92), background: options.flattenBackground,
              properties: options.stripImageMetadata ? nil : loaded.properties, dpi: loaded.dpi)
    }

    // MARK: Lossless edits

    /// Rotates/flips JPEG, HEIC and TIFF by rewriting the orientation tag, without re-encoding pixels.
    private func losslessOrientationEdit(_ tool: ToolID, input: URL, format: FileFormat, output: OutputPlan) throws -> URL? {
        guard [.jpg, .heic, .tiff].contains(format),
              let source = CGImageSourceCreateWithURL(input as CFURL, nil),
              let type = CGImageSourceGetType(source)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let current = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
        let next = Orientation.apply(tool, to: current)
        let suffix = (tool == .rotateLeft || tool == .rotateRight) ? "rotated" : "flipped"
        let destinationURL = output.file(extension: format.fileExtension, suffix: suffix)
        guard let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationOrientation: next]
        guard CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil) else {
            try? FileManager.default.removeItem(at: destinationURL)
            return nil
        }
        return destinationURL
    }

    private func stripMetadata(_ input: URL, format: FileFormat, output: OutputPlan, options: ConversionOptions) async throws -> URL {
        // Lossless path: copy the compressed image data with empty metadata, keeping only orientation.
        if [.jpg, .png, .tiff, .heic].contains(format),
           let source = CGImageSourceCreateWithURL(input as CFURL, nil),
           let type = CGImageSourceGetType(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = properties?[kCGImagePropertyOrientation] as? UInt32 ?? 1
            let destinationURL = output.file(extension: format.fileExtension, suffix: "clean")
            if let destination = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil) {
                let copyOptions: [CFString: Any] = [
                    kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                    kCGImageDestinationMergeMetadata: false,
                    kCGImageMetadataShouldExcludeXMP: true,
                    kCGImageMetadataShouldExcludeGPS: true,
                    kCGImageDestinationOrientation: orientation,
                ]
                if CGImageDestinationCopyImageSource(destination, source, copyOptions as CFDictionary, nil) {
                    return destinationURL
                }
            }
            try? FileManager.default.removeItem(at: destinationURL)
        }
        let loaded = try ImageCodec.load(input)
        let outputFormat = ImageEngine.editOutputFormat(for: format)
        let destination = output.file(extension: outputFormat.fileExtension, suffix: "clean")
        try await ImageCodec.write(loaded.image, as: outputFormat, to: destination,
                                   options: .init(quality: 0.95, background: options.flattenBackground, properties: nil, dpi: loaded.dpi))
        return destination
    }
}

/// EXIF orientation arithmetic for lossless rotate/flip.
enum Orientation {
    private static let rotateClockwise: [UInt32: UInt32] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]
    private static let mirrorHorizontal: [UInt32: UInt32] = [1: 2, 2: 1, 3: 4, 4: 3, 6: 5, 5: 6, 8: 7, 7: 8]
    private static let mirrorVertical: [UInt32: UInt32] = [1: 4, 4: 1, 2: 3, 3: 2, 6: 7, 7: 6, 8: 5, 5: 8]

    static func apply(_ tool: ToolID, to orientation: UInt32) -> UInt32 {
        let o = (1...8).contains(orientation) ? orientation : 1
        switch tool {
        case .rotateRight: return rotateClockwise[o]!
        case .rotateLeft: return rotateClockwise[rotateClockwise[rotateClockwise[o]!]!]!
        case .flipHorizontal: return mirrorHorizontal[o]!
        case .flipVertical: return mirrorVertical[o]!
        default: return o
        }
    }
}

/// Finds the bounding box of non-transparent pixels (top-left origin), or nil when nothing to trim.
enum OpaqueBounds {
    static func find(in image: CGImage) -> CGRect? {
        guard image.hasAlpha, let pixels = try? PNGQuantizer.rgba(image) else { return nil }
        let width = image.width, height = image.height
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] > 8 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return rect.size == CGSize(width: width, height: height) ? nil : rect
    }
}

/// "Compress" keeps the format family and reports when the file can't get smaller.
enum ImageCompressor {
    static func compress(_ input: URL, format: FileFormat, output: OutputPlan, options: ConversionOptions) async throws -> ToolOutput {
        let loaded = try ImageCodec.load(input)
        let originalSize = input.fileSize
        let properties = options.stripImageMetadata ? nil : loaded.properties
        let destination: URL

        switch format {
        case .jpg, .heic, .avif, .jp2:
            destination = output.file(extension: format.fileExtension, suffix: "compressed")
            let quality = format == .jpg ? 0.7 : 0.6
            try await ImageCodec.write(loaded.image, as: format, to: destination,
                                       options: .init(quality: quality, properties: properties, dpi: loaded.dpi))
        case .webp where ImageCodec.writableFormats.contains(.webp):
            destination = output.file(extension: "webp", suffix: "compressed")
            try await ImageCodec.write(loaded.image, as: .webp, to: destination, options: .init(quality: 0.7))
        case .raw, .psd, .exr, .jxl, .webp:
            // Heavy or unwritable sources become a high-quality JPEG/PNG.
            let target: FileFormat = loaded.hasAlpha ? .png : .jpg
            destination = output.file(extension: target.fileExtension, suffix: "compressed")
            if target == .png {
                try PNGQuantizer.encode(loaded.image).write(to: destination)
            } else {
                try await ImageCodec.write(loaded.image, as: .jpg, to: destination,
                                           options: .init(quality: 0.8, properties: properties, dpi: loaded.dpi))
            }
        default:
            // PNG, TIFF, BMP, TGA: palette-quantized PNG. Dithering looks better but compresses worse,
            // so fall back to a flat palette when it doesn't pay off.
            destination = output.file(extension: "png", suffix: "compressed")
            var data = try PNGQuantizer.encode(loaded.image)
            if Int64(data.count) >= originalSize {
                data = try PNGQuantizer.encode(loaded.image, dithering: 0)
            }
            try data.write(to: destination)
        }

        if destination.fileSize >= originalSize {
            try? FileManager.default.removeItem(at: destination)
            return ToolOutput(note: "Already optimized")
        }
        return ToolOutput(files: [destination])
    }
}

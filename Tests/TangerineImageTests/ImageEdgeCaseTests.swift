import AVFoundation
import CoreImage
import ImageIO
import TangerineCore
@testable import TangerineImage
import XCTest

/// Edge cases real files hit: odd sizes and color models, EXIF orientation, broken inputs, metadata, compression.
final class ImageEdgeCaseTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let backend = ImageConversionBackend()
    private let tools = ImageToolBackend()

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    // XCTest keeps every test case alive until the run ends; release the folder so it gets deleted.
    override func tearDown() { temp = nil }

    // MARK: Fixtures

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Opaque gray image with a red block at the stored top-left and a blue block at the stored top-right.
    private func markerImage(width: Int = 200, height: Int = 100) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.sRGB,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let side = max(1, min(width, height) / 5)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - side, width: side, height: side))   // CG origin is bottom-left
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width - side, y: height - side, width: side, height: side))
        return context.makeImage()!
    }

    private func solid(width: Int, height: Int, red: Double, green: Double, blue: Double, alpha: Double = 1) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.sRGB,
                                bitmapInfo: (alpha < 1 ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Deterministic photo-like gradient with sensor-style grain (PNG stores it poorly, JPEG well).
    private func noise(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for i in 0..<(width * height) {
            let grain = Int(UInt32(truncatingIfNeeded: i &* 2_654_435_761) >> 28)   // 0...15
            bytes[i * 4] = UInt8(min(255, (i % width) * 200 / width + grain))
            bytes[i * 4 + 1] = UInt8(min(255, (i / width) * 200 / height + grain))
            bytes[i * 4 + 2] = UInt8(100 + grain)
        }
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: Self.sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return context.makeImage()!
    }

    /// Transparent canvas with an opaque green disc in the middle.
    private func logo(side: Int = 64) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: Self.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: side / 4, y: side / 4, width: side / 2, height: side / 2))
        return context.makeImage()!
    }

    @discardableResult
    private func write(_ image: CGImage, _ name: String, type: String, properties: [CFString: Any] = [:]) -> URL {
        let url = temp.file(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        return url
    }

    private func writeFrames(_ frames: [CGImage], _ name: String, type: String = "com.compuserve.gif", delay: Double = 0.1) -> URL {
        let url = temp.file(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil)!
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        return url
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    private func storedHasAlpha(_ url: URL) throws -> Bool {
        try properties(url)[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let p = try! PNGQuantizer.rgba(image)
        let o = (y * image.width + x) * 4
        return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]), Int(p[o + 3]))
    }

    private func convert(_ url: URL, to: FileFormat, options: ConversionOptions = ConversionOptions(),
                         into directory: URL? = nil) async throws -> URL {
        let from = try XCTUnwrap(FileFormat.detect(url))
        XCTAssertTrue(backend.supports(from: from, to: to), "\(from) → \(to) should be supported")
        let outputs = try await backend.convert(url, from: from, to: to, output: OutputPlan(for: url, directory: directory),
                                                context: ConversionContext(options: options))
        let output = try XCTUnwrap(outputs.first)
        XCTAssertGreaterThan(output.fileSize, 0)
        return output
    }

    private func run(_ tool: ToolID, _ url: URL, options: ConversionOptions = ConversionOptions()) async throws -> ToolOutput {
        let format = try XCTUnwrap(FileFormat.detect(url))
        XCTAssertTrue(tools.supports(tool, format: format), "\(tool) on \(format)")
        return try await tools.run(tool, inputs: [url], output: OutputPlan(for: url), context: ConversionContext(options: options))
    }

    private func runFile(_ tool: ToolID, _ url: URL, options: ConversionOptions = ConversionOptions()) async throws -> URL {
        let result = try await run(tool, url, options: options)
        return try XCTUnwrap(result.files.first, result.note ?? "no output")
    }

    // MARK: Orientation helpers

    enum Corner: String { case topLeft, topRight, bottomRight, bottomLeft }

    /// Where the red and blue markers are in the displayed image.
    private func markers(_ image: CGImage) -> (red: Corner?, blue: Corner?) {
        let inset = 3
        let points: [(Corner, Int, Int)] = [
            (.topLeft, inset, inset), (.topRight, image.width - 1 - inset, inset),
            (.bottomRight, image.width - 1 - inset, image.height - 1 - inset), (.bottomLeft, inset, image.height - 1 - inset),
        ]
        var red: Corner?, blue: Corner?
        for (corner, x, y) in points {
            let p = pixel(image, x: x, y: y)
            if p.r > 180, p.g < 80, p.b < 80 { red = corner }
            if p.b > 180, p.r < 80, p.g < 80 { blue = corner }
        }
        return (red, blue)
    }

    /// Displayed marker corners for each EXIF orientation of `markerImage()` (red stored top-left, blue top-right).
    private static let expectedMarkers: [UInt32: (Corner, Corner)] = [
        1: (.topLeft, .topRight), 2: (.topRight, .topLeft), 3: (.bottomRight, .bottomLeft), 4: (.bottomLeft, .bottomRight),
        5: (.topLeft, .bottomLeft), 6: (.topRight, .bottomRight), 7: (.bottomRight, .topRight), 8: (.bottomLeft, .topLeft),
    ]

    private static func moved(_ corner: Corner, by tool: ToolID) -> Corner {
        let clockwise: [Corner: Corner] = [.topLeft: .topRight, .topRight: .bottomRight, .bottomRight: .bottomLeft, .bottomLeft: .topLeft]
        switch tool {
        case .rotateRight: return clockwise[corner]!
        case .rotateLeft: return clockwise[clockwise[clockwise[corner]!]!]!
        case .flipHorizontal:
            return [.topLeft: .topRight, .topRight: .topLeft, .bottomRight: .bottomLeft, .bottomLeft: .bottomRight][corner]!
        case .flipVertical:
            return [.topLeft: .bottomLeft, .bottomLeft: .topLeft, .topRight: .bottomRight, .bottomRight: .topRight][corner]!
        default: return corner
        }
    }

    // MARK: Odd sizes

    func testOnePixelImageConvertsToEveryFormat() async throws {
        let png = write(solid(width: 1, height: 1, red: 1, green: 0.5, blue: 0), "dot.png", type: "public.png")
        for target in ImageCodec.writableFormats.sorted(by: { $0.rawValue < $1.rawValue }) where target != .png {
            let output = try await convert(png, to: target)
            guard target != .pdf else { continue }
            let decoded = try ImageCodec.load(output)
            if target == .ico || target == .icns {
                XCTAssertEqual(decoded.image.width, decoded.image.height, "\(target)")
            } else {
                XCTAssertEqual(decoded.pixelSize, CGSize(width: 1, height: 1), "\(target)")
            }
        }
        let half = try await runFile(.resizeHalf, png)
        XCTAssertEqual(try ImageCodec.load(half).pixelSize, CGSize(width: 1, height: 1), "never resizes to zero")
    }

    func testExtremeAspectRatios() async throws {
        let wide = write(solid(width: 20000, height: 10, red: 0.2, green: 0.4, blue: 0.6), "pano.png", type: "public.png")
        for target: FileFormat in [.jpg, .heic, .tiff, .gif] {
            let output = try await convert(wide, to: target)
            XCTAssertEqual(try ImageCodec.load(output).pixelSize, CGSize(width: 20000, height: 10), "\(target)")
        }
        let icon = try await convert(wide, to: .ico)
        XCTAssertEqual(try ImageCodec.load(icon).image.width, 256)

        // Fit 1080 on a 4×20000 strip must still shrink it, even though the width rounds below one pixel.
        let tall = write(solid(width: 4, height: 20000, red: 0.2, green: 0.4, blue: 0.6), "strip.png", type: "public.png")
        let fitted = try await runFile(.resizeLong1080, tall)
        XCTAssertEqual(fitted.lastPathComponent, "strip 1080px.png")
        XCTAssertEqual(try ImageCodec.load(fitted).pixelSize, CGSize(width: 1, height: 1080))
    }

    func testWebPRefusesImagesBeyondItsSizeLimit() async throws {
        try XCTSkipUnless(WebPTools.canEncode, "cwebp or ffmpeg with libwebp not installed")
        let wide = write(solid(width: 17000, height: 8, red: 0.2, green: 0.4, blue: 0.6), "wide.png", type: "public.png")
        do {
            _ = try await convert(wide, to: .webp)
            XCTFail("WebP is limited to 16383 px per side")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("16383"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.file("wide.webp").path), "no broken file left behind")
    }

    func testLargeImageDownsamplesOnDecode() async throws {
        let big = write(markerImage(width: 8000, height: 6000), "big.jpg", type: "public.jpeg")
        var options = ConversionOptions()
        options.imageMaxPixelSize = 1000
        let small = try ImageCodec.load(try await convert(big, to: .png, options: options)).image
        XCTAssertEqual(small.width, 1000)
        XCTAssertEqual(small.height, 750)

        // The limit applies to the displayed (rotated) image, and never upscales.
        let portrait = write(markerImage(width: 800, height: 600), "portrait.jpg", type: "public.jpeg",
                             properties: [kCGImagePropertyOrientation: 6])
        options.imageMaxPixelSize = 400
        let fitted = try ImageCodec.load(try await convert(portrait, to: .png, options: options)).image
        XCTAssertEqual(CGSize(width: fitted.width, height: fitted.height), CGSize(width: 300, height: 400))
        options.imageMaxPixelSize = 5000
        let untouched = try ImageCodec.load(try await convert(portrait, to: .tiff, options: options)).image
        XCTAssertEqual(CGSize(width: untouched.width, height: untouched.height), CGSize(width: 600, height: 800))
    }

    // MARK: Color models and bit depths

    func testGrayscaleCMYKAnd16BitInputs() async throws {
        let gray: CGImage = {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(CGColor(gray: 0.3, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            return context.makeImage()!
        }()
        let cmyk: CGImage = {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.genericCMYK)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.setFillColor(CGColor(genericCMYKCyan: 0, magenta: 1, yellow: 1, black: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            return context.makeImage()!
        }()
        let deep: CGImage = {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 16, bytesPerRow: 0, space: Self.sRGB,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
            context.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))   // right half stays transparent
            return context.makeImage()!
        }()
        let inputs = [
            write(gray, "gray.png", type: "public.png"),
            write(cmyk, "print.jpg", type: "public.jpeg"),
            write(deep, "deep.png", type: "public.png"),
        ]
        XCTAssertEqual(try properties(inputs[1])[kCGImagePropertyColorModel] as? String, "CMYK")
        XCTAssertEqual(try properties(inputs[2])[kCGImagePropertyDepth] as? Int, 16)

        for input in inputs {
            for target: FileFormat in [.jpg, .png, .heic, .tiff, .bmp, .gif, .tga, .ico] where FileFormat.detect(input) != target {
                let decoded = try ImageCodec.load(try await convert(input, to: target)).image
                XCTAssertGreaterThan(decoded.width, 0, "\(input.lastPathComponent) → \(target)")
            }
        }
        let red = pixel(try ImageCodec.load(try await convert(inputs[1], to: .png)).image, x: 30, y: 20)
        XCTAssertTrue(red.r > 180 && red.g < 90 && red.b < 90, "CMYK red stays red: \(red)")
        let flattened = try ImageCodec.load(try await convert(inputs[2], to: .bmp)).image
        XCTAssertGreaterThan(pixel(flattened, x: 60, y: 20).r, 240, "transparent half of a 16-bit PNG flattens to white")
        XCTAssertGreaterThan(pixel(flattened, x: 5, y: 20).b, 180)
    }

    func testIndexedPNGInput() async throws {
        let indexed = temp.file("palette.png")
        try PNGQuantizer.encode(logo()).write(to: indexed)
        let jpg = try ImageCodec.load(try await convert(indexed, to: .jpg)).image
        XCTAssertGreaterThan(pixel(jpg, x: 2, y: 2).g, 240, "transparent palette entries flatten to white")
        let rotated = try ImageCodec.load(try await runFile(.rotateRight, indexed)).image
        XCTAssertEqual(pixel(rotated, x: 2, y: 2).a, 0, "rotating keeps palette transparency")
        XCTAssertEqual(pixel(rotated, x: 32, y: 32).a, 255)
    }

    func testTransparencyFlattensOntoTheChosenBackground() async throws {
        let png = write(logo(), "logo.png", type: "public.png")
        let bmp = try ImageCodec.load(try await convert(png, to: .bmp)).image
        XCTAssertGreaterThan(pixel(bmp, x: 2, y: 2).r, 240)
        var options = ConversionOptions()
        options.flattenBackground = .black
        let jpg = try ImageCodec.load(try await convert(png, to: .jpg, options: options)).image
        XCTAssertLessThan(pixel(jpg, x: 2, y: 2).r, 15)
        XCTAssertGreaterThan(pixel(jpg, x: 32, y: 32).g, 120, "the subject itself is untouched")

        for target: FileFormat in [.heic, .avif, .tiff, .gif, .tga] where ImageCodec.writableFormats.contains(target) {
            let decoded = try ImageCodec.load(try await convert(png, to: target)).image
            XCTAssertEqual(pixel(decoded, x: 2, y: 2).a, 0, "\(target) keeps transparency")
            XCTAssertEqual(pixel(decoded, x: 32, y: 32).a, 255, "\(target)")
        }
    }

    func testFullyTransparentPNG() async throws {
        let png = write(solid(width: 40, height: 30, red: 0, green: 0, blue: 0, alpha: 0), "empty.png", type: "public.png")
        let jpg = try ImageCodec.load(try await convert(png, to: .jpg)).image
        XCTAssertGreaterThan(pixel(jpg, x: 20, y: 15).r, 240)
        let quantized = try ImageCodec.load(temp.file("q.png").writing(try PNGQuantizer.encode(ImageCodec.load(png).image))).image
        XCTAssertEqual(pixel(quantized, x: 20, y: 15).a, 0)
        let trim = try await run(.trimTransparent, png)
        XCTAssertTrue(trim.files.isEmpty, "nothing to keep, so nothing is written")
    }

    // MARK: EXIF orientation

    func testEveryEXIFOrientationDisplaysUpright() async throws {
        for orientation: UInt32 in 1...8 {
            let jpg = write(markerImage(), "o\(orientation).jpg", type: "public.jpeg", properties: [kCGImagePropertyOrientation: orientation])
            for target: FileFormat in [.png, .heic] {
                let output = try await convert(jpg, to: target)
                let decoded = try ImageCodec.load(output).image
                let swapped = orientation >= 5
                XCTAssertEqual(decoded.width, swapped ? 100 : 200, "orientation \(orientation) → \(target)")
                let (red, blue) = markers(decoded)
                XCTAssertEqual(red, Self.expectedMarkers[orientation]!.0, "red, orientation \(orientation) → \(target)")
                XCTAssertEqual(blue, Self.expectedMarkers[orientation]!.1, "blue, orientation \(orientation) → \(target)")
                // Pixels are already upright, so the tag must be reset (no double rotation in other apps).
                XCTAssertEqual(try properties(output)[kCGImagePropertyOrientation] as? UInt32 ?? 1, 1, "\(target)")
            }
        }
    }

    func testLosslessRotateAndFlipForEveryOrientation() async throws {
        let cases: [(String, String, [UInt32])] = [("jpg", "public.jpeg", Array(1...8)), ("heic", "public.heic", [1, 3, 6, 8]),
                                                   ("tiff", "public.tiff", [1, 2, 6])]
        for (ext, type, orientations) in cases {
            for orientation in orientations {
                let input = write(markerImage(), "src\(orientation).\(ext)", type: type, properties: [kCGImagePropertyOrientation: orientation])
                let (red, blue) = Self.expectedMarkers[orientation]!
                for tool: ToolID in [.rotateRight, .rotateLeft, .flipHorizontal, .flipVertical] {
                    let output = try await runFile(tool, input)
                    XCTAssertEqual(output.pathExtension, ext)
                    XCTAssertEqual(try properties(output)[kCGImagePropertyPixelWidth] as? Int, 200,
                                   "\(ext) \(orientation) \(tool): stored pixels are untouched")
                    let shown = markers(try ImageCodec.load(output).image)
                    XCTAssertEqual(shown.red, Self.moved(red, by: tool), "\(ext) orientation \(orientation) \(tool)")
                    XCTAssertEqual(shown.blue, Self.moved(blue, by: tool), "\(ext) orientation \(orientation) \(tool)")
                    try FileManager.default.removeItem(at: output)
                }
            }
        }
    }

    func testRenderedEditsMatchLosslessOnes() async throws {
        // PNG takes the Core Image path; the result must match what the EXIF path shows for JPEG.
        let png = write(markerImage(), "edit.png", type: "public.png")
        for tool: ToolID in [.rotateRight, .rotateLeft, .flipHorizontal, .flipVertical] {
            let image = try ImageCodec.load(try await runFile(tool, png)).image
            let shown = markers(image)
            XCTAssertEqual(shown.red, Self.moved(.topLeft, by: tool), "\(tool)")
            XCTAssertEqual(shown.blue, Self.moved(.topRight, by: tool), "\(tool)")
        }
    }

    // MARK: Opaque stays opaque

    func testOpaqueHEICDecodesWithoutAlpha() throws {
        // HEIC thumbnails (orientation or downsampling) come back as RGBA; photos must not look transparent.
        for orientation: UInt32 in [1, 6] {
            let heic = write(markerImage(), "photo\(orientation).heic", type: "public.heic", properties: [kCGImagePropertyOrientation: orientation])
            XCTAssertFalse(try ImageCodec.load(heic).hasAlpha, "orientation \(orientation)")
            XCTAssertFalse(try ImageCodec.load(heic, maxPixelSize: 50).hasAlpha, "preview, orientation \(orientation)")
        }
        let logo = write(logo(), "logo.heic", type: "public.heic")
        XCTAssertTrue(try ImageCodec.load(logo, maxPixelSize: 32).hasAlpha, "real transparency is kept")
    }

    func testEditsOfOpaqueImagesDoNotAddAnAlphaChannel() async throws {
        let png = write(markerImage(), "flat.png", type: "public.png")
        let heic = write(markerImage(), "phone.heic", type: "public.heic", properties: [kCGImagePropertyOrientation: 6])
        for (input, tool) in [(png, ToolID.rotateRight), (png, .resizeHalf), (heic, .resizeHalf), (heic, .grayscale)] {
            let output = try await runFile(tool, input)
            XCTAssertFalse(try storedHasAlpha(output), "\(input.lastPathComponent) \(tool)")
        }
        let logo = write(logo(), "logo.png", type: "public.png")
        let kept = try await runFile(.resizeHalf, logo)
        XCTAssertTrue(try storedHasAlpha(kept), "transparent sources keep alpha")
    }

    func testResizeKeepsEdgesSolid() async throws {
        // Lanczos sampling past the edge used to fade the border, showing up as a light frame in JPEGs.
        let jpg = write(solid(width: 400, height: 300, red: 0, green: 0, blue: 0), "night.jpg", type: "public.jpeg")
        let half = try ImageCodec.load(try await runFile(.resizeHalf, jpg)).image
        XCTAssertEqual(half.width, 200)
        for (x, y) in [(0, 0), (199, 0), (0, 149), (199, 149), (100, 0), (0, 75)] {
            let p = pixel(half, x: x, y: y)
            XCTAssertLessThan(p.r + p.g + p.b, 24, "edge pixel (\(x), \(y)) is \(p)")
            XCTAssertEqual(p.a, 255)
        }
    }

    // MARK: Multi-frame inputs

    func testMultiPageTIFF() async throws {
        let pages = [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].map { solid(width: 80, height: 60, red: $0.0, green: $0.1, blue: $0.2) }
        let tiff = writeFrames(pages, "scan.tiff", type: "public.tiff")
        let pdf = try await convert(tiff, to: .pdf)
        XCTAssertEqual(CGPDFDocument(pdf as CFURL)?.numberOfPages, 3, "every scanned page reaches the PDF")
        let png = try ImageCodec.load(try await convert(tiff, to: .png)).image
        XCTAssertGreaterThan(pixel(png, x: 10, y: 10).r, 240, "single-image formats get the first page")
    }

    func testAnimatedGIFToStillUsesFirstFrame() async throws {
        let frames = [(1.0, 0.0, 0.0), (0.0, 1.0, 0.0), (0.0, 0.0, 1.0)].map { solid(width: 60, height: 40, red: $0.0, green: $0.1, blue: $0.2) }
        let gif = writeFrames(frames, "anim.gif")
        XCTAssertEqual(try ImageCodec.load(gif).frameCount, 3)
        let first = try ImageCodec.load(try await convert(gif, to: .png)).image
        let p = pixel(first, x: 30, y: 20)
        XCTAssertTrue(p.r > 200 && p.g < 60, "first frame is red: \(p)")
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    func testSingleFrameAndTinyGIFsToMP4() async throws {
        try XCTSkipUnless(backend.supports(from: .gif, to: .mp4), "ffmpeg H.264 encoder not installed")
        let still = writeFrames([solid(width: 64, height: 48, red: 1, green: 0.5, blue: 0)], "still.gif")
        let clip = try await convert(still, to: .mp4)
        let stillLength = try await duration(of: clip)
        XCTAssertGreaterThanOrEqual(stillLength, 0.9, "a still GIF becomes a watchable clip, not a single 10 ms frame")

        let dot = writeFrames([solid(width: 1, height: 1, red: 1, green: 0, blue: 0)], "pixel.gif")
        let dotClip = try await convert(dot, to: .mp4)
        let dotLength = try await duration(of: dotClip)
        XCTAssertGreaterThan(dotLength, 0, "1 px GIFs still encode")

        let animation = writeFrames((0..<4).map { solid(width: 33, height: 21, red: Double($0) / 4, green: 0, blue: 0) }, "odd.gif")
        let animated = try await convert(animation, to: .mp4)
        let animatedLength = try await duration(of: animated)
        XCTAssertEqual(animatedLength, 0.4, accuracy: 0.15, "animations keep their own length")
        let tracks = try await AVURLAsset(url: animated).loadTracks(withMediaType: .video)
        let naturalSize = try await XCTUnwrap(tracks.first).load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 32, height: 20), "even dimensions for H.264")
    }

    // MARK: Vector and icon inputs/outputs

    func testSVGWithoutExplicitSize() async throws {
        let svgs = [
            "viewbox": (#"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 150"><rect width="300" height="150" fill="red"/></svg>"#, 2.0),
            "percent": (#"<svg xmlns="http://www.w3.org/2000/svg" width="100%" height="100%" viewBox="0 0 40 20"><rect width="40" height="20" fill="red"/></svg>"#, 2.0),
            "bare": (#"<svg xmlns="http://www.w3.org/2000/svg"><circle cx="25" cy="25" r="20" fill="red"/></svg>"#, 0),
        ]
        for (name, (markup, ratio)) in svgs {
            let url = temp.file("\(name).svg")
            try markup.write(to: url, atomically: true, encoding: .utf8)
            let png = try ImageCodec.load(try await convert(url, to: .png)).image
            XCTAssertGreaterThanOrEqual(max(png.width, png.height), 1024, "\(name) renders crisp")
            if ratio > 0 { XCTAssertEqual(Double(png.width) / Double(png.height), ratio, accuracy: 0.01, name) }
        }
    }

    func testIconsFromNonSquareAndTinyImages() async throws {
        let jpg = write(markerImage(width: 300, height: 100), "banner.jpg", type: "public.jpeg")
        let ico = try await convert(jpg, to: .ico)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(ico as CFURL, nil))
        let sizes = (0..<CGImageSourceGetCount(source)).compactMap {
            (CGImageSourceCopyPropertiesAtIndex(source, $0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int
        }
        XCTAssertEqual(Set(sizes), [256, 48, 32, 16], "ICO tops out at 256 px")
        let largest = try ImageCodec.load(ico).image
        XCTAssertEqual(pixel(largest, x: 128, y: 5).a, 0, "letterboxed, not stretched")
        XCTAssertEqual(pixel(largest, x: 128, y: 128).a, 255)

        let tiny = write(solid(width: 3, height: 2, red: 0, green: 0, blue: 1), "tiny.png", type: "public.png")
        let icns = try ImageCodec.load(try await convert(tiny, to: .icns)).image
        XCTAssertEqual(icns.width, icns.height)
        XCTAssertGreaterThanOrEqual(icns.width, 512)
    }

    // MARK: Broken and mislabeled files

    func testBrokenFilesFailCleanly() async throws {
        let empty = temp.file("empty.jpg")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let text = temp.file("notes.jpg")
        try "just some text".write(to: text, atomically: true, encoding: .utf8)
        let header = temp.file("header.png")
        try Data(try Data(contentsOf: write(markerImage(), "whole.png", type: "public.png")).prefix(40)).write(to: header)
        let before = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count

        for url in [empty, text, header] {
            do {
                _ = try await convert(url, to: url.pathExtension == "png" ? .jpg : .png)
                XCTFail("\(url.lastPathComponent) should not convert")
            } catch let error as ConversionError {
                guard case .unreadable = error else { return XCTFail("\(url.lastPathComponent): \(error)") }
                XCTAssertTrue(error.localizedDescription.contains(url.lastPathComponent))
            }
            do {
                _ = try await run(.compress, url)
                XCTFail("\(url.lastPathComponent) should not compress")
            } catch {}
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count, before, "no stray outputs")
    }

    /// A complete, all-black 1-bit PNG of `width`×`height`: a few KB on disk, hundreds of MB once decoded.
    private func pngBomb(width: Int, height: Int, name: String, rows: Int? = nil) throws -> URL {
        func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typeAndBody = Array(type.utf8) + body
            return be32(body.count) + typeAndBody + be32(Int(CRC32.checksum(typeAndBody)))
        }
        let raw = Data(count: (1 + (width + 7) / 8) * (rows ?? height))   // filter byte + packed bits per row, all zero
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        let adler = (raw.count % 65521) << 16 | 1   // Adler-32 of zeros
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", be32(width) + be32(height) + [1, 0, 0, 0, 0])
        png += chunk("IDAT", [0x78, 0x9C] + [UInt8](deflated) + be32(adler))
        png += chunk("IEND", [])
        let url = temp.file(name)
        try Data(png).write(to: url)
        return url
    }

    func testDecompressionBombsAreRefusedBeforeDecoding() async throws {
        let bomb = try pngBomb(width: 20000, height: 20000, name: "bomb.png")
        XCTAssertLessThan(bomb.fileSize, 200_000)
        let started = Date()
        for attempt in [{ _ = try ImageCodec.load(bomb) }, { _ = try ImageCodec.load(bomb, maxPixelSize: 2000) }] {
            XCTAssertThrowsError(try attempt()) { error in
                XCTAssertTrue(error.localizedDescription.contains("too large"), error.localizedDescription)
                XCTAssertTrue(error.localizedDescription.contains("bomb.png"), error.localizedDescription)
            }
        }
        for tool: ToolID in [.compress, .resizeHalf, .rotateRight] {
            do {
                _ = try await run(tool, bomb)
                XCTFail("\(tool) must refuse a 400 MP image")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("too large"), "\(tool): \(error.localizedDescription)")
            }
        }
        do {
            _ = try await convert(bomb, to: .jpg)
            XCTFail("conversion must refuse a 400 MP image")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "refused from the header, nothing decoded")

        let absurd = try pngBomb(width: 100_000, height: 100_000, name: "absurd.png", rows: 8)
        XCTAssertThrowsError(try ImageCodec.load(absurd))

        // Big but legitimate photos still open (16000×12000 = 192 MP is under the budget).
        XCTAssertNoThrow(try ImageCodec.checkPixelBudget(width: 16000, height: 12000, name: "pano.jpg"))
        XCTAssertThrowsError(try ImageCodec.checkPixelBudget(width: 16000, height: 13000, name: "pano.jpg"))
    }

    func testSVGDeclaringAHugeCanvasRendersWithinBudget() throws {
        // A 119-byte SVG used to render at 2× its declared size: 20000×20000 meant a 40000² (6.4 GB) bitmap.
        let cases = [("poster", 3000, 3000), ("giant", 20000, 20000)]
        for (name, side, expected) in cases.map({ ($0.0, $0.1, min($0.2, 8192)) }) {
            let url = temp.file("\(name).svg")
            try #"<svg xmlns="http://www.w3.org/2000/svg" width="\#(side)" height="\#(side)"><rect width="\#(side)" height="\#(side)" fill="red"/></svg>"#
                .write(to: url, atomically: true, encoding: .utf8)
            let image = try ImageCodec.load(url).image
            XCTAssertEqual(image.width, expected, "\(name): large art renders at its natural size, capped")
            XCTAssertLessThanOrEqual(image.width * image.height, ImageCodec.maxPixelCount, name)
            let center = try XCTUnwrap(image.cropping(to: CGRect(x: image.width / 2, y: image.height / 2, width: 1, height: 1)))
            XCTAssertGreaterThan(pixel(center, x: 0, y: 0).r, 200, name)
        }
    }

    func testTruncatedJPEGStillDecodes() async throws {
        // Like Preview, a half-downloaded photo opens with its missing part blank rather than failing.
        let data = try Data(contentsOf: write(markerImage(width: 400, height: 300), "full.jpg", type: "public.jpeg"))
        let truncated = temp.file("partial.jpg")
        try Data(data.prefix(data.count / 2)).write(to: truncated)
        let rescued = try await convert(truncated, to: .png)
        XCTAssertEqual(try ImageCodec.load(rescued).pixelSize, CGSize(width: 400, height: 300))
    }

    func testWrongExtensionIsDecodedByContent() async throws {
        let png = write(noise(width: 300, height: 200), "real.png", type: "public.png")
        let mislabeled = temp.file("actually-png.jpg")
        try FileManager.default.copyItem(at: png, to: mislabeled)
        let heic = try ImageCodec.load(try await convert(mislabeled, to: .heic)).image
        XCTAssertEqual(heic.width, 300)
        let compressed = try await runFile(.compress, mislabeled)
        XCTAssertEqual(CGImageSourceGetType(try XCTUnwrap(CGImageSourceCreateWithURL(compressed as CFURL, nil))) as String?, "public.jpeg",
                       "a .jpg output really is a JPEG")
    }

    // MARK: File names and folders

    func testAwkwardFileNames() async throws {
        let names = ["my holiday photo.jpg", "ünïcødé 日本 🍊.jpg", "quote \"it's\".jpg", "-starts-with-dash.jpg", "100% done.jpg"]
        for name in names {
            let jpg = write(markerImage(), name, type: "public.jpeg")
            let base = FileFormat.baseName(of: jpg)
            let png = try await convert(jpg, to: .png)
            XCTAssertEqual(png.lastPathComponent, "\(base).png")
            let rotated = try await runFile(.rotateRight, jpg)
            XCTAssertEqual(rotated.lastPathComponent, "\(base) rotated.jpg")
            if WebPTools.canEncode {
                let webp = try await convert(jpg, to: .webp)
                XCTAssertEqual(webp.lastPathComponent, "\(base).webp", "cwebp gets the path verbatim")
            }
        }
        if backend.supports(from: .gif, to: .mp4) {
            let gif = writeFrames([markerImage(width: 40, height: 20), solid(width: 40, height: 20, red: 0, green: 0, blue: 1)],
                                  "-loop \"quoted\" 50% ü.gif")
            let mp4 = try await convert(gif, to: .mp4)
            XCTAssertEqual(mp4.lastPathComponent, "-loop \"quoted\" 50% ü.mp4")
        }
    }

    func testOutputNamesNeverCollide() async throws {
        let jpg = write(markerImage(), "pic.jpg", type: "public.jpeg")
        write(markerImage(), "pic rotated.jpg", type: "public.jpeg")
        let second = try await runFile(.rotateRight, jpg), third = try await runFile(.rotateRight, jpg)
        XCTAssertEqual(second.lastPathComponent, "pic rotated 2.jpg")
        XCTAssertEqual(third.lastPathComponent, "pic rotated 3.jpg")
        let numbered = write(markerImage(), "pic 2.jpg", type: "public.jpeg")
        let first = try await convert(numbered, to: .png), again = try await convert(numbered, to: .png)
        XCTAssertEqual(first.lastPathComponent, "pic 2.png")
        XCTAssertEqual(again.lastPathComponent, "pic 2 2.png")
    }

    func testReadOnlyOutputFolderThrows() async throws {
        let folder = temp.url.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let jpg = write(markerImage(), "locked/photo.jpg", type: "public.jpeg")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        do {
            _ = try await convert(jpg, to: .png)
            XCTFail("writing into a read-only folder must fail")
        } catch {}
        let elsewhere = temp.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let moved = try await convert(jpg, to: .png, into: elsewhere)
        XCTAssertEqual(moved.deletingLastPathComponent().lastPathComponent, "out")
    }

    // MARK: Metadata

    private var cameraMetadata: [CFString: Any] {
        [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon", kCGImagePropertyTIFFModel: "EOS R5"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:06 07:08:09",
                                             kCGImagePropertyExifUserComment: "home"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"],
        ]
    }

    private func assertNoPrivateMetadata(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let p = try properties(url)
        XCTAssertNil(p[kCGImagePropertyGPSDictionary], "GPS", file: file, line: line)
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "capture date", file: file, line: line)
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "comment", file: file, line: line)
        XCTAssertNil((p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake], "camera", file: file, line: line)
    }

    func testStripMetadataIsLosslessForJPEG() async throws {
        for (ext, type) in [("jpg", "public.jpeg"), ("heic", "public.heic")] {
            var metadata = cameraMetadata
            metadata[kCGImagePropertyOrientation] = 6
            let input = write(markerImage(), "camera.\(ext)", type: type, properties: metadata)
            XCTAssertNotNil(try properties(input)[kCGImagePropertyGPSDictionary])
            let output = try await runFile(.stripMetadata, input)
            XCTAssertEqual(output.lastPathComponent, "camera clean.\(ext)")
            try assertNoPrivateMetadata(output)
            XCTAssertEqual(markers(try ImageCodec.load(output).image).red, .topRight, "\(ext) still displays upright")
            guard ext == "jpg" else { continue }   // HEIC copies keep the capture date, so HEIC re-encodes
            let p = try properties(output)
            XCTAssertEqual(p[kCGImagePropertyPixelWidth] as? Int, 200, "compressed data copied, not re-encoded")
            XCTAssertEqual(p[kCGImagePropertyOrientation] as? Int, 6, "orientation is the one tag kept")
            XCTAssertEqual(try Data(contentsOf: output).count, try Data(contentsOf: input).count, accuracy: 600, "same scan data, less metadata")
        }
    }

    func testStripMetadataForOtherFormats() async throws {
        for (ext, type) in [("png", "public.png"), ("tiff", "public.tiff")] {
            var metadata = cameraMetadata
            metadata[kCGImagePropertyOrientation] = 8
            let input = write(markerImage(), "scan.\(ext)", type: type, properties: metadata)
            let output = try await runFile(.stripMetadata, input)
            try assertNoPrivateMetadata(output)
            let image = try ImageCodec.load(output).image
            XCTAssertEqual(image.width, 100, "\(ext)")
            XCTAssertEqual(markers(image).red, .bottomLeft, "\(ext) orientation baked in once")
        }
    }

    func testConversionKeepsMetadataUnlessStripped() async throws {
        var metadata = cameraMetadata
        metadata[kCGImagePropertyOrientation] = 6
        let jpg = write(markerImage(), "trip.jpg", type: "public.jpeg", properties: metadata)
        let kept = try await convert(jpg, to: .heic)
        XCTAssertNotNil(try properties(kept)[kCGImagePropertyGPSDictionary], "metadata is kept by default")
        XCTAssertEqual((try properties(kept)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "Canon")
        var options = ConversionOptions()
        options.stripImageMetadata = true
        for target: FileFormat in [.heic, .tiff, .png] {
            let output = try await convert(jpg, to: target, options: options)
            try assertNoPrivateMetadata(output)
            XCTAssertEqual(markers(try ImageCodec.load(output).image).red, .topRight, "\(target)")
        }
        let compressed = try await runFile(.compress, jpg, options: options)
        try assertNoPrivateMetadata(compressed)
    }

    // MARK: Compression

    /// Chunk types and bodies of a PNG, checking every CRC.
    private func pngChunks(_ data: Data, file: StaticString = #filePath, line: UInt = #line) -> [(String, [UInt8])] {
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], file: file, line: line)
        var chunks: [(String, [UInt8])] = []
        var i = 8
        while i + 12 <= bytes.count {
            let length = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let typeAndBody = Array(bytes[(i + 4)..<(i + 8 + length)])
            let crc = UInt32(bytes[i + 8 + length]) << 24 | UInt32(bytes[i + 9 + length]) << 16
                | UInt32(bytes[i + 10 + length]) << 8 | UInt32(bytes[i + 11 + length])
            let type = String(decoding: typeAndBody.prefix(4), as: UTF8.self)
            XCTAssertEqual(CRC32.checksum(typeAndBody), crc, "\(type) CRC", file: file, line: line)
            chunks.append((type, Array(typeAndBody.dropFirst(4))))
            i += 12 + length
        }
        return chunks
    }

    func testQuantizedPNGStructure() throws {
        // 512×64 gradient with thousands of colors and an alpha ramp.
        let width = 512, height = 64
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: Self.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<width {
            for y in stride(from: 0, to: height, by: 8) {
                context.setFillColor(CGColor(srgbRed: Double(x) / 511, green: Double(y) / 63, blue: 0.5, alpha: Double(x % 256) / 255))
                context.fill(CGRect(x: x, y: y, width: 1, height: 8))
            }
        }
        let source = context.makeImage()!
        let data = try PNGQuantizer.encode(source)
        let chunks = pngChunks(data)
        XCTAssertEqual(chunks.map(\.0).first, "IHDR")
        XCTAssertEqual(chunks.map(\.0).last, "IEND")
        let header = try XCTUnwrap(chunks.first { $0.0 == "IHDR" }?.1)
        XCTAssertEqual(header[8], 8, "bit depth")
        XCTAssertEqual(header[9], 3, "palette color type")
        let palette = try XCTUnwrap(chunks.first { $0.0 == "PLTE" }?.1)
        XCTAssertEqual(palette.count % 3, 0)
        XCTAssertLessThanOrEqual(palette.count / 3, 256)
        XCTAssertGreaterThan(palette.count / 3, 200, "a rich image uses most of the palette")
        let transparency = try XCTUnwrap(chunks.first { $0.0 == "tRNS" }?.1)
        XCTAssertLessThanOrEqual(transparency.count, palette.count / 3)

        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        let alphas = try PNGQuantizer.rgba(decoded)
        for x in [8, 64, 128, 200, 248, 300] {
            // Dithering trades exactness per pixel for the right average, so compare an 8×8 block.
            var sum = 0
            for dy in 0..<8 { for dx in 0..<8 { sum += Int(alphas[((16 + dy) * width + x - 4 + dx) * 4 + 3]) } }
            XCTAssertEqual(sum / 64, x % 256, accuracy: 10, "alpha ramp at x=\(x)")
        }
        XCTAssertEqual(pixel(decoded, x: 256, y: 20).a, 0, "fully transparent stays fully transparent")
        XCTAssertEqual(pixel(decoded, x: 255, y: 20).a, 255, "fully opaque stays fully opaque")
        let original = pixel(source, x: 400, y: 40), mapped = pixel(decoded, x: 400, y: 40)
        XCTAssertLessThan(abs(original.r - mapped.r) + abs(original.g - mapped.g) + abs(original.b - mapped.b), 60)
    }

    func testCompressFlatAndAlreadyOptimizedPNGs() async throws {
        // A one-color PNG shrinks and stays exact.
        let flat = write(solid(width: 300, height: 300, red: 0.9, green: 0.4, blue: 0.1), "flat.png", type: "public.png")
        let small = try await runFile(.compress, flat)
        XCTAssertLessThan(small.fileSize, flat.fileSize)
        let p = pixel(try ImageCodec.load(small).image, x: 150, y: 150), q = pixel(solid(width: 1, height: 1, red: 0.9, green: 0.4, blue: 0.1), x: 0, y: 0)
        XCTAssertEqual(p.r, q.r, accuracy: 1)
        XCTAssertEqual(p.g, q.g, accuracy: 1)
        XCTAssertEqual(p.b, q.b, accuracy: 1)

        // Compressing our own output again can't win, so nothing new is written.
        let before = try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count
        let again = try await run(.compress, small)
        XCTAssertTrue(again.files.isEmpty)
        XCTAssertEqual(again.note, "Already optimized")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.url.path).count, before)
    }

    func testCompressNeverGrowsLossyFiles() async throws {
        for (ext, format) in [("jpg", FileFormat.jpg), ("heic", .heic)] {
            let url = temp.file("tiny.\(ext)")
            try ImageCodec.encode(markerImage(width: 600, height: 400), as: format, options: .init(quality: 0.2)).write(to: url)
            let result = try await run(.compress, url)
            if let output = result.files.first {
                XCTAssertLessThan(output.fileSize, url.fileSize, "\(ext) output must be smaller")
            } else {
                XCTAssertEqual(result.note, "Already optimized", ext)
                XCTAssertFalse(FileManager.default.fileExists(atPath: temp.file("tiny compressed.\(ext)").path))
            }
        }
    }

    func testCompressKeepsOrientationAndMetadata() async throws {
        var metadata = cameraMetadata
        metadata[kCGImagePropertyOrientation] = 6
        let jpg = temp.file("big.jpg")
        let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        metadata[kCGImageDestinationLossyCompressionQuality] = 1.0
        CGImageDestinationAddImage(destination, markerImage(width: 800, height: 400), metadata as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let output = try await runFile(.compress, jpg)
        XCTAssertLessThan(output.fileSize, jpg.fileSize)
        let image = try ImageCodec.load(output).image
        XCTAssertEqual(CGSize(width: image.width, height: image.height), CGSize(width: 400, height: 800))
        XCTAssertEqual(markers(image).red, .topRight, "rotated exactly once")
        XCTAssertNotNil(try properties(output)[kCGImagePropertyGPSDictionary], "compress keeps metadata unless stripping")
    }

    func testCompressKeepsTIFFAndTGAFormats() async throws {
        // An uncompressed two-page scan becomes an LZW TIFF with the same pixels, every page and the metadata.
        let tiff = temp.file("scan.tif")
        let destination = CGImageDestinationCreateWithURL(tiff as CFURL, "public.tiff" as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, markerImage(width: 600, height: 400), cameraMetadata as CFDictionary)
        CGImageDestinationAddImage(destination, solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let small = try await runFile(.compress, tiff)
        XCTAssertEqual(small.lastPathComponent, "scan compressed.tiff")
        XCTAssertLessThan(small.fileSize, tiff.fileSize / 4)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(small as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.tiff")
        XCTAssertEqual(CGImageSourceGetCount(source), 2, "every page kept")
        let info = try properties(small)
        XCTAssertEqual((info[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFCompression] as? Int, 5)
        XCTAssertNotNil(info[kCGImagePropertyGPSDictionary], "metadata kept unless stripping")
        let before = try ImageCodec.load(tiff).image, after = try ImageCodec.load(small).image
        for (x, y) in [(3, 3), (596, 3), (300, 200), (10, 390)] {
            XCTAssertTrue(pixel(before, x: x, y: y) == pixel(after, x: x, y: y), "lossless at \(x),\(y)")
        }
        XCTAssertEqual(try ImageCodec.load(small, frame: 1).pixelSize, CGSize(width: 300, height: 200))
        let again = try await run(.compress, small)
        XCTAssertEqual(again.note, "Already optimized")

        var stripping = ConversionOptions()
        stripping.stripImageMetadata = true
        let clean = try await runFile(.compress, tiff, options: stripping)
        XCTAssertNil(try properties(clean)[kCGImagePropertyGPSDictionary])

        // An uncompressed TGA (game textures, renders) stays a TGA, run-length encoded.
        let width = 64, height = 32
        var tga = Data([0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(width), 0, UInt8(height), 0, 24, 0x20])
        for y in 0..<height {
            for _ in 0..<width { tga.append(contentsOf: y < height / 2 ? [0, 0, 255] : [255, 0, 0]) }   // BGR
        }
        let texture = try temp.file("texture.tga").writing(tga)
        let rle = try await runFile(.compress, texture)
        XCTAssertEqual(rle.pathExtension, "tga")
        XCTAssertLessThan(rle.fileSize, texture.fileSize / 4)
        let decoded = try ImageCodec.load(rle).image
        XCTAssertTrue(pixel(decoded, x: 5, y: 5) == (255, 0, 0, 255), "\(pixel(decoded, x: 5, y: 5))")
        XCTAssertTrue(pixel(decoded, x: 5, y: 25) == (0, 0, 255, 255), "\(pixel(decoded, x: 5, y: 25))")

        // BMP has no compression to apply, so Compress isn't offered; converting to PNG is the way.
        XCTAssertFalse(tools.supports(.compress, format: .bmp))
    }

    func testImageWithoutTextFailsClearlyForTXT() async throws {
        let blank = write(solid(width: 300, height: 120, red: 1, green: 1, blue: 1), "blank.png", type: "public.png")
        do {
            _ = try await backend.convert(blank, from: .png, to: .txt, output: OutputPlan(for: blank), context: ConversionContext())
            XCTFail("expected “No text found”")
        } catch {
            XCTAssertEqual(error.localizedDescription, "No text found in “blank.png”.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.file("blank.txt").path))
    }
}

private extension URL {
    /// Writes `data` here and returns the URL.
    func writing(_ data: Data) throws -> URL {
        try data.write(to: self)
        return self
    }
}

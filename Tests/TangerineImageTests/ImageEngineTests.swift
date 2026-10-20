import AppKit
import CoreImage
import ImageIO
import TangerineCore
@testable import TangerineImage
import XCTest

final class ImageEngineTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let backend = ImageConversionBackend()
    private let tools = ImageToolBackend()

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    // XCTest keeps every test case alive until the run ends; release the folder so it gets deleted.
    override func tearDown() { temp = nil }

    // MARK: Fixtures

    /// 200×100 image: red square top-left, blue bottom-right, gradient elsewhere.
    private func makeImage(width: Int = 200, height: Int = 100, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if alpha {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1))
            context.fillEllipse(in: CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        } else {
            for x in 0..<width {
                context.setFillColor(CGColor(srgbRed: Double(x) / Double(width), green: 0.5, blue: 0.3, alpha: 1))
                context.fill(CGRect(x: x, y: 0, width: 1, height: height))
            }
            context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - 20, width: 20, height: 20))   // top-left (CG origin is bottom-left)
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: width - 20, y: 0, width: 20, height: 20))    // bottom-right
        }
        return context.makeImage()!
    }

    @discardableResult
    private func write(_ image: CGImage, _ name: String, type: String, properties: [CFString: Any] = [:]) -> URL {
        let url = temp.file(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let p = try! PNGQuantizer.rgba(image)
        let o = (y * image.width + x) * 4
        return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]), Int(p[o + 3]))
    }

    private func convert(_ url: URL, to: FileFormat, options: ConversionOptions = ConversionOptions()) async throws -> URL {
        let from = try XCTUnwrap(FileFormat.detect(url))
        XCTAssertTrue(backend.supports(from: from, to: to), "\(from) → \(to) should be supported")
        let outputs = try await backend.convert(url, from: from, to: to, output: OutputPlan(for: url),
                                                context: ConversionContext(options: options))
        let output = try XCTUnwrap(outputs.first)
        XCTAssertGreaterThan(output.fileSize, 0)
        return output
    }

    // MARK: Conversion

    func testConvertsJPGToEveryNativeFormat() async throws {
        let jpg = write(makeImage(), "photo.jpg", type: "public.jpeg")
        let targets: [FileFormat] = [.png, .heic, .tiff, .bmp, .gif, .ico, .icns, .jp2, .tga, .avif]
        for target in targets where ImageCodec.nativeWritableFormats.contains(target) {
            let output = try await convert(jpg, to: target)
            XCTAssertEqual(output.pathExtension, target.fileExtension)
            let decoded = try ImageCodec.load(output)
            if target == .ico || target == .icns {
                XCTAssertEqual(decoded.image.width, decoded.image.height, "icons are square")
            } else {
                XCTAssertEqual(decoded.image.width, 200, "\(target)")
                XCTAssertEqual(decoded.image.height, 100, "\(target)")
            }
        }
    }

    func testAppliesEXIFOrientation() async throws {
        // Stored 200×100 with orientation 6 (rotate 90° CW to display) → displays 100×200.
        let jpg = write(makeImage(), "rotated.jpg", type: "public.jpeg", properties: [kCGImagePropertyOrientation: 6])
        let png = try await convert(jpg, to: .png)
        let decoded = try ImageCodec.load(png)
        XCTAssertEqual(decoded.image.width, 100)
        XCTAssertEqual(decoded.image.height, 200)
        // The red top-left marker ends up top-right after a clockwise rotation.
        XCTAssertGreaterThan(pixel(decoded.image, x: 90, y: 5).r, 200)
    }

    func testFlattensTransparencyForJPG() async throws {
        let png = write(makeImage(alpha: true), "logo.png", type: "public.png")
        let jpg = try await convert(png, to: .jpg)
        let corner = pixel(try ImageCodec.load(jpg).image, x: 2, y: 2)
        XCTAssertGreaterThan(corner.r, 240)
        XCTAssertGreaterThan(corner.g, 240)
        XCTAssertGreaterThan(corner.b, 240)
    }

    func testPDFPageUsesImageResolution() async throws {
        let png = write(makeImage(), "scan.png", type: "public.png",
                        properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let pdf = try await convert(png, to: .pdf)
        let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
        let box = try XCTUnwrap(document.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, 100, accuracy: 0.5)
        XCTAssertEqual(box.height, 50, accuracy: 0.5)
    }

    func testMaxPixelSizeOptionDownscales() async throws {
        let jpg = write(makeImage(width: 400, height: 200), "big.jpg", type: "public.jpeg")
        var options = ConversionOptions()
        options.imageMaxPixelSize = 100
        let png = try await convert(jpg, to: .png, options: options)
        XCTAssertEqual(try ImageCodec.load(png).image.width, 100)
    }

    func testWebPRoundTripWithFFmpeg() async throws {
        try XCTSkipUnless(WebPTools.canEncode, "cwebp or ffmpeg with libwebp not installed")
        let png = write(makeImage(), "web.png", type: "public.png")
        let webp = try await convert(png, to: .webp)
        let decoded = try ImageCodec.load(webp)
        XCTAssertEqual(decoded.image.width, 200)
        let back = try await convert(webp, to: .jpg)
        XCTAssertEqual(try ImageCodec.load(back).image.height, 100)
    }

    func testOCRExtractsText() async throws {
        let width = 900, height = 200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Hello Tangerine" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [
            .font: NSFont.systemFont(ofSize: 72, weight: .bold), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let png = write(context.makeImage()!, "words.png", type: "public.png")
        let txt = try await convert(png, to: .txt)
        let text = try String(contentsOf: txt, encoding: .utf8)
        XCTAssertTrue(text.localizedCaseInsensitiveContains("tangerine"), "got: \(text)")
    }

    func testAnimatedGIFToMP4() async throws {
        try XCTSkipUnless(backend.supports(from: .gif, to: .mp4), "ffmpeg H.264 encoder not installed")
        let url = temp.file("anim.gif")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil)!
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for _ in 0..<3 {
            CGImageDestinationAddImage(destination, makeImage(width: 101, height: 51),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let mp4 = try await convert(url, to: .mp4)
        XCTAssertEqual(mp4.pathExtension, "mp4")
    }

    func testAnimatedGIFToWebP() async throws {
        try XCTSkipUnless(WebPTools.canEncodeAnimation, "gif2webp not installed")
        let url = temp.file("loop.gif")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 2, nil)!
        for alpha in [false, true] {
            CGImageDestinationAddImage(destination, makeImage(alpha: alpha),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let webp = try await convert(url, to: .webp)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(webp as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2, "animation frames are kept")
    }

    func testOutputNeverOverwrites() async throws {
        let jpg = write(makeImage(), "same.jpg", type: "public.jpeg")
        let first = try await convert(jpg, to: .png)
        let second = try await convert(jpg, to: .png)
        XCTAssertEqual(first.lastPathComponent, "same.png")
        XCTAssertEqual(second.lastPathComponent, "same 2.png")
    }

    // MARK: Tools

    private func run(_ tool: ToolID, _ url: URL) async throws -> ToolOutput {
        let format = try XCTUnwrap(FileFormat.detect(url))
        XCTAssertTrue(tools.supports(tool, format: format), "\(tool) on \(format)")
        return try await tools.run(tool, inputs: [url], output: OutputPlan(for: url), context: ConversionContext())
    }

    func testRotateRightRendersPixels() async throws {
        let png = write(makeImage(), "turn.png", type: "public.png")
        let result = try await run(.rotateRight, png)
        let image = try ImageCodec.load(try XCTUnwrap(result.files.first)).image
        XCTAssertEqual(image.width, 100)
        XCTAssertEqual(image.height, 200)
        XCTAssertGreaterThan(pixel(image, x: 90, y: 5).r, 200, "red marker should move to the top-right")
    }

    func testLosslessJPEGRotationOnlyChangesOrientation() async throws {
        let jpg = write(makeImage(), "lossless.jpg", type: "public.jpeg")
        let result = try await run(.rotateRight, jpg)
        let output = try XCTUnwrap(result.files.first)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 200, "pixels are untouched")
        XCTAssertEqual(try ImageCodec.load(output).image.width, 100, "displays rotated")
    }

    func testOrientationArithmetic() {
        XCTAssertEqual(Orientation.apply(.rotateRight, to: 1), 6)
        XCTAssertEqual(Orientation.apply(.rotateLeft, to: 1), 8)
        XCTAssertEqual(Orientation.apply(.rotateLeft, to: Orientation.apply(.rotateRight, to: 3)), 3)
        for o: UInt32 in 1...8 {
            XCTAssertEqual(Orientation.apply(.flipHorizontal, to: Orientation.apply(.flipHorizontal, to: o)), o)
            XCTAssertEqual(Orientation.apply(.flipVertical, to: Orientation.apply(.flipVertical, to: o)), o)
            var r = o
            for _ in 0..<4 { r = Orientation.apply(.rotateRight, to: r) }
            XCTAssertEqual(r, o)
        }
    }

    func testCompressQuantizesPNG() async throws {
        // A noisy, photo-like PNG compresses well once reduced to a palette.
        let width = 512, height = 512
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var generator = SystemRandomNumberGenerator()
        for y in 0..<height {
            for x in 0..<width {
                let noise = Double(UInt8.random(in: 0...24, using: &generator)) / 255
                context.setFillColor(CGColor(srgbRed: Double(x) / 600 + noise, green: Double(y) / 600 + noise, blue: 0.4 + noise, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        let png = write(context.makeImage()!, "noisy.png", type: "public.png")
        let result = try await run(.compress, png)
        let output = try XCTUnwrap(result.files.first, result.note ?? "no output")
        XCTAssertLessThan(output.fileSize, png.fileSize)
        let decoded = try ImageCodec.load(output)
        XCTAssertEqual(decoded.image.width, width)
        let original = pixel(context.makeImage()!, x: 300, y: 300), compressed = pixel(decoded.image, x: 300, y: 300)
        XCTAssertLessThan(abs(original.r - compressed.r) + abs(original.g - compressed.g) + abs(original.b - compressed.b), 90)
    }

    func testQuantizedPNGKeepsTransparency() throws {
        let image = makeImage(alpha: true)
        let data = try PNGQuantizer.encode(image)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(pixel(decoded, x: 2, y: 2).a, 0, "corner stays transparent")
        XCTAssertEqual(pixel(decoded, x: 100, y: 50).a, 255, "subject stays opaque")
    }

    func testTrimTransparentEdges() async throws {
        let png = write(makeImage(alpha: true), "badge.png", type: "public.png")
        let result = try await run(.trimTransparent, png)
        let image = try ImageCodec.load(try XCTUnwrap(result.files.first)).image
        XCTAssertEqual(image.width, 100, accuracy: 2)
        XCTAssertEqual(image.height, 50, accuracy: 2)
    }

    func testStripMetadataRemovesGPS() async throws {
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 37.33, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 122.0, kCGImagePropertyGPSLongitudeRef: "W"]
        let jpg = write(makeImage(), "trip.jpg", type: "public.jpeg", properties: [kCGImagePropertyGPSDictionary: gps])
        let before = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(jpg as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNotNil(before?[kCGImagePropertyGPSDictionary])
        let result = try await run(.stripMetadata, jpg)
        let output = try XCTUnwrap(result.files.first)
        let after = CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(output as CFURL, nil)!, 0, nil) as? [CFString: Any]
        XCTAssertNil(after?[kCGImagePropertyGPSDictionary])
    }

    func testResizeAndSquare() async throws {
        let png = write(makeImage(), "size.png", type: "public.png")
        let halfResult = try await run(.resizeHalf, png)
        let half = try ImageCodec.load(try XCTUnwrap(halfResult.files.first)).image
        XCTAssertEqual(half.width, 100)
        XCTAssertEqual(half.height, 50)
        let squareResult = try await run(.makeSquare, png)
        let square = try ImageCodec.load(try XCTUnwrap(squareResult.files.first)).image
        XCTAssertEqual(square.width, 200)
        XCTAssertEqual(square.height, 200)
        let fit = try await run(.resizeLong1080, png)
        XCTAssertTrue(fit.files.isEmpty)
        XCTAssertEqual(fit.note, "Already within 1080 px")
    }

    func testCopyTextReturnsText() async throws {
        let png = write(makeImage(), "plain.png", type: "public.png")
        let result = try await run(.copyText, png)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertNotNil(result.text)
    }

    // MARK: Edit recipe

    func testRecipeGeometry() throws {
        let renderer = RecipeRenderer.shared
        let input = CIImage(cgImage: makeImage())
        var recipe = EditRecipe()
        recipe.quarterTurns = 1
        XCTAssertEqual(renderer.apply(recipe, to: input).extent.size, CGSize(width: 100, height: 200))

        recipe = EditRecipe()
        recipe.crop = CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let cropped = try renderer.render(renderer.apply(recipe, to: input))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 50)
        XCTAssertGreaterThan(pixel(cropped, x: 5, y: 5).r, 200, "top-left crop keeps the red marker")

        recipe = EditRecipe()
        recipe.straighten = 10
        XCTAssertEqual(renderer.apply(recipe, to: input).extent.size, CGSize(width: 200, height: 100))

        recipe.outputSize = CGSize(width: 50, height: 25)
        XCTAssertEqual(try renderer.render(renderer.apply(recipe, to: input)).width, 50)
    }

    func testRecipeColorAdjustments() throws {
        let renderer = RecipeRenderer.shared
        let input = CIImage(cgImage: makeImage())
        var recipe = EditRecipe()
        recipe.filter = .mono
        let mono = try renderer.render(renderer.apply(recipe, to: input))
        let p = pixel(mono, x: 150, y: 50)
        XCTAssertEqual(p.r, p.g, accuracy: 3)
        XCTAssertEqual(p.g, p.b, accuracy: 3)

        recipe = EditRecipe()
        recipe.exposure = 0.5
        let bright = try renderer.render(renderer.apply(recipe, to: input))
        XCTAssertGreaterThan(pixel(bright, x: 100, y: 50).g, pixel(makeImage(), x: 100, y: 50).g)
    }
}

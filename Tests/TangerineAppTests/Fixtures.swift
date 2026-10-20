import CoreGraphics
import ImageIO
import TangerineKit
import XCTest

/// Small images written with ImageIO into a scratch folder.
struct EditorFixtures {
    let temp: TemporaryDirectory

    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Opaque gray image with a red block at the stored top-left and a blue block at the stored top-right.
    static func markerImage(width: Int = 200, height: Int = 100, alpha: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        if alpha {
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        } else {
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let side = max(1, min(width, height) / 5)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: height - side, width: side, height: side))   // CG origin is bottom-left
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width - side, y: height - side, width: side, height: side))
        return context.makeImage()!
    }

    @discardableResult
    func write(_ image: CGImage, _ name: String, type: String = "public.jpeg", properties: [CFString: Any] = [:]) -> URL {
        writeFrames([image], name, type: type, properties: properties)
    }

    @discardableResult
    func writeFrames(_ frames: [CGImage], _ name: String, type: String, properties: [CFString: Any] = [:]) -> URL {
        let url = temp.file(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, frames.count, nil)!
        for frame in frames { CGImageDestinationAddImage(destination, frame, properties as CFDictionary) }
        XCTAssertTrue(CGImageDestinationFinalize(destination), name)
        return url
    }

    static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
    }

    /// Straight RGBA of one pixel (top-left origin).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var p = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &p, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    enum Corner: String { case topLeft, topRight, bottomRight, bottomLeft }

    /// Where the red and blue markers are in a displayed image.
    static func markers(_ image: CGImage) -> (red: Corner?, blue: Corner?) {
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
}

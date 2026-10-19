import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import TangerineCore

/// Renders PDF pages to bitmaps and writes them with ImageIO.
enum PDFRasterizer {
    /// Renders the crop box of `page` at `dpi`, honoring the page rotation, on a white background.
    static func render(_ page: PDFPage, dpi: Double) throws -> CGImage {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        var size = box.size
        if rotation == 90 || rotation == 270 { size = CGSize(width: size.height, height: size.width) }
        let scale = dpi / 72
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        // Cap at ~300 megapixels to avoid runaway allocations on huge pages.
        guard width > 0, height > 0, Double(width) * Double(height) <= 300_000_000 else {
            throw ConversionError.failed("This page is too large to render at \(Int(dpi)) DPI.")
        }
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw ConversionError.failed("Couldn't allocate memory to render this page.")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // `draw(with:to:)` maps the box origin to (0, 0) and applies the page rotation itself.
        page.draw(with: .cropBox, to: context)
        guard let image = context.makeImage() else {
            throw ConversionError.failed("Couldn't render this page.")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL, typeIdentifier: String, dpi: Double, quality: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, typeIdentifier as CFString, 1, nil) else {
            throw ConversionError.failed("Can't write \(url.pathExtension.uppercased()) images on this Mac.")
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw ConversionError.failed("Couldn't save “\(url.lastPathComponent)”.")
        }
    }
}

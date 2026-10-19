import AppKit

/// Programmatic artwork: the tangerine mark used for the app icon, menu bar and sample file.
enum TangerineArt {
    static let orange = NSColor(srgbRed: 0xF3 / 255, green: 0x5B / 255, blue: 0x28 / 255, alpha: 1)

    /// Draws a glossy tangerine with a leaf inside `rect` (y-up context).
    static func draw(in context: CGContext, rect: CGRect) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)
        let fruit = CGRect(x: rect.minX + rect.width * 0.06, y: rect.minY + rect.height * 0.02,
                           width: rect.width * 0.88, height: rect.height * 0.8)
        context.saveGState()
        context.addEllipse(in: fruit)
        context.clip()
        let peel = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 1, green: 0.66, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.95, green: 0.36, blue: 0.16, alpha: 1),
            CGColor(srgbRed: 0.8, green: 0.25, blue: 0.1, alpha: 1),
        ] as CFArray, locations: [0, 0.6, 1])!
        context.drawRadialGradient(peel,
                                   startCenter: CGPoint(x: fruit.minX + fruit.width * 0.35, y: fruit.minY + fruit.height * 0.68),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: fruit.midX, y: fruit.midY),
                                   endRadius: fruit.width * 0.62, options: [.drawsAfterEndLocation])
        context.restoreGState()

        // Highlight.
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
        context.fillEllipse(in: CGRect(x: fruit.minX + fruit.width * 0.2, y: fruit.minY + fruit.height * 0.58,
                                       width: fruit.width * 0.22, height: fruit.height * 0.16))

        // Leaf.
        let base = CGPoint(x: fruit.midX, y: fruit.maxY - rect.height * 0.02)
        let leaf = CGMutablePath()
        leaf.move(to: base)
        leaf.addCurve(to: CGPoint(x: base.x + rect.width * 0.3, y: base.y + rect.height * 0.17),
                      control1: CGPoint(x: base.x + rect.width * 0.04, y: base.y + rect.height * 0.16),
                      control2: CGPoint(x: base.x + rect.width * 0.18, y: base.y + rect.height * 0.2))
        leaf.addCurve(to: base,
                      control1: CGPoint(x: base.x + rect.width * 0.26, y: base.y + rect.height * 0.04),
                      control2: CGPoint(x: base.x + rect.width * 0.12, y: base.y - rect.height * 0.01))
        context.addPath(leaf)
        context.setFillColor(CGColor(srgbRed: 0.27, green: 0.62, blue: 0.3, alpha: 1))
        context.fillPath()
        context.setStrokeColor(CGColor(srgbRed: 0.35, green: 0.25, blue: 0.15, alpha: 1))
        context.setLineWidth(max(1, rect.width * 0.025))
        context.setLineCap(.round)
        context.move(to: CGPoint(x: base.x, y: base.y - rect.height * 0.02))
        context.addLine(to: CGPoint(x: base.x - rect.width * 0.03, y: base.y + rect.height * 0.08))
        context.strokePath()
    }

    /// Rounded-square app icon with the tangerine centered.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: CGSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let tile = rect.insetBy(dx: rect.width * 0.09, dy: rect.height * 0.09)
            let path = CGPath(roundedRect: tile, cornerWidth: tile.width * 0.225, cornerHeight: tile.width * 0.225, transform: nil)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -rect.height * 0.012), blur: rect.width * 0.03,
                              color: CGColor(gray: 0, alpha: 0.3))
            context.addPath(path)
            context.setFillColor(CGColor(srgbRed: 0.995, green: 0.97, blue: 0.93, alpha: 1))
            context.fillPath()
            context.restoreGState()
            draw(in: context, rect: tile.insetBy(dx: tile.width * 0.16, dy: tile.height * 0.14))
            return true
        }
    }

    /// Monochrome template for the menu bar.
    static func menuBarIcon() -> NSImage {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setStrokeColor(.black)
            context.setFillColor(.black)
            context.setLineWidth(1.6)
            context.strokeEllipse(in: CGRect(x: 2.5, y: 1.5, width: 13, height: 12))
            context.fillEllipse(in: CGRect(x: 6.5, y: 5, width: 5, height: 5))
            let leaf = CGMutablePath()
            leaf.move(to: CGPoint(x: 9, y: 13.2))
            leaf.addQuadCurve(to: CGPoint(x: 15, y: 16.5), control: CGPoint(x: 10.5, y: 17))
            leaf.addQuadCurve(to: CGPoint(x: 9, y: 13.2), control: CGPoint(x: 13.5, y: 13))
            context.addPath(leaf)
            context.fillPath()
            _ = rect
            return true
        }
        image.isTemplate = true
        return image
    }
}

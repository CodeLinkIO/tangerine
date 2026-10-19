import AppKit
import TangerineKit

/// Hidden command-line flags:
///   --render-iconset <dir>                 writes AppIcon PNGs for iconutil
///   --render-wheel <png> <file> [tools] [dark] [highlight N]   snapshots the wheel for a file
@MainActor
enum DeveloperCommands {
    static func run(_ arguments: [String]) -> Bool {
        guard arguments.count >= 3 else { return false }
        switch arguments[1] {
        case "--render-iconset":
            renderIconset(to: URL(fileURLWithPath: arguments[2], isDirectory: true))
            return true
        case "--render-wheel" where arguments.count >= 4:
            let rest = Array(arguments.dropFirst(4))
            let highlight = rest.firstIndex(of: "highlight").flatMap { rest.indices.contains($0 + 1) ? Int(rest[$0 + 1]) : nil }
            renderWheel(to: URL(fileURLWithPath: arguments[2]), file: URL(fileURLWithPath: arguments[3]),
                        mode: rest.contains("tools") ? .tools : .convert, dark: rest.contains("dark"), highlight: highlight)
            return true
        default:
            return false
        }
    }

    private static func renderIconset(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = points * scale
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                writePNG(TangerineArt.appIcon(size: CGFloat(pixels)), pixels: pixels, to: folder.appendingPathComponent(name))
            }
        }
    }

    private static func renderWheel(to url: URL, file: URL, mode: WheelMode, dark: Bool, highlight: Int?) {
        let view = WheelView(frame: CGRect(origin: .zero, size: WheelView.size))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.items = WheelController.items(for: mode, files: [file])
        view.mode = mode
        view.keys = WheelMode.allCases.map { (Preferences.shared.key(for: $0), $0) }
        view.subtitle = WheelController.summary(of: [file])
        view.emptyMessage = "No conversions for this file.\nTap ⌘ for edits and tools."
        if let highlight {
            let point = WheelGeometry.labelPoint(index: highlight, count: view.items.count, center: view.wheelCenter)
            view.select(at: point)
        }
        // Composite over a backdrop so the translucent petals are visible in the snapshot.
        let scale = 2
        let size = WheelView.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(srgbRed: 0.9, green: 0.92, blue: 0.95, alpha: 1)).setFill()
        CGRect(origin: .zero, size: size).fill()
        view.appearance?.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("\(view.items.map(\.label))")
    }

    private static func writePNG(_ image: NSImage, pixels: Int, to url: URL) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = CGSize(width: pixels, height: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

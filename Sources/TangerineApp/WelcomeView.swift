import AppKit
import SwiftUI
import TangerineKit

@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 470),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: WelcomeView(sample: Self.makeSampleFile()) { [weak self] in
            Preferences.shared.hasSeenWelcome = true
            self?.close()
        })
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    /// A small photo-like JPEG to practice with, kept in Application Support.
    static func makeSampleFile() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let folder = support.appendingPathComponent("Tangerine", isDirectory: true)
        let url = folder.appendingPathComponent("Sample Photo.jpg")
        if fm.fileExists(atPath: url.path) { return url }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let width = 1600, height = 1067
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.36, alpha: 1),
            CGColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1),
        ] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.36, blue: 0.24, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 220))
        TangerineArt.draw(in: context, rect: CGRect(x: 560, y: 260, width: 480, height: 480))
        guard let image = context.makeImage(),
              let data = try? ImageCodec.encode(image, as: .jpg, options: .init(quality: 0.9)) else { return nil }
        try? data.write(to: url)
        return url
    }
}

struct WelcomeView: View {
    let sample: URL?
    let onDone: () -> Void
    @ObservedObject private var prefs = Preferences.shared
    private let orange = Color(red: 0xF3 / 255, green: 0x5B / 255, blue: 0x28 / 255)

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: TangerineArt.appIcon(size: 72)).resizable().frame(width: 72, height: 72)
            VStack(spacing: 6) {
                Text("The zero-click file converter").font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Drag a file, tap a key, drop. Everything happens on your Mac.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 26) {
                step(1, "Drag", "Start dragging any file, from Finder or right here.")
                step(2, "Tap \(prefs.convertKey.symbol) or \(prefs.toolsKey.symbol)",
                     "\(prefs.convertKey.name) converts, \(prefs.toolsKey.name) shows edits and tools.")
                step(3, "Drop", "Drop on a petal. The result is saved next to the original.")
            }
            .padding(.horizontal, 30)

            if let sample {
                VStack(spacing: 6) {
                    DraggableFile(url: sample).frame(width: 96, height: 96)
                    Text("Try it: drag this file, then tap \(prefs.convertKey.symbol)").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Open Converter") { ConverterWindowController.shared.show() }
                Spacer()
                Button("Get Started", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(orange)
            }
            .padding(.horizontal, 30)
        }
        .padding(.vertical, 26)
        .frame(width: 620, height: 470)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(orange))
            Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// An icon you can drag like a file in Finder (uses a real file URL on the drag pasteboard).
struct DraggableFile: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> DraggableFileView { DraggableFileView(url: url) }
    func updateNSView(_ view: DraggableFileView, context: Context) {}
}

final class DraggableFileView: NSView, NSDraggingSource {
    let url: URL
    private lazy var icon: NSImage = NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: url.path)

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.6).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : [.copy, .generic]
    }
}

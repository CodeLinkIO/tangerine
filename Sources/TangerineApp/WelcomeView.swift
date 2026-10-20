import AppKit
import SwiftUI
import TangerineKit

@MainActor
final class WelcomeWindowController: NSWindowController {
    static let shared = WelcomeWindowController()

    private init() {
        let window = NSWindow.themed(size: CGSize(width: 640, height: 600), title: "Welcome", resizable: false)
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
    @State private var openAtLogin = true

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: TangerineArt.appIcon(size: 64)).resizable().frame(width: 64, height: 64)
                .padding(.bottom, 18)
            Text("The zero-click\noffline file converter.")
                .font(.system(size: 40, weight: .medium)).tracking(-1.1)
                .multilineTextAlignment(.center).foregroundStyle(Theme.text)
            Text("Drag a file, tap \(prefs.convertKey.symbol), and drop. Everything happens on your Mac.")
                .font(Theme.label(14, weight: .regular)).foregroundStyle(Theme.muted).padding(.top, 12)

            Card(padding: 0, radius: 20) {
                HStack(spacing: 0) {
                    VStack(spacing: 8) {
                        if let sample {
                            DraggableFile(url: sample).frame(width: 84, height: 84)
                            Text(sample.lastPathComponent).font(Theme.label(11.5)).foregroundStyle(Theme.text)
                            Text("Drag this file").font(Theme.label(11, weight: .regular)).foregroundStyle(Theme.muted)
                        }
                    }
                    .frame(width: 200)
                    Rectangle().fill(Theme.line).frame(width: 1).padding(.vertical, 22)
                    VStack(alignment: .leading, spacing: 14) {
                        step(KeyCap(symbol: prefs.convertKey.symbol, name: prefs.convertKey.name), "Convert", "JPG, PNG, WebP, MP4, MP3, PDF…")
                        step(KeyCap(symbol: prefs.toolsKey.symbol, name: prefs.toolsKey.name), "Edit", "Crop, rotate, resize, compress")
                        step(Image(systemName: "arrow.down.circle.fill").font(.system(size: 22)).foregroundStyle(Theme.orange),
                             "Drop on a petal", "Saved next to the original")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 26)
                    .padding(.trailing, 12)
                }
                .frame(height: 190)
            }
            .padding(.top, 30)

            HStack(spacing: 10) {
                Toggle("", isOn: $openAtLogin).toggleStyle(.switch).labelsHidden().tint(Theme.orange)
                Text("Open at login").font(Theme.label(13)).foregroundStyle(Theme.text)
                Spacer()
                Button("Open Converter") { ConverterWindowController.shared.show() }.buttonStyle(.secondary)
                Button("Get Started") {
                    if openAtLogin != prefs.launchAtLogin { prefs.launchAtLogin = openAtLogin }
                    onDone()
                }
                .buttonStyle(.primary).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 26)
        }
        .padding(.horizontal, 44)
        .padding(.top, 36)
        .padding(.bottom, 30)
        .frame(width: 640, height: 600)
        .background(Theme.page)
    }

    private func step(_ icon: some View, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 12) {
            icon.frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.label(13.5, weight: .semibold)).foregroundStyle(Theme.text)
                Text(detail).font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.muted)
            }
        }
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

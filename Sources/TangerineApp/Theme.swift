import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Visual language borrowed from tangerineformac.com: soft off-white page, white rounded cards
/// with hairline borders, orange accents, rounded labels and big friendly controls.
enum Theme {
    static let orange = Color(hex: 0xF35B28)
    /// Brighter orange used for selected petals and chips.
    static let orangeHot = Color(hex: 0xFF5200)
    static let page = Color.adaptive(light: 0xF4F4F4, dark: 0x161616)
    static let card = Color.adaptive(light: 0xFFFFFF, dark: 0x232323)
    static let line = Color.adaptive(light: 0xE6E6E6, dark: 0x343434)
    /// Fill for unselected chips and segmented controls.
    static let subtle = Color.adaptive(light: 0xF1F1F0, dark: 0x2D2D2D)
    /// Selected segment in a `Segmented` control: lifts above the track in both appearances.
    static let raised = Color.adaptive(light: 0xFFFFFF, dark: 0x464646)
    static let text = Color.adaptive(light: 0x292929, dark: 0xF2F2F2)
    static let muted = Color.adaptive(light: 0x777777, dark: 0x9C9C9C)
    static let faint = Color.adaptive(light: 0xA0A69D, dark: 0x6E6E6E)

    static let nsOrange = NSColor(srgbRed: 0xF3 / 255, green: 0x5B / 255, blue: 0x28 / 255, alpha: 1)
    static let nsOrangeHot = NSColor(srgbRed: 1, green: 0x52 / 255, blue: 0, alpha: 1)

    static func title(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .medium) }
    static func label(_ size: CGFloat = 13, weight: Font.Weight = .medium) -> Font { .system(size: size, weight: weight) }
    static func rounded(_ size: CGFloat = 13, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// A color that follows the window's light/dark appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Containers

/// White rounded card with a hairline border and a whisper of shadow.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.035), radius: 18, y: 8)
    }
}

/// Small grey section label.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.label(12, weight: .semibold)).foregroundStyle(Theme.muted)
    }
}

// MARK: - Controls

/// Capsule choice, orange when selected (formats, presets, ratios).
struct Chip: View {
    let title: String
    var systemImage: String? = nil
    var isSelected = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title)
            }
            .font(Theme.rounded(12.5))
            .foregroundStyle(isSelected ? Color.white : Theme.text)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(
                Capsule().fill(isSelected ? Theme.orangeHot : (hovering ? Theme.line : Theme.subtle))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

/// Pill-shaped segmented control (the site's tab switcher).
struct Segmented<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let title: (Value) -> String

    var body: some View {
        HStack(spacing: 3) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(title(option))
                        .lineLimit(1)
                        .fixedSize()
                        .font(Theme.label(12.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.muted)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 54, minHeight: 26)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised)
                                    .shadow(color: .black.opacity(0.07), radius: 2, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .fixedSize()
        .background(Theme.subtle, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(Capsule().fill(Theme.orange.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .contentShape(Capsule())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.label(13, weight: .medium))
            .foregroundStyle(Theme.text.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, 16)
            .frame(height: 34)
            .background(Capsule().fill(configuration.isPressed ? Theme.subtle : Theme.card))
            .overlay(Capsule().strokeBorder(Theme.line))
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// Round icon-only button (undo, remove, close).
struct IconButton: View {
    let systemImage: String
    var help: String = ""
    var size: CGFloat = 28
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(Theme.muted.opacity(isEnabled ? 1 : 0.4))
                .frame(width: size, height: size)
                .background(Circle().fill(hovering && isEnabled ? Theme.subtle : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Keyboard key, like the ⇧ / ⌘ caps on the website.
struct KeyCap: View {
    let symbol: String
    var name: String? = nil
    var isActive = false

    var body: some View {
        HStack(spacing: 5) {
            Text(symbol).font(Theme.rounded(13, weight: .bold))
            if let name { Text(name.lowercased()).font(Theme.label(10.5, weight: .medium)) }
        }
        .foregroundStyle(isActive ? Color.white : Theme.text)
        .padding(.horizontal, 9)
        .frame(minWidth: 30, minHeight: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isActive ? Theme.orangeHot : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(isActive ? .clear : Theme.line))
        .shadow(color: .black.opacity(isActive ? 0 : 0.08), radius: 0, y: 1.5)
    }
}

/// Settings-style row inside a card: title (+ optional detail) on the left, control on the right.
struct Row<Control: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.label(13.5)).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.muted) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.vertical, 6)
    }
}

/// Hairline divider in the theme's line color.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.line).frame(height: 1) }
}

// MARK: - File thumbnails

/// Quick Look thumbnail for any file (falls back to the Finder icon).
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 44
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .background(Theme.subtle)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).strokeBorder(Theme.line))
        .task(id: url) { image = await Self.thumbnail(for: url, size: size) }
    }

    static func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: scale,
                                                   representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
    }
}

// MARK: - Windows

extension NSWindow {
    /// Borderless-looking window on the page background with the traffic lights floating over content.
    static func themed(size: CGSize, title: String, resizable: Bool = true) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(Theme.page)
        window.isReleasedWhenClosed = false
        return window
    }
}

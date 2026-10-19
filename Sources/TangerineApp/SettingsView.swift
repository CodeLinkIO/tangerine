import AppKit
import SwiftUI
import TangerineKit

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 520),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Tangerine Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = NSHostingView(rootView: SettingsView(prefs: .shared))
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        TabView {
            GeneralSettings(prefs: prefs).tabItem { Label("General", systemImage: "gearshape") }
            WheelSettings(prefs: prefs).tabItem { Label("Wheel", systemImage: "circle.circle") }
            OptionsForm(options: $prefs.options).tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            EngineSettings().tabItem { Label("Engines", systemImage: "cpu") }
        }
        .frame(width: 560, height: 520)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Section("Drag wheel") {
                Toggle("Open the wheel while dragging files", isOn: $prefs.dragWheelEnabled)
                keyPicker("Convert wheel", selection: $prefs.convertKey, other: prefs.toolsKey)
                keyPicker("Edit wheel", selection: $prefs.toolsKey, other: prefs.convertKey)
                Text("Start dragging a file, tap the key, then drop on a petal. The wheel stays open until you drop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Saving") {
                LabeledContent("Save results") {
                    HStack {
                        Text(prefs.outputFolder?.path(percentEncoded: false) ?? "Next to the original")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { chooseFolder() }
                        if prefs.outputFolder != nil { Button("Reset") { prefs.outputFolder = nil } }
                    }
                }
                Toggle("Reveal results in Finder", isOn: $prefs.revealInFinder)
                Toggle("Move originals to the Trash after converting", isOn: $prefs.replaceOriginals)
            }
            Section("Shortcuts") {
                Toggle("⌃⌥T opens the wheel for the Finder selection", isOn: $prefs.finderShortcutEnabled)
                Text("Finder → right-click → Services → “Convert with Tangerine” also works.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
            }
        }
        .formStyle(.grouped)
    }

    private func keyPicker(_ title: String, selection: Binding<ModifierKey>, other: ModifierKey) -> some View {
        Picker(title, selection: selection) {
            ForEach(ModifierKey.allCases) { key in
                Text("\(key.symbol) \(key.name)").tag(key).disabled(key == other)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK { prefs.outputFolder = panel.url }
    }
}

/// Pick which formats appear on the convert wheel for each kind of file.
private struct WheelSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        Form {
            Text("Choose up to \(TargetCatalog.wheelCapacity) formats per kind of file. Everything else stays one tap away under “More…”.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(FormatCategory.allCases, id: \.self) { category in
                Section(category.title) {
                    let available = Self.available(for: category)
                    let pinned = prefs.pinnedTargets[category] ?? Array(available.prefix(TargetCatalog.wheelCapacity))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 4), spacing: 6) {
                        ForEach(available, id: \.self) { format in
                            Toggle(format.shortName, isOn: Binding(
                                get: { pinned.contains(format) },
                                set: { on in toggle(format, on: on, category: category, current: pinned, available: available) }
                            ))
                            .toggleStyle(.checkbox)
                            .disabled(!pinned.contains(format) && pinned.count >= TargetCatalog.wheelCapacity)
                        }
                    }
                    if prefs.pinnedTargets[category] != nil {
                        Button("Use Defaults") { prefs.pinnedTargets[category] = nil }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func toggle(_ format: FileFormat, on: Bool, category: FormatCategory, current: [FileFormat], available: [FileFormat]) {
        var set = Set(current)
        if on { set.insert(format) } else { set.remove(format) }
        prefs.pinnedTargets[category] = available.filter(set.contains)
    }

    /// Targets at least one format of the category can be converted to.
    static func available(for category: FormatCategory) -> [FileFormat] {
        let sources = FileFormat.allCases.filter { $0.category == category }
        let reachable = Set(sources.flatMap { Engine.shared.targets(from: $0) })
        return TargetCatalog.orderedTargets(for: category).filter(reachable.contains)
    }
}

private struct EngineSettings: View {
    private let ffmpeg = FFmpeg.shared

    var body: some View {
        Form {
            Section("Built in") {
                row("Images, PDF, documents, OCR", ok: true, detail: "ImageIO, Core Image, PDFKit, Vision")
                row("Video and audio", ok: true, detail: "AVFoundation, Core Audio")
                row("Background removal", ok: RecipeRenderer.canRemoveBackground,
                    detail: RecipeRenderer.canRemoveBackground ? "Vision" : "Needs macOS 14 or later")
            }
            Section("Optional engines") {
                row("ffmpeg", ok: ffmpeg.isAvailable,
                    detail: ffmpeg.path ?? "Adds MP3, OGG, Opus, WMA, MKV, WebM, AVI, WMV and better GIFs")
                row("WebP (libwebp)", ok: WebPTools.canEncode, detail: WebPTools.cwebp ?? "Adds WebP output")
                if !ffmpeg.isAvailable || !WebPTools.canEncode {
                    HStack {
                        Text("brew install ffmpeg webp").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install ffmpeg webp", forType: .string)
                        }
                    }
                }
            }
            Section {
                LabeledContent("Conversion options", value: "\(FileFormat.allCases.reduce(0) { $0 + Engine.shared.targets(from: $1).count })")
                LabeledContent("Image formats written", value: ImageCodec.writableFormats.map(\.displayName).sorted().joined(separator: ", "))
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(ok ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
    }
}

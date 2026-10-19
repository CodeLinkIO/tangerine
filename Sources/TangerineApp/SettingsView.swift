import AppKit
import SwiftUI
import TangerineKit

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow.themed(size: CGSize(width: 600, height: 620), title: "Settings", resizable: false)
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

private enum SettingsTab: String, CaseIterable {
    case general = "General", wheel = "Wheel", engines = "Engines"
}

struct SettingsView: View {
    @ObservedObject var prefs: Preferences
    @State private var tab: SettingsTab = .general

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                Text("Settings").font(Theme.title(24)).tracking(-0.7).foregroundStyle(Theme.text)
                Spacer()
                Segmented(options: SettingsTab.allCases, selection: $tab) { $0.rawValue }
            }
            ScrollView {
                Group {
                    switch tab {
                    case .general: GeneralSettings(prefs: prefs)
                    case .wheel: WheelSettings(prefs: prefs)
                    case .engines: EngineSettings()
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.never)
        }
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .frame(width: 600, height: 620, alignment: .top)
        .background(Theme.page)
        .tint(Theme.orange)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var prefs: Preferences

    var body: some View {
        VStack(spacing: 14) {
            Card {
                VStack(spacing: 4) {
                    Row(title: "Open the wheel while dragging", detail: "Drag a file, tap a key, drop on a petal.") {
                        Toggle("", isOn: $prefs.dragWheelEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    Hairline()
                    Row(title: "Convert key") { keyChoice($prefs.convertKey, other: prefs.toolsKey) }
                    Hairline()
                    Row(title: "Edit key") { keyChoice($prefs.toolsKey, other: prefs.convertKey) }
                }
            }
            Card {
                VStack(spacing: 4) {
                    Row(title: "Quality", detail: "Used by the wheel and as the Converter default.") {
                        Segmented(options: QualityPreset.allCases, selection: $prefs.quality) { $0.title }
                    }
                    Hairline()
                    Row(title: "Save results", detail: prefs.outputFolder?.path(percentEncoded: false) ?? "Next to the original file") {
                        HStack(spacing: 6) {
                            if prefs.outputFolder != nil {
                                Button("Reset") { prefs.outputFolder = nil }.buttonStyle(.secondary)
                            }
                            Button("Change…") { chooseFolder() }.buttonStyle(.secondary)
                        }
                    }
                    Hairline()
                    Row(title: "Show results in Finder") {
                        Toggle("", isOn: $prefs.revealInFinder).toggleStyle(.switch).labelsHidden()
                    }
                    Hairline()
                    Row(title: "Move originals to the Trash", detail: "After a successful conversion.") {
                        Toggle("", isOn: $prefs.replaceOriginals).toggleStyle(.switch).labelsHidden()
                    }
                }
            }
            Card {
                VStack(spacing: 4) {
                    Row(title: "⌃⌥T converts the Finder selection", detail: "Or right-click → Services → Convert with Tangerine.") {
                        Toggle("", isOn: $prefs.finderShortcutEnabled).toggleStyle(.switch).labelsHidden()
                    }
                    Hairline()
                    Row(title: "Open at login") {
                        Toggle("", isOn: Binding(get: { prefs.launchAtLogin }, set: { prefs.launchAtLogin = $0 }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                }
            }
        }
    }

    private func keyChoice(_ selection: Binding<ModifierKey>, other: ModifierKey) -> some View {
        HStack(spacing: 6) {
            ForEach(ModifierKey.allCases) { key in
                Button { selection.wrappedValue = key } label: {
                    KeyCap(symbol: key.symbol, name: key.name, isActive: selection.wrappedValue == key)
                }
                .buttonStyle(.plain)
                .disabled(key == other)
                .opacity(key == other ? 0.35 : 1)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose up to \(TargetCatalog.wheelCapacity) formats per kind of file. The rest stay under “More…”.")
                .font(Theme.label(12.5, weight: .regular)).foregroundStyle(Theme.muted)
            ForEach(FormatCategory.allCases, id: \.self) { category in
                let available = Self.available(for: category)
                let pinned = prefs.pinnedTargets[category] ?? Array(available.prefix(TargetCatalog.wheelCapacity))
                Card(padding: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(category.title)
                            Spacer()
                            if prefs.pinnedTargets[category] != nil {
                                Button("Reset") { prefs.pinnedTargets[category] = nil }
                                    .buttonStyle(.plain).font(Theme.label(12, weight: .semibold)).foregroundStyle(Theme.orange)
                            }
                        }
                        ChipFlow(spacing: 6) {
                            ForEach(available, id: \.self) { format in
                                let on = pinned.contains(format)
                                Chip(title: format.shortName, isSelected: on) {
                                    toggle(format, category: category, current: pinned, available: available)
                                }
                                .opacity(!on && pinned.count >= TargetCatalog.wheelCapacity ? 0.4 : 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ format: FileFormat, category: FormatCategory, current: [FileFormat], available: [FileFormat]) {
        var set = Set(current)
        if set.contains(format) {
            guard set.count > 1 else { return }
            set.remove(format)
        } else {
            guard set.count < TargetCatalog.wheelCapacity else { return }
            set.insert(format)
        }
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
        VStack(spacing: 14) {
            Card {
                VStack(spacing: 4) {
                    status("Images, PDF and documents", ok: true, detail: "Built into macOS")
                    Hairline()
                    status("Video and audio", ok: true, detail: "Built into macOS")
                    Hairline()
                    status("More video and audio formats", ok: ffmpeg.isAvailable,
                           detail: ffmpeg.isAvailable ? "ffmpeg · MP3, OGG, MKV, WebM, AVI, WMV" : "Install ffmpeg to add MP3, OGG, MKV, WebM, AVI, WMV")
                    Hairline()
                    status("WebP", ok: WebPTools.canEncode, detail: WebPTools.canEncode ? "libwebp" : "Install webp to save WebP images")
                }
            }
            if !ffmpeg.isAvailable || !WebPTools.canEncode {
                Card(padding: 14) {
                    HStack {
                        Text("brew install ffmpeg webp").font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install ffmpeg webp", forType: .string)
                        }
                        .buttonStyle(.secondary)
                    }
                }
            }
            Text("\(FileFormat.allCases.reduce(0) { $0 + Engine.shared.targets(from: $1).count }) conversions available · all processing stays on this Mac")
                .font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.faint)
        }
    }

    private func status(_ title: String, ok: Bool, detail: String) -> some View {
        Row(title: title, detail: detail) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 17)).foregroundStyle(ok ? Theme.orange : Theme.faint)
        }
    }
}

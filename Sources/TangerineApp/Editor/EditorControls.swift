import AppKit
import SwiftUI
import TangerineKit

/// The card under the image: four tools, their options, and saving.
struct EditorControls: View {
    @ObservedObject var model: EditorModel
    private static let labelWidth: CGFloat = 62

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(EditorTool.allCases) { tool in
                        EditorToolButton(tool: tool, isSelected: model.tool == tool) { alternate in
                            model.tap(tool, alternate: alternate)
                        }
                    }
                    Spacer()
                    Button("Reset", action: model.resetAll)
                        .buttonStyle(.plain)
                        .font(Theme.label(12.5))
                        .foregroundStyle(model.state == EditorState() ? Theme.faint : Theme.muted)
                        .disabled(model.state == EditorState())
                        .help("Undo every edit")
                }
                options
                    .frame(height: 30)
                Hairline()
                saveRow
                exportRow
                if let hint = model.transparencyHint {
                    Text(hint).font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.muted)
                }
            }
        }
    }

    // MARK: Tool options

    @ViewBuilder private var options: some View {
        switch model.tool {
        case nil:
            Text("Pick a tool to crop, rotate, flip or resize.")
                .font(Theme.label(12.5, weight: .regular))
                .foregroundStyle(Theme.muted)
                .frame(maxHeight: .infinity)
        case .crop:
            HStack(spacing: 6) {
                ForEach(EditorAspect.allCases) { aspect in
                    Chip(title: aspect.title, isSelected: model.aspect == aspect) { model.setAspect(aspect) }
                }
                IconButton(systemImage: "arrow.left.arrow.right", help: "Switch portrait / landscape",
                           action: model.swapAspect)
                    .disabled(!model.aspect.canSwap)
                Spacer(minLength: 8)
                Text(EditorFormatting.pixels(model.croppedSize))
                    .font(Theme.label(12)).monospacedDigit().foregroundStyle(Theme.muted)
                Chip(title: "Done", systemImage: "checkmark", action: model.commitCrop)
                    .help("Keep this crop (Return)")
            }
        case .rotate:
            HStack(spacing: 6) {
                Chip(title: "Left", systemImage: "rotate.left") { model.rotate(clockwise: false) }
                Chip(title: "Right", systemImage: "rotate.right") { model.rotate(clockwise: true) }
                Spacer()
            }
        case .flip:
            HStack(spacing: 6) {
                Chip(title: "Horizontal", systemImage: "arrow.left.and.right") { model.flip(horizontal: true) }
                Chip(title: "Vertical", systemImage: "arrow.up.and.down") { model.flip(horizontal: false) }
                Spacer()
            }
        case .resize:
            resizeOptions
        }
    }

    private var resizeOptions: some View {
        HStack(spacing: 6) {
            ForEach(Array(EditorResize.presets.enumerated()), id: \.offset) { _, preset in
                let applies = preset.applies(to: model.croppedSize)
                Chip(title: preset.title, isSelected: model.state.resize == preset) { model.setResize(preset) }
                    .disabled(!applies)
                    .opacity(applies ? 1 : 0.4)
                    .help(applies ? "" : "Already smaller than \(preset.title)")
            }
            Chip(title: "Custom", isSelected: model.state.resize.isCustom, action: model.startCustomSize)
            if let custom = model.customSize {
                SizeField(value: custom.width, onCommit: model.setCustomWidth)
                Text("×").font(Theme.label(12)).foregroundStyle(Theme.muted)
                SizeField(value: custom.height, onCommit: model.setCustomHeight)
                IconButton(systemImage: custom.locked ? "lock.fill" : "lock.open",
                           help: custom.locked ? "Keep proportions (on)" : "Keep proportions (off)",
                           action: model.toggleCustomLock)
            }
            Spacer(minLength: 8)
            if model.state.resize != .original, !model.state.resize.isCustom {
                Text("→ \(EditorFormatting.pixels(model.finalSize))")
                    .font(Theme.label(12)).monospacedDigit().foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: Saving

    private var saveRow: some View {
        HStack(spacing: 6) {
            SectionLabel("Save as").frame(width: Self.labelWidth, alignment: .leading)
            ForEach(model.primaryFormats, id: \.self) { format in
                Chip(title: format.shortName, isSelected: model.exportFormat == format) { model.exportFormat = format }
            }
            if !model.moreFormats.isEmpty {
                let picked = model.moreFormats.contains(model.exportFormat)
                Menu {
                    ForEach(model.moreFormats, id: \.self) { format in
                        Button(format.displayName) { model.exportFormat = format }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(picked ? model.exportFormat.shortName : "More")
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    }
                    .font(Theme.rounded(12.5))
                    .foregroundStyle(picked ? Color.white : Theme.text)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(picked ? Theme.orangeHot : Theme.subtle))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(EditorFormatting.pixels(model.finalSize))
                    .font(Theme.label(12.5)).monospacedDigit().foregroundStyle(Theme.text)
                Text(estimateText).font(Theme.label(11.5, weight: .regular)).monospacedDigit().foregroundStyle(Theme.muted)
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    private var exportRow: some View {
        HStack(spacing: 10) {
            if model.isLossy {
                SectionLabel("Quality").frame(width: Self.labelWidth, alignment: .leading)
                Segmented(options: QualityPreset.allCases, selection: $model.qualityPreset) { $0.title }
                    .fixedSize()
            }
            Spacer(minLength: 8)
            Button("Replace Original") { confirmReplace() }
                .buttonStyle(.secondary)
                .disabled(!model.canReplaceOriginal || model.isSaving)
                .help(model.replaceHelp)
            Button {
                Task { await model.saveCopy() }
            } label: {
                HStack(spacing: 6) {
                    if model.isSaving {
                        ProgressView().controlSize(.small).tint(.white)
                        Text("Saving…")
                    } else if model.justSaved {
                        Image(systemName: "checkmark")
                        Text("Saved")
                    } else {
                        Text("Save Copy")
                    }
                }
                .frame(minWidth: 92)
            }
            .buttonStyle(.primary)
            .disabled(model.isSaving || !model.isFullResolutionReady)
            .help("Save as a new file next to the original (⌘S)")
        }
    }

    private var estimateText: String {
        switch model.estimate {
        case let .bytes(bytes): EditorFormatting.estimate(bytes: bytes)
        case .working, .unknown: "estimating…"
        case .failed: "size unknown"
        }
    }

    private func confirmReplace() {
        let alert = NSAlert()
        alert.messageText = "Replace “\(model.url.lastPathComponent)”?"
        alert.informativeText = "The original file will be overwritten with your edits. This can't be undone."
        alert.addButton(withTitle: "Replace").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await model.replaceOriginal() }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(alert.runModal())
        }
    }
}

/// Big icon-over-label tool button.
struct EditorToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    /// Receives whether ⌥ was held (counter-clockwise rotate / vertical flip).
    let action: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        Button {
            action(NSEvent.modifierFlags.contains(.option))
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tool.symbol).font(.system(size: 17, weight: .medium)).frame(height: 20)
                Text(tool.title).font(Theme.label(11.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? Theme.orange : Theme.text)
            .frame(width: 74, height: 54)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.orange.opacity(0.1) : (hovering ? Theme.subtle : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.orange.opacity(0.35) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }

    private var help: String {
        switch tool {
        case .crop: "Crop (Return to finish, Esc to cancel)"
        case .rotate: "Rotate 90° clockwise (⌥-click: counter-clockwise)"
        case .flip: "Flip horizontally (⌥-click: vertically)"
        case .resize: "Resize the result"
        }
    }
}

/// Compact pixel field used for custom sizes; commits on Return or when focus leaves.
struct SizeField: View {
    let value: Int
    let onCommit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.label(12.5)).monospacedDigit()
            .multilineTextAlignment(.center)
            .frame(width: 58, height: 26)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtle))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.orange.opacity(0.6) : Theme.line))
            .focused($focused)
            .onAppear { text = "\(value)" }
            .onChange(of: value) { text = "\($0)" }
            .onChange(of: focused) { if !$0 { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        if let number = Int(text.filter(\.isNumber)), number > 0, number != value {
            onCommit(number)
        } else {
            text = "\(value)"
        }
    }
}

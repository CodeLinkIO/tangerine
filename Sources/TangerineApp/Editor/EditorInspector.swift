import SwiftUI
import TangerineKit

/// Right-hand sidebar: section tabs, the active section, and the export panel.
struct EditorInspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorSectionTabs(selection: $model.section)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch model.section {
                    case .crop: EditorCropSection(model: model)
                    case .adjust: EditorAdjustSection(model: model)
                    case .filters: EditorFiltersSection(model: model)
                    case .background: EditorBackgroundSection(model: model)
                    case .resize: EditorResizeSection(model: model)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            EditorExportPanel(model: model)
                .padding(16)
        }
        .frame(width: EditorStyle.sidebarWidth)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isLoading || model.loadError != nil)
    }
}

struct EditorSectionTabs: View {
    @Binding var selection: EditorSection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(EditorSection.allCases) { section in
                let selected = section == selection
                Button {
                    selection = section
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .frame(height: 18)
                        Text(section.title)
                            .font(.system(size: 10, weight: selected ? .semibold : .regular))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? EditorStyle.accent.opacity(0.16) : Color.clear)
                    )
                    .foregroundStyle(selected ? EditorStyle.accent : Color.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(section.title)
            }
        }
    }
}

// MARK: - Crop

struct EditorCropSection: View {
    @ObservedObject var model: EditorModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Aspect Ratio")
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(EditorAspect.allCases) { aspect in
                    EditorChip(title: aspect.title, isSelected: model.aspect == aspect) { model.setAspect(aspect) }
                }
            }
            Button {
                model.swapAspect()
            } label: {
                Label("Swap Orientation", systemImage: "rectangle.portrait.rotate")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canSwapAspect)
            .help("Swap the aspect ratio orientation")
        }

        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Straighten", resetEnabled: model.recipe.straighten != 0) {
                model.change { $0.straighten = 0 }
            }
            EditorSlider(title: "Angle",
                         value: Binding(get: { model.recipe.straighten }, set: { v in model.update { $0.straighten = v } }),
                         range: -45...45,
                         format: { EditorFormatting.degrees($0) },
                         onEditingChanged: { if !$0 { model.endContinuousEdit() } },
                         onReset: { model.change { $0.straighten = 0 } })
        }

        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Rotate & Flip")
            HStack(spacing: 6) {
                EditorIconButton(symbol: "rotate.left", help: "Rotate Left") { model.rotate(clockwise: false) }
                EditorIconButton(symbol: "rotate.right", help: "Rotate Right") { model.rotate(clockwise: true) }
                EditorIconButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                                 help: "Flip Horizontal", isActive: model.recipe.flipHorizontal) { model.flip(horizontal: true) }
                EditorIconButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                                 help: "Flip Vertical", isActive: model.recipe.flipVertical) { model.flip(horizontal: false) }
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(EditorFormatting.pixels(model.croppedSize), systemImage: "crop")
                    .monospacedDigit()
                Spacer()
                Button("Reset", action: model.resetGeometry)
                    .disabled(!model.hasGeometryEdits)
            }
            .font(.callout)
            Text("Drag the corners or edges on the image, or drag inside the frame to move it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Adjust

struct EditorAdjustSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Adjust", resetEnabled: model.hasColorEdits || model.recipe.autoEnhance,
                              onReset: model.resetAdjustments)
            Toggle(isOn: Binding(get: { model.recipe.autoEnhance }, set: { v in model.change { $0.autoEnhance = v } })) {
                Label("Auto Enhance", systemImage: "wand.and.stars")
            }
            .toggleStyle(.switch)
        }

        group("Light", [
            ("Exposure", \.exposure), ("Brightness", \.brightness), ("Contrast", \.contrast),
            ("Highlights", \.highlights), ("Shadows", \.shadows),
        ])
        group("Color", [
            ("Saturation", \.saturation), ("Vibrance", \.vibrance), ("Temperature", \.temperature), ("Tint", \.tint),
        ])
        group("Detail", [("Sharpness", \.sharpness), ("Vignette", \.vignette)], range: 0...1)
    }

    private func group(_ title: String, _ items: [(String, WritableKeyPath<EditRecipe, Double>)],
                       range: ClosedRange<Double> = -1...1) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorGroupHeader(title: title)
            ForEach(items, id: \.0) { name, keyPath in
                EditorSlider(title: name,
                             value: Binding(get: { model.recipe[keyPath: keyPath] },
                                            set: { v in model.update { $0[keyPath: keyPath] = v } }),
                             range: range,
                             format: { range.lowerBound < 0 ? EditorFormatting.signedValue($0) : "\(Int(($0 * 100).rounded()))" },
                             onEditingChanged: { if !$0 { model.endContinuousEdit() } },
                             onReset: { model.change { $0[keyPath: keyPath] = 0 } })
            }
        }
    }
}

// MARK: - Filters

struct EditorFiltersSection: View {
    @ObservedObject var model: EditorModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Filters", resetEnabled: model.recipe.filter != .none) {
                model.change { $0.filter = .none }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(FilterPreset.allCases, id: \.self) { preset in
                    let selected = model.recipe.filter == preset
                    Button {
                        model.change { $0.filter = preset }
                    } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                                if let thumbnail = model.filterThumbnails[preset] {
                                    Image(decorative: thumbnail, scale: 1)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    ProgressView().controlSize(.small)
                                }
                            }
                            .frame(width: 78, height: 78)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(selected ? EditorStyle.accent : Color.clear, lineWidth: 2.5)
                            )
                            Text(preset.title)
                                .font(.caption.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? EditorStyle.accent : Color.primary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Background

struct EditorBackgroundSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Remove Background")
            Toggle(isOn: Binding(get: { model.recipe.removeBackground || model.cutoutStatus == .working },
                                 set: { model.setRemoveBackground($0) })) {
                Label("Remove background", systemImage: "person.crop.rectangle")
            }
            .toggleStyle(.switch)
            .disabled(!RecipeRenderer.canRemoveBackground || model.cutoutStatus == .working)

            switch model.cutoutStatus {
            case .working:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finding the subject…").foregroundStyle(.secondary)
                }
                .font(.callout)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            case .idle:
                Text(RecipeRenderer.canRemoveBackground
                     ? "Lifts the main subject on-device with Vision. Nothing is uploaded."
                     : "Background removal requires macOS 14 or later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Fill")
            HStack(spacing: 6) {
                ForEach(EditorFill.allCases) { fill in
                    EditorChip(title: fill.title, isSelected: model.fill == fill) { model.setFill(fill) }
                }
            }
            if model.fill == .custom {
                ColorPicker("Fill color", selection: Binding(get: { model.customFill }, set: { model.setCustomFill($0) }),
                            supportsOpacity: false)
            }
            Text("PNG, HEIC, WebP, AVIF and TIFF keep transparency.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!model.recipe.removeBackground)
        .opacity(model.recipe.removeBackground ? 1 : 0.5)
    }
}

// MARK: - Resize

struct EditorResizeSection: View {
    @ObservedObject var model: EditorModel

    private var enabled: Bool { model.recipe.outputSize != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            EditorGroupHeader(title: "Resize")
            Toggle(isOn: Binding(get: { enabled }, set: { model.setResizeEnabled($0) })) {
                Label("Resize image", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .toggleStyle(.switch)
        }

        VStack(alignment: .leading, spacing: 12) {
            Picker("Unit", selection: $model.resizeUnit) {
                ForEach(EditorResizeUnit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.resizeUnit == .pixels {
                HStack(spacing: 6) {
                    numberField("Width", value: model.finalSize.width) { model.setOutputWidth($0) }
                    Button {
                        model.resizeLocked.toggle()
                    } label: {
                        Image(systemName: model.resizeLocked ? "lock.fill" : "lock.open")
                            .foregroundStyle(model.resizeLocked ? EditorStyle.accent : Color.secondary)
                            .frame(width: 22)
                    }
                    .buttonStyle(.borderless)
                    .help(model.resizeLocked ? "Aspect ratio locked" : "Aspect ratio unlocked")
                    numberField("Height", value: model.finalSize.height) { model.setOutputHeight($0) }
                }
            } else {
                HStack(spacing: 8) {
                    numberField("Scale", value: model.scalePercent) { model.setScalePercent($0) }
                    Text("%").foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                EditorChip(title: "25%", isSelected: false) { model.setScalePercent(25) }
                EditorChip(title: "50%", isSelected: false) { model.setScalePercent(50) }
                EditorChip(title: "2048", isSelected: false) { model.fitLongestEdge(2048) }
                EditorChip(title: "1080", isSelected: false) { model.fitLongestEdge(1080) }
            }
            .help("Quick sizes (longest edge for 2048 and 1080)")
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)

        VStack(alignment: .leading, spacing: 4) {
            row("Original", EditorFormatting.pixels(model.sourceSize))
            if model.recipe.crop != nil { row("Cropped", EditorFormatting.pixels(model.croppedSize)) }
            row("Final", EditorFormatting.pixels(model.finalSize)).fontWeight(.semibold)
        }
        .font(.callout)
        .monospacedDigit()
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private func numberField(_ title: String, value: CGFloat, commit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField(title, value: Binding(get: { Double(value) }, set: { commit($0) }),
                      format: .number.precision(.fractionLength(0)).grouping(.never))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Export

struct EditorExportPanel: View {
    @ObservedObject var model: EditorModel
    @State private var confirmOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Format")
                Spacer()
                Picker("Format", selection: $model.exportFormat) {
                    ForEach(model.exportFormats, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 120)
            }

            if EditorModel.isLossy(model.exportFormat) {
                HStack(spacing: 8) {
                    Text("Quality")
                    Slider(value: $model.quality, in: 0.3...1)
                    Text("\(Int((model.quality * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }

            Toggle("Strip metadata (EXIF, GPS)", isOn: $model.stripMetadata)
                .toggleStyle(.checkbox)

            HStack(spacing: 6) {
                Text(EditorFormatting.pixels(model.finalSize))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                estimateLabel
            }
            .font(.callout)

            if let warning = model.transparencyWarning {
                Label(warning, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Overwrite…") { confirmOverwrite = true }
                    .disabled(!model.canOverwrite || !model.isDirty || model.isSaving || !model.isFullResolutionReady)
                    .help(model.canOverwrite ? "Replace the original \(model.sourceFormat.displayName) file"
                        : "This file can't be overwritten; use Save as Copy")
                Spacer()
                if model.isSaving { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.saveCopy() }
                } label: {
                    Text("Save as Copy").frame(minWidth: 96)
                }
                .buttonStyle(.borderedProminent)
                .tint(EditorStyle.accent)
                .disabled(model.isSaving || !model.isFullResolutionReady)
                .help("Save “\(FileFormat.baseName(of: model.url)) edited.\(model.exportFormat.fileExtension)” next to the original (⌘S)")
            }
            .controlSize(.large)
        }
        .alert("Overwrite “\(model.url.lastPathComponent)”?", isPresented: $confirmOverwrite) {
            Button("Overwrite", role: .destructive) { Task { await model.overwrite() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The original will be replaced with the edited image as \(model.sourceFormat.displayName). This can't be undone.")
        }
    }

    @ViewBuilder private var estimateLabel: some View {
        switch model.estimate {
        case .unknown:
            Text(model.isFullResolutionReady ? "—" : "Loading full resolution…").foregroundStyle(.secondary)
        case .working:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Estimating…").foregroundStyle(.secondary)
            }
        case let .bytes(bytes):
            Text(EditorFormatting.estimate(bytes: bytes)).fontWeight(.semibold).monospacedDigit()
        case .failed:
            Text("Size unavailable").foregroundStyle(.secondary)
        }
    }
}

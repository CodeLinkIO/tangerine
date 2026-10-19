import SwiftUI
import TangerineKit

/// Root view of the editor window: toolbar + canvas on the left, inspector on the right.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                EditorTopBar(model: model)
                Divider()
                canvas
            }
            Divider()
            EditorInspector(model: model)
        }
        .frame(minWidth: 800, minHeight: 560)
        .tint(EditorStyle.accent)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var canvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)
            if let error = model.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 34))
                        .foregroundStyle(.secondary)
                    Text("Couldn't open this image").font(.headline)
                    Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(40)
            } else if model.isLoading || model.previewImage == nil {
                ProgressView("Opening \(model.url.lastPathComponent)…")
            } else {
                let showsOriginal = model.isComparing && model.originalImage != nil
                EditorCanvas(
                    image: showsOriginal ? model.originalImage : model.previewImage,
                    showsCrop: model.section == .crop && model.previewIsUncropped && !showsOriginal,
                    crop: model.cropRect,
                    cropRatio: model.normalizedCropRatio,
                    zoom: model.zoom,
                    pan: model.pan,
                    onCropChange: { rect, ended in model.updateCrop(rect, ended: ended) },
                    onPanChange: { model.pan = $0 },
                    onZoomChange: { model.zoom = $0 }
                )
                if showsOriginal {
                    VStack {
                        Text("Original")
                            .font(.callout.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 14)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .clipped()
    }
}

struct EditorTopBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 6) {
            Group {
                Button(action: model.undo) { Image(systemName: "arrow.uturn.backward") }
                    .help("Undo (⌘Z)")
                    .disabled(!model.canUndo)
                Button(action: model.redo) { Image(systemName: "arrow.uturn.forward") }
                    .help("Redo (⇧⌘Z)")
                    .disabled(!model.canRedo)
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 24)

            Button("Reset All", action: model.resetAll)
                .disabled(model.recipe.isIdentity)
                .controlSize(.small)

            Spacer(minLength: 12)

            Text(sizeSummary)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 12)

            compareButton

            Divider().frame(height: 18)

            Group {
                Button(action: model.zoomOut) { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom Out (⌘−)")
                Button(action: model.zoomToFit) {
                    Text(model.zoom == 1 ? "Fit" : "\(Int((model.zoom * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(minWidth: 42)
                }
                .help("Zoom to Fit (⌘0)")
                Button(action: model.zoomIn) { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom In (⌘+)")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(model.isLoading || model.loadError != nil)
    }

    private var sizeSummary: String {
        guard model.sourceSize != .zero else { return "" }
        let source = EditorFormatting.pixels(model.sourceSize)
        let final = model.finalSize
        return final == model.sourceSize ? source : "\(source)  →  \(EditorFormatting.pixels(final))"
    }

    /// Press and hold to see the original (Space does the same).
    private var compareButton: some View {
        Label("Compare", systemImage: "square.split.2x1")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.isComparing ? EditorStyle.accent.opacity(0.2) : Color.primary.opacity(0.06))
            )
            .foregroundStyle(model.isComparing ? EditorStyle.accent : Color.primary)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 60, maximumDistance: 400, perform: {},
                                onPressingChanged: { model.isComparing = $0 })
            .help("Hold to compare with the original (or hold Space)")
            .accessibilityAddTraits(.isButton)
    }
}

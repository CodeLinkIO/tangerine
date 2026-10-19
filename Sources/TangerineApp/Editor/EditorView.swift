import SwiftUI
import TangerineKit

/// Root view of the editor window: title bar, the image card, and one card of controls.
struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(spacing: 14) {
            EditorTopBar(model: model)
            canvasCard
            EditorControls(model: model)
                .disabled(model.isLoading || model.loadError != nil)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(minWidth: 760, minHeight: 560)
        .background(Theme.page)
        // Draw into the transparent title bar so the file name lines up with the traffic lights.
        .ignoresSafeArea(.container, edges: .top)
        .tint(Theme.orange)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil },
                                                            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var canvasCard: some View {
        ZStack {
            if let error = model.loadError {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark").font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.muted)
                    Text("Couldn't open this image").font(Theme.label(15, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(error).font(Theme.label(12.5, weight: .regular)).foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .padding(40)
            } else if model.isLoading || model.previewImage == nil {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening \(model.url.lastPathComponent)…").font(Theme.label(12.5)).foregroundStyle(Theme.muted)
                }
            } else {
                let showsOriginal = model.isComparing && model.originalImage != nil
                EditorCanvas(
                    image: showsOriginal ? model.originalImage : model.previewImage,
                    showsCrop: model.tool == .crop && model.previewIsUncropped && !showsOriginal,
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
                            .font(Theme.label(12, weight: .semibold))
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 26)
                            .background(Capsule().fill(Theme.card))
                            .overlay(Capsule().strokeBorder(Theme.line))
                            .padding(.top, 12)
                        Spacer()
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.035), radius: 18, y: 8)
    }
}

/// Sits in the transparent title bar: file name in the middle, undo/redo on the right.
struct EditorTopBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: 120, height: 1)   // room for the traffic lights, keeps the title centered
            Spacer(minLength: 8)
            HStack(spacing: 7) {
                Text(model.url.lastPathComponent)
                    .font(Theme.label(13.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if model.isDirty {
                    Circle().fill(Theme.orange).frame(width: 6, height: 6).help("Unsaved changes")
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                IconButton(systemImage: "arrow.uturn.backward", help: "Undo (⌘Z)", action: model.undo)
                    .disabled(!model.canUndo)
                IconButton(systemImage: "arrow.uturn.forward", help: "Redo (⇧⌘Z)", action: model.redo)
                    .disabled(!model.canRedo)
            }
            .frame(width: 120, alignment: .trailing)
        }
        .frame(height: 30)
        .padding(.top, 1)
    }
}

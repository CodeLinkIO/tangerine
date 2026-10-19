import AppKit
import SwiftUI
import TangerineKit

/// State of one progress toast.
@MainActor
final class HUDModel: ObservableObject, Identifiable {
    enum State: Equatable { case working, success, failure, info }

    let id = UUID()
    @Published var title: String
    @Published var detail: String
    @Published var state: State = .working
    @Published var progress: Double = 0
    @Published var outputs: [URL] = []
    var onCancel: (() -> Void)?
    fileprivate var onDismiss: (() -> Void)?

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    func finish(_ state: State, title: String, detail: String = "", outputs: [URL] = []) {
        self.state = state
        self.title = title
        self.detail = detail
        self.outputs = outputs
        progress = 1
        let delay: Double = state == .failure ? 8 : 4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.dismiss() }
    }

    func dismiss() { onDismiss?() }

    func reveal() {
        guard !outputs.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(outputs)
        dismiss()
    }
}

/// Stack of toasts at the bottom of the active screen.
@MainActor
final class HUDController {
    static let shared = HUDController()

    private var panels: [(HUDModel, NSPanel)] = []
    private static let size = CGSize(width: 360, height: 64)

    @discardableResult
    func present(title: String, detail: String) -> HUDModel {
        let model = HUDModel(title: title, detail: detail)
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = CGRect(origin: .zero, size: Self.size)
        panel.contentView = host
        model.onDismiss = { [weak self, weak model] in
            guard let self, let model else { return }
            self.remove(model)
        }
        panels.append((model, panel))
        layout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
        return model
    }

    private func remove(_ model: HUDModel) {
        guard let index = panels.firstIndex(where: { $0.0 === model }) else { return }
        let panel = panels.remove(at: index).1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
        layout()
    }

    private func layout() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        for (offset, (_, panel)) in panels.enumerated() {
            let origin = CGPoint(x: visible.midX - Self.size.width / 2,
                                 y: visible.minY + 72 + CGFloat(offset) * (Self.size.height + 10))
            panel.setFrame(CGRect(origin: origin, size: Self.size), display: true, animate: panel.isVisible)
        }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 5) {
                Text(model.title).font(Theme.label(13, weight: .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if model.state == .working {
                    ProgressView(value: model.progress).progressViewStyle(.linear).tint(Theme.orange)
                } else if !model.detail.isEmpty {
                    Text(model.detail).font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            if model.state == .working, model.onCancel != nil {
                IconButton(systemImage: "xmark", help: "Cancel", size: 24) { model.onCancel?() }
            } else if !model.outputs.isEmpty {
                Button("Show") { model.reveal() }
                    .buttonStyle(.plain).font(Theme.label(12.5, weight: .semibold)).foregroundStyle(Theme.orange)
            } else {
                IconButton(systemImage: "xmark", size: 24) { model.dismiss() }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: 360, height: 64)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal() }
    }

    @ViewBuilder private var leading: some View {
        switch model.state {
        case .working:
            ProgressView().controlSize(.small)
        case .success:
            if let file = model.outputs.first {
                FileThumbnail(url: file, size: 36)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(.white, Theme.orange)
                            .offset(x: 4, y: 4)
                    }
            } else {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.orange)
            }
        case .failure:
            Image(systemName: "exclamationmark.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.orange)
        case .info:
            Image(systemName: "info.circle.fill").font(.system(size: 24)).foregroundStyle(Theme.faint)
        }
    }
}

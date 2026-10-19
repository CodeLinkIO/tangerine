import AppKit
import SwiftUI
import TangerineKit
import UniformTypeIdentifiers

@MainActor
final class ConverterWindowController: NSWindowController {
    static let shared = ConverterWindowController()

    let model = ConverterModel()

    private init() {
        let window = NSWindow.themed(size: CGSize(width: 820, height: 600), title: "Convert")
        window.minSize = CGSize(width: 640, height: 460)
        window.setFrameAutosaveName("ConverterWindow")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ConverterView(model: model))
        if window.frame.origin == .zero { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(adding files: [URL] = []) {
        model.add(files)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ConverterView: View {
    @ObservedObject var model: ConverterModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.items.isEmpty {
                ConverterEmptyState { choose() }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        if model.items.count > 1, !model.allTargets.isEmpty { convertAllCard }
                        ForEach(model.items) { item in
                            ConverterFileCard(item: item, featured: model.featuredTargets(for: item),
                                              onTarget: { model.setTarget($0, for: item.id) },
                                              onRemove: { model.remove([item.id]) })
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
                }
            }
            footer
        }
        .background(Theme.page)
        .frame(minWidth: 640, minHeight: 460)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in model.add(await Self.urls(from: providers)) }
            return true
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.orange, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Convert").font(Theme.title(26)).tracking(-0.8).foregroundStyle(Theme.text)
                Text("Drop files here. Everything stays on your Mac.").font(Theme.label(13, weight: .regular))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            if !model.items.isEmpty {
                Button { choose() } label: { Label("Add Files", systemImage: "plus") }.buttonStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 34)
        .padding(.bottom, 14)
    }

    private var convertAllCard: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Convert all to")
                ChipFlow(spacing: 6) {
                    ForEach(model.allTargets.prefix(10), id: \.self) { target in
                        let allSet = model.items.filter { $0.targets.contains(target) }.allSatisfy { $0.target == target }
                        Chip(title: target.shortName, isSelected: allSet) { model.setTargetForAll(target) }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("Quality").font(Theme.label(12.5)).foregroundStyle(Theme.muted)
                Segmented(options: QualityPreset.allCases, selection: $model.quality) { $0.title }
            }
            Menu {
                Button("Next to Originals") { model.outputFolder = nil }
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label(model.outputFolder?.lastPathComponent ?? "Next to originals", systemImage: "folder")
                    .font(Theme.label(12.5))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.muted)
            Spacer()
            if model.items.contains(where: \.isDone), !model.isRunning {
                Button("Clear Done") { model.clearFinished() }.buttonStyle(.secondary)
            }
            if model.isRunning {
                Button("Stop") { model.cancel() }.buttonStyle(.secondary)
            } else {
                Button(model.pendingCount > 1 ? "Convert \(model.pendingCount) files" : "Convert") { model.convertAll() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.pendingCount == 0)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Theme.page)
        .overlay(alignment: .top) { Hairline() }
    }

    // MARK: Actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { model.add(panel.urls) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { model.outputFolder = panel.url }
    }

    static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}

struct ConverterEmptyState: View {
    let onChoose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: TangerineArt.appIcon(size: 84)).resizable().frame(width: 84, height: 84)
            Text("Drop files to convert").font(Theme.title(22)).tracking(-0.6).foregroundStyle(Theme.text)
            Text("Images, video, audio, PDFs and documents").font(Theme.label(13, weight: .regular))
                .foregroundStyle(Theme.muted)
            Button("Choose Files…", action: onChoose).buttonStyle(.secondary).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Theme.line, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .padding(.horizontal, 28)
        .padding(.bottom, 18)
    }
}

struct ConverterFileCard: View {
    let item: ConverterModel.Item
    let featured: [FileFormat]
    let onTarget: (FileFormat) -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    FileThumbnail(url: item.url, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.url.lastPathComponent).font(Theme.label(13.5)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(item.format.displayName) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                            .font(Theme.label(11.5, weight: .regular)).foregroundStyle(Theme.muted)
                    }
                    Spacer(minLength: 8)
                    status
                    IconButton(systemImage: "xmark", help: "Remove", size: 24, action: onRemove)
                        .opacity(hovering ? 1 : 0)
                }
                if item.targets.isEmpty {
                    Text("No conversions for this file").font(Theme.label(12, weight: .regular)).foregroundStyle(Theme.muted)
                } else {
                    ChipFlow(spacing: 6) {
                        ForEach(featured, id: \.self) { target in
                            Chip(title: target.shortName, isSelected: item.target == target) { onTarget(target) }
                        }
                        let others = item.targets.filter { !featured.contains($0) }
                        if !others.isEmpty {
                            Menu {
                                ForEach(others, id: \.self) { target in Button(target.displayName) { onTarget(target) } }
                            } label: {
                                Text("More").font(Theme.rounded(12.5)).foregroundStyle(Theme.text)
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.visible)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .background(Capsule().fill(Theme.subtle))
                        }
                    }
                }
                if case let .working(progress) = item.status {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.orange)
                }
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .ready, .working:
            EmptyView()
        case let .done(outputs, summary):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.orange)
                Text(summary).font(Theme.label(12)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                if !outputs.isEmpty {
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
                        .buttonStyle(.plain).font(Theme.label(12, weight: .semibold)).foregroundStyle(Theme.orange)
                }
            }
            .frame(maxWidth: 300, alignment: .trailing)
        case let .failed(message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.orange)
                Text(message).font(Theme.label(12, weight: .regular)).foregroundStyle(Theme.muted).lineLimit(2)
            }
            .frame(maxWidth: 300, alignment: .trailing)
            .help(message)
        }
    }
}

extension ConverterModel.Item {
    var isDone: Bool { if case .done = status { true } else { false } }
}

/// Wrapping row of chips.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct FlowRow { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [FlowRow] {
        var rows = [FlowRow()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(FlowRow(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

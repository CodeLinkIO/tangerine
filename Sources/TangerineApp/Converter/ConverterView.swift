import AppKit
import SwiftUI
import TangerineKit
import UniformTypeIdentifiers

@MainActor
final class ConverterWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ConverterWindowController()

    let model = ConverterModel()

    private init() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 520),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Converter"
        window.minSize = CGSize(width: 620, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ConverterWindow")
        super.init(window: window)
        window.contentView = NSHostingView(rootView: ConverterView(model: model))
        window.delegate = self
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
    @State private var showOptions = false
    private let orange = Color(red: 0xF3 / 255, green: 0x5B / 255, blue: 0x28 / 255)

    var body: some View {
        VStack(spacing: 0) {
            if model.items.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 380)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            Task { @MainActor in model.add(await Self.urls(from: providers)) }
            return true
        }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12).strokeBorder(orange, lineWidth: 3).padding(6).allowsHitTesting(false)
            }
        }
    }

    // MARK: Sections

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.doc").font(.system(size: 46, weight: .light)).foregroundStyle(orange)
            Text("Drop files or folders to convert").font(.title3.weight(.semibold))
            Text("Images, video, audio, PDFs and documents. Everything stays on your Mac.")
                .foregroundStyle(.secondary)
            Button("Choose Files…") { choose() }.controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 20)
    }

    private var list: some View {
        List(selection: $model.selection) {
            ForEach(model.items) { item in
                ConverterRow(item: item, orange: orange) { target in model.setTarget(target, for: item.id) }
                    .tag(item.id)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                        if item.format.category == .image {
                            Button("Edit Image…") { JobRunner.shared.openEditor(item.url) }
                        }
                        Divider()
                        Button("Remove") { model.remove(model.selection.contains(item.id) ? model.selection : [item.id]) }
                    }
            }
            .onDelete { offsets in model.remove(Set(offsets.map { model.items[$0].id })) }
        }
        .listStyle(.inset)
        .onDeleteCommand { model.remove(model.selection) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { choose() } label: { Image(systemName: "plus") }.help("Add files")
            Menu("Set all to") {
                ForEach(model.allTargets, id: \.self) { target in
                    Button(target.displayName) { model.setTargetForAll(target) }
                }
            }
            .fixedSize()
            .disabled(model.items.isEmpty)
            Menu("Tools") {
                ForEach(model.commonTools, id: \.self) { tool in
                    Button { model.runTool(tool) } label: { Label(tool.title, systemImage: tool.symbol) }
                }
            }
            .fixedSize()
            .disabled(model.items.isEmpty || model.commonTools.isEmpty || model.isRunning)
            Button { showOptions.toggle() } label: { Label("Options", systemImage: "slider.horizontal.3") }
                .popover(isPresented: $showOptions, arrowEdge: .top) {
                    OptionsForm(options: $model.options).frame(width: 380, height: 460)
                }
            Spacer()
            Menu {
                Button("Next to Originals") { model.outputFolder = nil }
                Button("Choose Folder…") { chooseFolder() }
            } label: {
                Label(model.outputFolder?.lastPathComponent ?? "Next to originals", systemImage: "folder")
            }
            .fixedSize()
            if model.isRunning {
                Button("Stop") { model.cancel() }
            } else {
                Button(model.items.contains(where: { if case .done = $0.status { true } else { false } }) ? "Clear Done" : "Clear") {
                    if model.items.contains(where: { if case .done = $0.status { true } else { false } }) {
                        model.clearFinished()
                    } else {
                        model.remove(Set(model.items.map(\.id)))
                    }
                }
                .disabled(model.items.isEmpty)
            }
            Button {
                model.convertAll()
            } label: {
                Text(model.pendingCount > 1 ? "Convert \(model.pendingCount)" : "Convert").frame(minWidth: 70)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(orange)
            .disabled(model.isRunning || model.pendingCount == 0)
        }
        .padding(12)
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

struct ConverterRow: View {
    let item: ConverterModel.Item
    let orange: Color
    let onTarget: (FileFormat) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                Text("\(item.format.displayName) · \(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            status.frame(width: 190, alignment: .trailing)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            if item.targets.isEmpty {
                Text("No conversions").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            } else {
                Picker("", selection: Binding(get: { item.target ?? item.targets[0] }, set: onTarget)) {
                    ForEach(item.targets, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var status: some View {
        switch item.status {
        case .ready:
            EmptyView()
        case let .working(progress):
            ProgressView(value: progress).tint(orange).frame(width: 120)
        case let .done(outputs, summary):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(orange)
                Text(summary).font(.caption).lineLimit(1).truncationMode(.middle)
                if !outputs.isEmpty {
                    Button { NSWorkspace.shared.activateFileViewerSelecting(outputs) } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
        case let .failed(message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(message).font(.caption).lineLimit(2).foregroundStyle(.secondary)
            }
            .help(message)
        }
    }
}

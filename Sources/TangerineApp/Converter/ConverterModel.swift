import AppKit
import TangerineKit

/// The Converter window's batch queue.
@MainActor
final class ConverterModel: ObservableObject {
    enum Status: Equatable {
        case ready
        case working(Double)
        case done(outputs: [URL], summary: String)
        case failed(String)
    }

    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let format: FileFormat
        let size: Int64
        let targets: [FileFormat]
        var target: FileFormat?
        var status: Status = .ready
    }

    @Published var items: [Item] = []
    @Published var selection = Set<Item.ID>()
    @Published var options: ConversionOptions
    @Published var outputFolder: URL?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    init() {
        options = Preferences.shared.options
        outputFolder = Preferences.shared.outputFolder
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        let engine = Engine.shared
        let known = Set(items.map(\.url))
        for url in engine.expand(urls) where !known.contains(url) {
            guard let format = FileFormat.detect(url) else { continue }
            let targets = engine.targets(from: format)
            // Default to the format chosen for siblings of the same kind, else the first option.
            let sibling = items.last { $0.format.category == format.category }?.target
            let target = sibling.flatMap { targets.contains($0) ? $0 : nil } ?? targets.first
            items.append(Item(url: url, format: format, size: url.fileSize, targets: targets, target: target))
        }
    }

    func remove(_ ids: Set<Item.ID>) {
        items.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    func clearFinished() {
        items.removeAll { if case .done = $0.status { true } else { false } }
    }

    func setTarget(_ target: FileFormat, for id: Item.ID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].target = target
        items[index].status = .ready
    }

    /// Applies `target` to every item (or the selection) that supports it.
    func setTargetForAll(_ target: FileFormat) {
        for index in items.indices where (selection.isEmpty || selection.contains(items[index].id))
            && items[index].targets.contains(target) {
            items[index].target = target
            items[index].status = .ready
        }
    }

    /// Every target at least one item supports, most common first.
    var allTargets: [FileFormat] {
        var counts: [FileFormat: Int] = [:]
        var order: [FileFormat] = []
        for item in items {
            for target in item.targets {
                if counts[target] == nil { order.append(target) }
                counts[target, default: 0] += 1
            }
        }
        return order.sorted { counts[$0]! > counts[$1]! }
    }

    /// Tools that apply to every item in scope.
    var commonTools: [ToolID] {
        Engine.shared.tools(for: scope.map(\.url)).filter { !$0.isInteractive }
    }

    private var scope: [Item] {
        selection.isEmpty ? items : items.filter { selection.contains($0.id) }
    }

    var pendingCount: Int {
        items.filter { item in
            guard item.target != nil else { return false }
            if case .ready = item.status { return true }
            if case .failed = item.status { return true }
            return false
        }.count
    }

    // MARK: Running

    func convertAll() {
        guard !isRunning else { return }
        isRunning = true
        let options = options
        let folder = outputFolder
        task = Task { @MainActor in
            for item in items {
                guard !Task.isCancelled else { break }
                guard let target = item.target else { continue }
                switch item.status {
                case .ready, .failed: break
                default: continue
                }
                let id = item.id
                update(id) { $0.status = .working(0) }
                do {
                    let report = try await Engine.shared.convert([item.url], to: target, options: options, outputDirectory: folder) { progress in
                        Task { @MainActor in
                            self.update(id) { item in
                                if case .working = item.status { item.status = .working(progress.fraction) }
                            }
                        }
                    }
                    finish(id, report: report)
                } catch {
                    update(id) { $0.status = .failed(error.localizedDescription) }
                }
            }
            isRunning = false
        }
    }

    func runTool(_ tool: ToolID) {
        guard !isRunning else { return }
        let targets = scope
        isRunning = true
        let options = options
        let folder = outputFolder
        task = Task { @MainActor in
            if tool.combinesInputs {
                targets.forEach { item in update(item.id) { $0.status = .working(0) } }
                do {
                    let report = try await Engine.shared.run(tool, on: targets.map(\.url), options: options, outputDirectory: folder)
                    targets.forEach { finish($0.id, report: report) }
                } catch {
                    targets.forEach { item in update(item.id) { $0.status = .failed(error.localizedDescription) } }
                }
            } else {
                for item in targets {
                    guard !Task.isCancelled else { break }
                    update(item.id) { $0.status = .working(0) }
                    do {
                        let report = try await Engine.shared.run(tool, on: [item.url], options: options, outputDirectory: folder)
                        finish(item.id, report: report)
                    } catch {
                        update(item.id) { $0.status = .failed(error.localizedDescription) }
                    }
                }
            }
            isRunning = false
        }
    }

    func cancel() {
        task?.cancel()
        for index in items.indices {
            if case .working = items[index].status { items[index].status = .ready }
        }
    }

    private func finish(_ id: Item.ID, report: JobReport) {
        Recents.shared.add(report.outputs)
        if let text = report.text {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if let failure = report.failures.first, report.outputs.isEmpty {
            update(id) { $0.status = .failed(failure.message) }
        } else {
            update(id) { $0.status = .done(outputs: report.outputs, summary: report.summary) }
        }
        if Preferences.shared.replaceOriginals, report.failures.isEmpty, !report.outputs.isEmpty,
           let item = items.first(where: { $0.id == id }), item.target != nil {
            NSWorkspace.shared.recycle([item.url])
        }
    }

    private func update(_ id: Item.ID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }
}

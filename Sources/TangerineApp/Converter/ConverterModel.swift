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
    @Published var quality: QualityPreset
    @Published var outputFolder: URL?
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    init() {
        quality = Preferences.shared.quality
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

    /// Targets shared by several items, in the dominant file type's natural order (JPG, PNG, HEIC…).
    var allTargets: [FileFormat] {
        var counts: [FileFormat: Int] = [:]
        var categories: [FormatCategory: Int] = [:]
        for item in items {
            categories[item.format.category, default: 0] += 1
            for target in item.targets { counts[target, default: 0] += 1 }
        }
        guard let dominant = categories.max(by: { $0.value < $1.value })?.key else { return [] }
        var ordered = TargetCatalog.orderedTargets(for: dominant)
        for category in FormatCategory.allCases where category != dominant {
            ordered += TargetCatalog.orderedTargets(for: category).filter { !ordered.contains($0) }
        }
        let minimum = items.count > 1 ? 2 : 1
        return ordered.filter { (counts[$0] ?? 0) >= minimum }
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

    /// The few formats shown as chips on a card; the rest live under "More".
    func featuredTargets(for item: Item) -> [FileFormat] {
        var featured = Array(Preferences.shared.wheelTargets(category: item.format.category, available: item.targets).prefix(5))
        if let target = item.target, !featured.contains(target) { featured.append(target) }
        return featured
    }

    func convertAll() {
        guard !isRunning else { return }
        isRunning = true
        let options = quality.apply(to: Preferences.shared.options)
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

import Foundation
@_exported import TangerineCore
import TangerineDocuments
@_exported import TangerineImage
import TangerineMedia

/// Progress for a whole job (several files).
public struct JobProgress: Sendable {
    public var completedFiles: Int
    public var totalFiles: Int
    /// Overall fraction, 0...1.
    public var fraction: Double
    public var currentFile: URL?
}

/// Outcome of a conversion or tool run across one or more files.
public struct JobReport: Sendable {
    public struct Failure: Sendable {
        public var file: URL
        public var message: String
    }

    public var outputs: [URL] = []
    public var failures: [Failure] = []
    public var notes: [String] = []
    /// Text produced by text tools (OCR); the app copies it to the clipboard.
    public var text: String?
    public var inputBytes: Int64 = 0
    public var outputBytes: Int64 = 0
    /// Whether the size change is meaningful (compression, same-family media conversions).
    public var comparesSize = false

    public var succeeded: Bool { failures.isEmpty && (!outputs.isEmpty || text != nil || !notes.isEmpty) }

    /// Size change as a signed percentage (negative = smaller), when outputs exist.
    public var sizeChangePercent: Int? {
        guard comparesSize, inputBytes > 0, outputBytes > 0 else { return nil }
        return Int((Double(outputBytes - inputBytes) / Double(inputBytes) * 100).rounded())
    }

    /// One-line summary for HUDs and the CLI.
    public var summary: String {
        if let failure = failures.first, outputs.isEmpty, text == nil {
            return failures.count == 1 ? failure.message : "\(failures.count) files failed: \(failure.message)"
        }
        if let text {
            return text.isEmpty ? (notes.first ?? "No text found") : "Copied \(text.count) characters"
        }
        if outputs.isEmpty { return notes.first ?? "Nothing to do" }
        var parts = [outputs.count == 1 ? "Saved \(outputs[0].lastPathComponent)" : "Saved \(outputs.count) files"]
        if let change = sizeChangePercent, change != 0 { parts.append(change > 0 ? "+\(change)%" : "\(change)%") }
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        return parts.joined(separator: " · ")
    }
}

/// Routes conversions and tools to the right engine, expands folders and handles batches.
public final class Engine: @unchecked Sendable {
    public static let shared = Engine()

    public let conversionBackends: [any ConversionBackend]
    public let toolBackends: [any ToolBackend]

    public init(conversionBackends: [any ConversionBackend] = ImageEngine.conversionBackends
                    + DocumentsEngine.conversionBackends + MediaEngine.conversionBackends,
                toolBackends: [any ToolBackend] = ImageEngine.toolBackends
                    + DocumentsEngine.toolBackends + MediaEngine.toolBackends) {
        self.conversionBackends = conversionBackends
        self.toolBackends = toolBackends
    }

    // MARK: Capabilities

    /// The first backend able to do `from → to`.
    public func backend(from: FileFormat, to: FileFormat) -> (any ConversionBackend)? {
        conversionBackends.first { $0.supports(from: from, to: to) }
    }

    /// Every supported target for one input format, in catalog order.
    public func targets(from format: FileFormat) -> [FileFormat] {
        TargetCatalog.orderedTargets(for: format.category).filter { $0 != format && backend(from: format, to: $0) != nil }
    }

    /// Targets every input supports (folders are expanded), in the first input's catalog order.
    /// Inputs already in the target format are skipped, so "PNG" is offered for a JPG + PNG selection.
    public func targets(for inputs: [URL]) -> [FileFormat] {
        let formats = Self.distinctFormats(expand(inputs, limit: Self.capabilitySampleSize))
        guard let first = formats.first else { return [] }
        let supported = formats.map { Set(targets(from: $0)) }
        var candidates = TargetCatalog.orderedTargets(for: first.category)
        for format in formats.dropFirst() {
            for target in TargetCatalog.orderedTargets(for: format.category) where !candidates.contains(target) {
                candidates.append(target)
            }
        }
        return candidates.filter { target in
            formats.contains { $0 != target }
                && zip(formats, supported).allSatisfy { format, targets in format == target || targets.contains(target) }
        }
    }

    /// Tools available for the selection, in catalog order.
    public func tools(for inputs: [URL]) -> [ToolID] {
        let files = expand(inputs, limit: Self.capabilitySampleSize)
        let formats = Self.distinctFormats(files)
        guard let first = formats.first else { return [] }
        var ordered: [ToolID] = []
        for tool in ToolID.orderedTools(for: first.category) where !ordered.contains(tool) {
            switch tool {
            case .openEditor:
                // The editor works on one still image at a time.
                if files.count == 1, first.category == .image { ordered.append(tool) }
            case .mergePDF:
                let mergeable = formats.allSatisfy { $0 == .pdf || $0.category == .image }
                if files.count > 1, mergeable, formats.allSatisfy({ toolBackend(tool, $0) != nil }) { ordered.append(tool) }
            default:
                if formats.allSatisfy({ toolBackend(tool, $0) != nil }) { ordered.append(tool) }
            }
        }
        return ordered
    }

    private func toolBackend(_ tool: ToolID, _ format: FileFormat) -> (any ToolBackend)? {
        toolBackends.first { $0.supports(tool, format: format) }
    }

    // MARK: Inputs

    /// Capability checks (wheel contents) look at this many files at most, so huge folders open instantly.
    static let capabilitySampleSize = 500

    /// Files plus the supported files inside any folders (recursively, skipping hidden items and packages),
    /// stopping after `limit` files when given.
    public func expand(_ inputs: [URL], limit: Int? = nil) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in inputs {
            if let limit, result.count >= limit { break }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue, FileFormat.detect(url) == nil {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let item = enumerator?.nextObject() as? URL {
                    if FileFormat.detect(item) != nil { result.append(item) }
                    if let limit, result.count >= limit { break }
                }
            } else if FileFormat.detect(url) != nil {
                result.append(url)
            }
        }
        return result
    }

    static func distinctFormats(_ files: [URL]) -> [FileFormat] {
        var seen: [FileFormat] = []
        for format in files.compactMap(FileFormat.detect) where !seen.contains(format) { seen.append(format) }
        return seen
    }

    /// Where results for `input` go: the chosen folder, or next to the input when writable, else Downloads.
    public static func outputDirectory(for input: URL, preferred: URL?) -> URL {
        if let preferred { return preferred }
        let parent = input.deletingLastPathComponent()
        if FileManager.default.isWritableFile(atPath: parent.path) { return parent }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? parent
    }

    // MARK: Running

    /// Converts every input to `target`. Inputs that already are `target` are skipped.
    public func convert(_ inputs: [URL], to target: FileFormat, options: ConversionOptions = ConversionOptions(),
                        outputDirectory: URL? = nil,
                        progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> JobReport {
        let files = expand(inputs).filter { FileFormat.detect($0) != target }
        guard !files.isEmpty else { throw ConversionError.unsupported(from: nil, to: target.displayName) }
        let mediaCategories: Set<FormatCategory> = [.image, .audio, .video]
        let sameFamily = files.allSatisfy { FileFormat.detect($0)?.category == target.category } && mediaCategories.contains(target.category)
        var report = try await runEach(files, progress: progress) { file, context in
            guard let from = FileFormat.detect(file), let backend = self.backend(from: from, to: target) else {
                throw ConversionError.unsupported(from: FileFormat.detect(file), to: target.displayName)
            }
            let plan = OutputPlan(for: file, directory: Self.outputDirectory(for: file, preferred: outputDirectory))
            var context = context
            context.options = options
            return ToolOutput(files: try await backend.convert(file, from: from, to: target, output: plan, context: context))
        }
        report.comparesSize = sameFamily
        return report
    }

    /// Runs a one-shot tool on the inputs.
    public func run(_ tool: ToolID, on inputs: [URL], options: ConversionOptions = ConversionOptions(),
                    outputDirectory: URL? = nil,
                    progress: @escaping @Sendable (JobProgress) -> Void = { _ in }) async throws -> JobReport {
        let files = expand(inputs)
        guard let first = files.first, let firstFormat = FileFormat.detect(first) else {
            throw ConversionError.unsupported(from: nil, to: tool.title)
        }
        guard !tool.isInteractive else { throw ConversionError.failed("\(tool.title) opens in the app.") }

        if tool.combinesInputs {
            guard let backend = toolBackend(tool, firstFormat) else {
                throw ConversionError.unsupported(from: firstFormat, to: tool.title)
            }
            let plan = OutputPlan(for: first, directory: Self.outputDirectory(for: first, preferred: outputDirectory))
            let context = ConversionContext(options: options) { fraction in
                progress(JobProgress(completedFiles: 0, totalFiles: 1, fraction: fraction, currentFile: first))
            }
            let output = try await backend.run(tool, inputs: files, output: plan, context: context)
            var report = JobReport()
            report.outputs = output.files
            report.text = output.text
            report.notes = output.note.map { [$0] } ?? []
            report.inputBytes = files.reduce(0) { $0 + $1.fileSize }
            report.outputBytes = output.files.reduce(0) { $0 + $1.fileSize }
            return report
        }

        var report = try await runEach(files, progress: progress) { file, context in
            guard let format = FileFormat.detect(file), let backend = self.toolBackend(tool, format) else {
                throw ConversionError.unsupported(from: FileFormat.detect(file), to: tool.title)
            }
            let plan = OutputPlan(for: file, directory: Self.outputDirectory(for: file, preferred: outputDirectory))
            var context = context
            context.options = options
            return try await backend.run(tool, inputs: [file], output: plan, context: context)
        }
        report.comparesSize = [.compress, .resizeHalf, .resizeLong2048, .resizeLong1080, .stripMetadata].contains(tool)
        return report
    }

    /// Runs `work` for each file (a few at a time for small files), collecting results and failures.
    private func runEach(_ files: [URL], progress: @escaping @Sendable (JobProgress) -> Void,
                         work: @escaping @Sendable (URL, ConversionContext) async throws -> ToolOutput) async throws -> JobReport {
        let total = files.count
        let tracker = ProgressTracker(total: total, report: progress)
        // Video and documents are heavy; images and audio can run a few in parallel.
        let heavy = files.contains { [.video, .pdf, .document].contains(FileFormat.detect($0)?.category) }
        let width = heavy ? 1 : min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

        var results = [(Int, Result<ToolOutput, Error>)]()
        try await withThrowingTaskGroup(of: (Int, Result<ToolOutput, Error>).self) { group in
            var next = 0
            func enqueue() {
                guard next < files.count else { return }
                let index = next
                next += 1
                let file = files[index]
                group.addTask {
                    let context = ConversionContext { fraction in tracker.update(index: index, fraction: fraction, file: file) }
                    do {
                        let output = try await work(file, context)
                        tracker.finish(index: index, file: file)
                        return (index, .success(output))
                    } catch {
                        tracker.finish(index: index, file: file)
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<width { enqueue() }
            while let result = try await group.next() {
                try Task.checkCancellation()
                results.append(result)
                enqueue()
            }
        }

        var report = JobReport()
        for (index, result) in results.sorted(by: { $0.0 < $1.0 }) {
            let file = files[index]
            switch result {
            case let .success(output):
                report.outputs += output.files
                if let note = output.note { report.notes.append(note) }
                if let text = output.text { report.text = [report.text, text].compactMap { $0 }.joined(separator: "\n\n") }
                if !output.files.isEmpty { report.inputBytes += file.fileSize }
            case let .failure(error):
                if error is CancellationError || (error as? ConversionError).map({ if case .cancelled = $0 { true } else { false } }) == true {
                    throw ConversionError.cancelled
                }
                report.failures.append(.init(file: file, message: error.localizedDescription))
            }
        }
        report.outputBytes = report.outputs.reduce(0) { $0 + $1.fileSize }
        return report
    }
}

/// Aggregates per-file progress into an overall fraction.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Int: Double] = [:]
    private var completed = 0
    private let total: Int
    private let report: @Sendable (JobProgress) -> Void

    init(total: Int, report: @escaping @Sendable (JobProgress) -> Void) {
        self.total = total
        self.report = report
    }

    func update(index: Int, fraction: Double, file: URL) {
        lock.lock()
        fractions[index] = min(max(fraction, 0), 1)
        let snapshot = JobProgress(completedFiles: completed, totalFiles: total, fraction: overall, currentFile: file)
        lock.unlock()
        report(snapshot)
    }

    func finish(index: Int, file: URL) {
        lock.lock()
        fractions[index] = 1
        completed += 1
        let snapshot = JobProgress(completedFiles: completed, totalFiles: total, fraction: overall, currentFile: file)
        lock.unlock()
        report(snapshot)
    }

    private var overall: Double {
        fractions.values.reduce(0, +) / Double(max(total, 1))
    }
}

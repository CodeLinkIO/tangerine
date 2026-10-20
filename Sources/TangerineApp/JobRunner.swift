import AppKit
import TangerineKit

/// Runs what the user picked on the wheel (or elsewhere) and reports through the HUD.
@MainActor
final class JobRunner {
    static let shared = JobRunner()

    func perform(_ item: WheelItem, on files: [URL]) {
        guard !files.isEmpty else { return }
        switch item {
        case .more:
            ConverterWindowController.shared.show(adding: files)
        case .tool(.openEditor):
            openEditor(files[0])
        case let .tool(tool):
            run(title: "\(tool.title)…", files: files, conversionTarget: nil) { options, folder, progress in
                try await Engine.shared.run(tool, on: files, options: options, outputDirectory: folder, progress: progress)
            }
        case let .convert(format):
            run(title: "Converting to \(format.displayName)…", files: files, conversionTarget: format) { options, folder, progress in
                try await Engine.shared.convert(files, to: format, options: options, outputDirectory: folder, progress: progress)
            }
        }
    }

    func openEditor(_ url: URL) {
        guard let format = FileFormat.detect(url), format.category == .image else {
            HUDController.shared.present(title: "Only images can be edited", detail: url.lastPathComponent)
                .finish(.info, title: "Only images can be edited", detail: url.lastPathComponent)
            return
        }
        EditorWindowController.open(url, options: Preferences.shared.effectiveOptions) { saved in
            Recents.shared.add([saved])
            HUDController.shared.present(title: "Saved", detail: "")
                .finish(.success, title: "Saved \(saved.lastPathComponent)", outputs: [saved])
        }
    }

    typealias Work = (ConversionOptions, URL?, @escaping @Sendable (JobProgress) -> Void) async throws -> JobReport

    private func run(title: String, files: [URL], conversionTarget: FileFormat?, work: @escaping Work) {
        let prefs = Preferences.shared
        let hud = HUDController.shared.present(title: title, detail: WheelController.summary(of: files))
        let options = prefs.effectiveOptions
        let folder = prefs.outputFolder

        let task = Task { @MainActor in
            do {
                let report = try await work(options, folder) { progress in
                    Task { @MainActor in hud.progress = progress.fraction }
                }
                self.finish(report, hud: hud, files: files, conversionTarget: conversionTarget)
            } catch ConversionError.cancelled {
                hud.finish(.info, title: "Cancelled")
            } catch is CancellationError {
                hud.finish(.info, title: "Cancelled")
            } catch {
                hud.finish(.failure, title: "Couldn't finish", detail: error.localizedDescription)
            }
        }
        hud.onCancel = { task.cancel() }
    }

    private func finish(_ report: JobReport, hud: HUDModel, files: [URL], conversionTarget: FileFormat?) {
        let prefs = Preferences.shared
        if let text = report.text, !text.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        Recents.shared.add(report.outputs)

        // Only inputs the engine actually converted, each with its own output; never re-scan the folders,
        // which now also hold the outputs (e.g. ALAC writes .m4a) and files added during the job.
        if conversionTarget != nil, prefs.replaceOriginals {
            let originals = report.replaceableOriginals
            if !originals.isEmpty { NSWorkspace.shared.recycle(originals) }
        }
        if prefs.revealInFinder, !report.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(report.outputs)
        }

        if !report.failures.isEmpty, report.outputs.isEmpty {
            hud.finish(.failure, title: "Couldn't finish", detail: report.summary)
        } else if report.outputs.isEmpty, report.text == nil {
            hud.finish(.info, title: report.summary)
        } else {
            let detail = report.failures.isEmpty ? "" : "\(report.failures.count) failed: \(report.failures[0].message)"
            hud.finish(.success, title: report.summary, detail: detail, outputs: report.outputs)
        }
    }
}

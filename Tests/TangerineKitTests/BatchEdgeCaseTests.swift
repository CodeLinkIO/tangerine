import CoreGraphics
import Foundation
@testable import TangerineKit
import XCTest

/// Batches: parallel naming races, progress, failures, cancellation and multi-file tools.
final class BatchEdgeCaseTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var fx: KitFixtures!

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        fx = KitFixtures(temp)
    }

    override func tearDown() { temp = nil }

    private func fakeEngine(_ configure: (FakeConversionBackend) -> Void = { _ in }) -> (Engine, FakeConversionBackend) {
        let fake = FakeConversionBackend()
        configure(fake)
        return (Engine(conversionBackends: [fake], toolBackends: []), fake)
    }

    /// `count` files called photo.png in separate folders.
    private func sameNamedInputs(_ count: Int, real: Bool = false) throws -> [URL] {
        try (1...count).map { real ? try fx.image("in\($0)/photo.png") : try fx.dummy("in\($0)/photo.png") }
    }

    // MARK: Naming under parallelism

    func testParallelFilesWithTheSameNameNeverOverwriteEachOther() async throws {
        let (engine, fake) = fakeEngine { $0.delayNanoseconds = 60_000_000 }
        let inputs = try sameNamedInputs(8)
        let out = try fx.folder("out")
        let report = try await engine.convert(inputs, to: .jpg, outputDirectory: out)

        XCTAssertGreaterThan(fake.running.value.peak, 1, "the batch should actually run in parallel")
        XCTAssertEqual(report.failures.map(\.message), [])
        XCTAssertEqual(Set(report.outputs).count, 8, "every input gets its own output: \(KitFixtures.names(report.outputs))")
        XCTAssertEqual(Set(KitFixtures.names(report.outputs)),
                       Set(["photo.jpg"] + (2...8).map { "photo \($0).jpg" }))
        let written = try report.outputs.map { try String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(Set(written), Set(inputs.map(\.path)), "no output was overwritten by another input")
    }

    func testConcurrentJobsIntoTheSameFolderDontCollide() async throws {
        let (engine, _) = fakeEngine { $0.delayNanoseconds = 60_000_000 }
        let inputs = try sameNamedInputs(4)
        let out = try fx.folder("out")
        async let first = engine.convert(Array(inputs.prefix(2)), to: .jpg, outputDirectory: out)
        async let second = engine.convert(Array(inputs.suffix(2)), to: .jpg, outputDirectory: out)
        let outputs = try await first.outputs + second.outputs
        XCTAssertEqual(Set(outputs).count, 4, KitFixtures.names(outputs).joined(separator: ", "))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 4)
    }

    func testRealImagesWithTheSameNameConvertInParallelSafely() async throws {
        let inputs = try sameNamedInputs(6, real: true)
        let out = try fx.folder("out")
        let report = try await Engine.shared.convert(inputs, to: .jpg, outputDirectory: out)
        XCTAssertEqual(report.failures.map(\.message), [])
        XCTAssertEqual(Set(report.outputs).count, 6, KitFixtures.names(report.outputs).joined(separator: ", "))
        XCTAssertTrue(report.outputs.allSatisfy(KitFixtures.isDecodableImage))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path).count, 6)
    }

    func testSameBaseNameInManyFormatsInOneFolder() async throws {
        // Security review repro: photo.{png,bmp,tiff,gif,tga,jp2,heic,psd} → JPG next to the originals.
        let context = CGContext(data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = context.makeImage()!
        let formats: [FileFormat] = [.png, .bmp, .tiff, .gif, .tga, .jp2, .heic, .psd].filter(ImageCodec.nativeWritableFormats.contains)
        XCTAssertGreaterThanOrEqual(formats.count, 6)
        var inputs: [URL] = []
        for format in formats {
            let url = try fx.url("same/photo.\(format.fileExtension)")
            try await ImageCodec.write(image, as: format, to: url, options: .init())
            inputs.append(url)
        }
        let report = try await Engine.shared.convert(inputs, to: .jpg)
        XCTAssertEqual(report.failures.map(\.message), [])
        XCTAssertEqual(Set(report.outputs).count, formats.count, KitFixtures.names(report.outputs).joined(separator: ", "))
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: fx.root.appendingPathComponent("same").path)
        XCTAssertEqual(onDisk.filter { $0.hasSuffix(".jpg") }.count, formats.count)
        XCTAssertTrue(report.outputs.allSatisfy(KitFixtures.isDecodableImage))
        XCTAssertEqual(Set(report.replaceableOriginals), Set(inputs), "each original has its own output")
    }

    func testReplacingOriginalsSkipsOutputsAndFilesAddedDuringTheJob() async throws {
        // ALAC is written as .m4a next to the originals, and a new file appears in the folder mid-job.
        let folder = try fx.folder("music")
        let songs = try ["one", "two"].map { try fx.dummy("music/\($0).mp3") }
        let late = folder.appendingPathComponent("late.mp3")
        let engine = Engine(conversionBackends: [FakeAudioBackend(dropWhileRunning: late)], toolBackends: [])
        let report = try await engine.convert([folder], to: .alac)
        XCTAssertEqual(KitFixtures.names(report.outputs), ["one.m4a", "two.m4a"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path))
        XCTAssertEqual(KitFixtures.paths(report.replaceableOriginals), KitFixtures.paths(songs),
                       "only converted inputs; never the new .m4a outputs or late.mp3")
    }

    func testReplacingOriginalsRequiresADistinctExistingOutput() throws {
        let a = try fx.dummy("r/a.png"), b = try fx.dummy("r/b.png"), c = try fx.dummy("r/c.png")
        let d = try fx.dummy("r/d.png"), e = try fx.dummy("r/e.png")
        let shared = try fx.dummy("r/shared.jpg"), eOut = try fx.dummy("r/e.jpg")
        let missing = fx.root.appendingPathComponent("r/gone.jpg")
        var report = JobReport()
        report.converted = [
            .init(input: a, outputs: [a]),                 // written in place
            .init(input: b, outputs: [shared]),            // two inputs claim one output (a naming race)
            .init(input: c, outputs: [shared]),
            .init(input: d, outputs: [missing]),           // output no longer exists
            .init(input: e, outputs: [eOut]),
        ]
        report.outputs = report.converted.flatMap(\.outputs)
        XCTAssertEqual(report.replaceableOriginals, [e])
        report.failures = [.init(file: d, message: "x")]
        XCTAssertEqual(report.replaceableOriginals, [], "nothing is trashed when anything failed")
    }

    func testNamesAreFreedAfterTheJobSoDeletedOutputsAreReused() async throws {
        let (engine, _) = fakeEngine()
        let input = try fx.dummy("in/photo.png")
        let out = try fx.folder("out")
        let first = try await engine.convert([input], to: .jpg, outputDirectory: out)
        XCTAssertEqual(KitFixtures.names(first.outputs), ["photo.jpg"])
        try FileManager.default.removeItem(at: first.outputs[0])
        let again = try await engine.convert([input], to: .jpg, outputDirectory: out)
        XCTAssertEqual(KitFixtures.names(again.outputs), ["photo.jpg"], "a finished job must not keep names reserved")
    }

    // MARK: Failures and progress

    func testOneFailureDoesntStopTheOthers() async throws {
        let (engine, _) = fakeEngine { $0.failingNames = ["c.png"] }
        let inputs = try ["a", "b", "c", "d", "e"].map { try fx.dummy("in/\($0).png") }
        let report = try await engine.convert(inputs, to: .jpg, outputDirectory: try fx.folder("out"))
        XCTAssertEqual(KitFixtures.names(report.outputs), ["a.jpg", "b.jpg", "d.jpg", "e.jpg"], "outputs keep input order")
        XCTAssertEqual(report.failures.map(\.file.lastPathComponent), ["c.png"])
        XCTAssertEqual(report.failures.first?.message, "Boom: c.png")
        XCTAssertTrue(report.summary.hasPrefix("Saved 4 files · ") && report.summary.hasSuffix(" · 1 failed"), report.summary)
        XCTAssertFalse(report.succeeded)
    }

    func testProgressNeverGoesBackwardsAndEndsAtOne() async throws {
        // Backends can restart a file's progress (e.g. ffmpeg retrying after a stream copy fails).
        let (engine, _) = fakeEngine {
            $0.progressSteps = [0.2, 0.6, 0.1, 0.4, 0.9, 1.5, -1]
            $0.delayNanoseconds = 14_000_000
        }
        let inputs = try (1...10).map { try fx.dummy("in/\($0).png") }
        let progress = Locked<[JobProgress]>([])
        _ = try await engine.convert(inputs, to: .jpg, outputDirectory: try fx.folder("out")) { p in
            progress.mutate { $0.append(p) }
        }
        let fractions = progress.value.map(\.fraction)
        XCTAssertFalse(fractions.isEmpty)
        for (previous, next) in zip(fractions, fractions.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next + 1e-9, "progress went backwards: \(fractions)")
        }
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(progress.value.last?.completedFiles, 10)
        XCTAssertEqual(progress.value.map(\.completedFiles), progress.value.map(\.completedFiles).sorted())
    }

    func testEverythingAlreadyInTheTargetFormatIsAnError() async throws {
        let png = try fx.dummy("in/a.png")
        do {
            _ = try await Engine.shared.convert([png], to: .png)
            XCTFail("nothing to convert")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        do {
            _ = try await Engine.shared.run(.compress, on: [try fx.dummy("a.xyz")])
            XCTFail("no supported files")
        } catch {}
        do {
            _ = try await Engine.shared.run(.compress, on: [])
            XCTFail("no files")
        } catch {}
    }

    // MARK: Cancellation

    func testCancellationStopsRemainingFiles() async throws {
        let (engine, fake) = fakeEngine { $0.delayNanoseconds = 200_000_000 }
        let inputs = try (1...30).map { try fx.dummy("in/\($0).png") }
        let out = try fx.folder("out")
        let task = Task { try await engine.convert(inputs, to: .jpg, outputDirectory: out) }
        while fake.started.value.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled job throws")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? ConversionError).map { "\($0)" == "cancelled" } == true, "\(error)")
        }
        let startedAtCancel = fake.started.value.count
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(fake.started.value.count, startedAtCancel, "no new files start after cancelling")
        XCTAssertLessThanOrEqual(startedAtCancel, 4)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [],
                       "files interrupted by cancellation leave nothing behind")
    }

    func testCancelledRealConversionLeavesOnlyCompleteFiles() async throws {
        let inputs = try (1...24).map { try fx.image("in/c\($0).png", width: 900, height: 700) }
        let out = try fx.folder("out")
        let task = Task { try await Engine.shared.convert(inputs, to: .heic, outputDirectory: out) }
        try await Task.sleep(nanoseconds: 30_000_000)
        task.cancel()
        _ = try? await task.value
        let written = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
        XCTAssertLessThan(written.count, inputs.count, "cancelling should stop the batch early")
        for file in written {
            XCTAssertTrue(KitFixtures.isDecodableImage(file), "partial output left behind: \(file.lastPathComponent)")
        }
    }

    func testCancellingBeforeTheJobStartsDoesNoWork() async throws {
        let (engine, fake) = fakeEngine()
        let inputs = try (1...8).map { try fx.dummy("in/\($0).png") }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await engine.convert(inputs, to: .jpg, outputDirectory: try fx.folder("out"))
        }
        _ = try? await task.value
        XCTAssertEqual(fake.started.value.count, 0)
    }

    // MARK: Multi-file tools

    func testMergeWithOneFileMixedInputsAndUnsupportedFiles() async throws {
        let one = try await Engine.shared.run(.mergePDF, on: [try fx.image("m/solo.png")])
        XCTAssertEqual(one.outputs.count, 1)
        XCTAssertEqual(CGPDFDocument(one.outputs[0] as CFURL)?.numberOfPages, 1)
        XCTAssertEqual(one.outputs[0].lastPathComponent, "solo merged.pdf")

        let mixed = try await Engine.shared.run(.mergePDF, on: [try fx.image("m/a.jpg", type: "public.jpeg"), one.outputs[0],
                                                                 try fx.image("m/b.png")])
        XCTAssertEqual(CGPDFDocument(mixed.outputs[0] as CFURL)?.numberOfPages, 3, "PDF pages are kept, images add pages")

        do {
            _ = try await Engine.shared.run(.mergePDF, on: [try fx.image("m/c.png"), try fx.dummy("m/song.mp3")])
            XCTFail("audio can't be merged into a PDF")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("song.mp3"), error.localizedDescription)
        }
    }

    func testMergingAFolderFollowsFinderOrder() async throws {
        let folder = try fx.folder("scans")
        // Distinct page widths identify the order after merging.
        for n in [10, 2, 1] { try fx.image("scans/page\(n).png", width: 100 + n, height: 50) }
        let report = try await Engine.shared.run(.mergePDF, on: [folder])
        let pdf = try XCTUnwrap(CGPDFDocument(report.outputs[0] as CFURL))
        let widths = (1...pdf.numberOfPages).map { Int(pdf.page(at: $0)!.getBoxRect(.mediaBox).width) }
        XCTAssertEqual(widths, [101, 102, 110])
    }

    func testCopyTextWithNoTextLeavesNoText() async throws {
        let blank = try fx.image("blank.png", color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let report = try await Engine.shared.run(.copyText, on: [blank, try fx.image("blank2.png", color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))])
        XCTAssertTrue(report.outputs.isEmpty)
        XCTAssertTrue(report.text?.isEmpty ?? true, "blank images produce no clipboard text")
        XCTAssertEqual(report.summary, "No text found")
    }
}

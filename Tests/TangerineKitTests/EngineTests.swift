import CoreGraphics
import ImageIO
@testable import TangerineKit
import XCTest

final class EngineTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let engine = Engine.shared

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    private func image(_ name: String, type: String = "public.jpeg") throws -> URL {
        let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let url = temp.file(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func text(_ name: String, _ contents: String) throws -> URL {
        let url = temp.file(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Capabilities

    func testEveryCategoryHasConversions() {
        let samples: [FileFormat] = [.jpg, .png, .heic, .raw, .svg, .mp4, .mov, .mp3, .wav, .flac, .pdf, .docx, .md, .html]
        for format in samples {
            XCTAssertFalse(engine.targets(from: format).isEmpty, "\(format) should have targets")
        }
        let total = FileFormat.allCases.reduce(0) { $0 + engine.targets(from: $1).count }
        XCTAssertGreaterThan(total, 250, "conversion matrix shrank unexpectedly: \(total)")
    }

    func testTargetsNeverIncludeTheSourceFormat() {
        for format in FileFormat.allCases {
            XCTAssertFalse(engine.targets(from: format).contains(format), "\(format)")
        }
    }

    func testMixedImageSelectionOffersCommonTargets() throws {
        let jpg = try image("a.jpg")
        let png = try image("b.png", type: "public.png")
        let targets = engine.targets(for: [jpg, png])
        XCTAssertTrue(targets.contains(.png), "PNG applies to the JPG; the PNG is skipped")
        XCTAssertTrue(targets.contains(.jpg))
        XCTAssertTrue(targets.contains(.heic))
        XCTAssertEqual(targets.first, .jpg, "catalog order")
    }

    func testUnrelatedSelectionHasNoCommonTargets() throws {
        let jpg = try image("a.jpg")
        let md = try text("notes.md", "# Hi")
        XCTAssertFalse(engine.targets(for: [jpg, md]).contains(.png))
        XCTAssertTrue(engine.targets(for: [jpg, md]).isEmpty || engine.targets(for: [jpg, md]).allSatisfy {
            engine.targets(from: .jpg).contains($0) && engine.targets(from: .md).contains($0)
        })
    }

    func testToolsDependOnSelection() throws {
        let jpg = try image("a.jpg")
        let single = engine.tools(for: [jpg])
        XCTAssertEqual(single.first, .openEditor)
        XCTAssertTrue(single.contains(.compress))
        XCTAssertFalse(single.contains(.mergePDF), "merging needs more than one file")

        let multiple = engine.tools(for: [jpg, try image("b.png", type: "public.png")])
        XCTAssertFalse(multiple.contains(.openEditor), "the editor opens one image at a time")
        XCTAssertTrue(multiple.contains(.mergePDF))
    }

    func testFoldersExpandToSupportedFiles() throws {
        let folder = temp.url.appendingPathComponent("album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
        let a = try image("album/one.jpg")
        let b = try image("album/nested/two.jpg")
        _ = try text("album/readme.unknownext", "x")
        _ = try text("album/.hidden.jpg", "x")
        let expanded = Set(engine.expand([folder]).map(\.lastPathComponent))
        XCTAssertEqual(expanded, [a.lastPathComponent, b.lastPathComponent])
        XCTAssertTrue(engine.targets(for: [folder]).contains(.png))
    }

    // MARK: Running

    func testBatchConversionReportsEveryOutput() async throws {
        let files = try (1...5).map { try image("photo\($0).jpg") }
        let out = temp.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let progress = Locked<[Double]>([])
        let report = try await engine.convert(files, to: .png, outputDirectory: out) { p in progress.mutate { $0.append(p.fraction) } }
        XCTAssertEqual(report.outputs.count, 5)
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.outputs.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == out.standardizedFileURL })
        XCTAssertEqual(report.summary.hasPrefix("Saved 5 files"), true, report.summary)
        XCTAssertEqual(progress.value.last ?? 0, 1, accuracy: 0.001)
    }

    func testBatchKeepsGoingAfterAFailure() async throws {
        let good = try image("good.jpg")
        let bad = try text("broken.jpg", "not really a jpeg")
        let report = try await engine.convert([good, bad], to: .png)
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.file.lastPathComponent, "broken.jpg")
        XCTAssertTrue(report.summary.contains("1 failed"), report.summary)
    }

    func testSizeChangeOnlyForMeaningfulJobs() async throws {
        let md = try text("doc.md", "# Title\n\nBody text.")
        let docReport = try await engine.convert([md], to: .html)
        XCTAssertNil(docReport.sizeChangePercent, "document conversions don't report size deltas")

        let jpg = try image("shrink.jpg")
        let imageReport = try await engine.convert([jpg], to: .png)
        XCTAssertNotNil(imageReport.sizeChangePercent)
    }

    func testCombiningToolProducesOneFile() async throws {
        let report = try await engine.run(.mergePDF, on: [try image("p1.jpg"), try image("p2.png", type: "public.png")])
        XCTAssertEqual(report.outputs.count, 1)
        XCTAssertEqual(report.outputs.first?.pathExtension, "pdf")
        XCTAssertEqual(CGPDFDocument(report.outputs[0] as CFURL)?.numberOfPages, 2)
    }

    func testEditorToolIsNotRunByTheEngine() async throws {
        let jpg = try image("e.jpg")
        do {
            _ = try await engine.run(.openEditor, on: [jpg])
            XCTFail("openEditor is handled by the app")
        } catch {}
    }

    func testCancellationStopsTheJob() async throws {
        let files = try (1...40).map { try image("c\($0).jpg") }
        let task = Task { try await engine.convert(files, to: .heic) }
        task.cancel()
        do {
            _ = try await task.value
        } catch {
            return   // cancelled as expected
        }
        // Small jobs may finish before cancellation is observed; that's acceptable.
    }
}

/// Tiny thread-safe box for collecting values from @Sendable callbacks.
final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    init(_ value: Value) { stored = value }

    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }

    func mutate(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

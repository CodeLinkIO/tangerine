import Foundation
@testable import TangerineKit
import XCTest

/// Output folders, collision-free naming and job report wording.
final class OutputEdgeCaseTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var fx: KitFixtures!
    private let engine = Engine.shared
    private var lockedFolders: [URL] = []

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        fx = KitFixtures(temp)
    }

    override func tearDown() {
        for folder in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        temp = nil
    }

    private func lock(_ folder: URL, _ mode: Int = 0o555) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: folder.path)
        lockedFolders.append(folder)
    }

    // MARK: Output folder

    func testOutputGoesNextToTheOriginalOrToDownloadsWhenReadOnly() throws {
        let writable = try fx.dummy("rw/a.jpg")
        XCTAssertEqual(Engine.outputDirectory(for: writable, preferred: nil).standardizedFileURL,
                       writable.deletingLastPathComponent().standardizedFileURL)

        let readOnly = try fx.dummy("ro/a.jpg")
        try lock(readOnly.deletingLastPathComponent())
        let downloads = try XCTUnwrap(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        XCTAssertEqual(Engine.outputDirectory(for: readOnly, preferred: nil), downloads, "read-only folders fall back to Downloads")

        let chosen = fx.root.appendingPathComponent("chosen", isDirectory: true)
        XCTAssertEqual(Engine.outputDirectory(for: readOnly, preferred: chosen), chosen, "a chosen folder always wins")
    }

    func testMissingChosenFolderIsCreated() async throws {
        let png = try fx.image("in/a.png")
        let out = fx.root.appendingPathComponent("not/yet/there", isDirectory: true)
        let report = try await engine.convert([png], to: .jpg, outputDirectory: out)
        XCTAssertEqual(report.failures.map(\.message), [])
        XCTAssertEqual(report.outputs.map { $0.deletingLastPathComponent().standardizedFileURL }, [out.standardizedFileURL])
    }

    func testUnusableChosenFolderFailsOnceWithAClearMessage() async throws {
        let png = try fx.image("in/a.png")
        let notAFolder = try fx.dummy("file-not-folder")
        do {
            _ = try await engine.convert([png], to: .jpg, outputDirectory: notAFolder)
            XCTFail("writing into a file must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("file-not-folder"), error.localizedDescription)
        }

        let readOnly = try fx.folder("locked-out")
        try lock(readOnly)
        do {
            _ = try await engine.run(.rotateRight, on: [png], outputDirectory: readOnly)
            XCTFail("writing into a read-only folder must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("locked-out"), error.localizedDescription)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: readOnly.path), [])
    }

    // MARK: Naming

    func testUniqueNamesSkipEveryTakenNumber() throws {
        let dir = try fx.folder("names")
        let plan = OutputPlan(directory: dir, baseName: "photo")
        XCTAssertEqual(plan.file(extension: "jpg").lastPathComponent, "photo.jpg")
        for name in ["photo.jpg", "photo 2.jpg", "photo 3.jpg"] { try fx.dummy("names/\(name)") }
        XCTAssertEqual(plan.file(extension: "jpg").lastPathComponent, "photo 4.jpg")
        XCTAssertEqual(plan.file(extension: "png").lastPathComponent, "photo.png", "other extensions are independent")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("photo 2.jpg"))
        XCTAssertEqual(plan.file(extension: "jpg").lastPathComponent, "photo 2.jpg", "gaps are reused")
        XCTAssertEqual(plan.file(extension: "jpg", suffix: "compressed").lastPathComponent, "photo compressed.jpg")
    }

    func testNamesWithDotsKeepTheirStem() throws {
        let dir = try fx.folder("dots")
        try fx.dummy("dots/my.photo.v2.jpg")
        XCTAssertEqual(OutputPlan(directory: dir, baseName: "my.photo.v2").file(extension: "jpg").lastPathComponent,
                       "my.photo.v2 2.jpg")
        let fromInput = OutputPlan(for: try fx.dummy("src/Q3.2024 report.pdf"), directory: dir)
        XCTAssertEqual(fromInput.file(extension: "txt").lastPathComponent, "Q3.2024 report.txt")
    }

    func testFoldersWithDotsAreNumberedAtTheEnd() throws {
        let dir = try fx.folder("folders")
        let plan = OutputPlan(directory: dir, baseName: "Q3.2024")
        XCTAssertEqual(try plan.makeFolder().lastPathComponent, "Q3.2024")
        XCTAssertEqual(try plan.makeFolder().lastPathComponent, "Q3.2024 2")
        XCTAssertEqual(try plan.makeFolder(suffix: "pages").lastPathComponent, "Q3.2024 pages")
        XCTAssertEqual(try plan.makeFolder(suffix: "pages").lastPathComponent, "Q3.2024 pages 2")
    }

    func testNamesCollideIgnoringCaseAndUnicodeForm() throws {
        let dir = try fx.folder("case")
        try fx.dummy("case/Photo.JPG")
        XCTAssertEqual(OutputPlan(directory: dir, baseName: "photo").file(extension: "jpg").lastPathComponent, "photo 2.jpg",
                       "APFS is case-insensitive: Photo.JPG and photo.jpg are the same file")
        try fx.dummy("case/caf\u{E9}.png")
        XCTAssertEqual(OutputPlan(directory: dir, baseName: "cafe\u{301}").file(extension: "png").lastPathComponent,
                       "cafe\u{301} 2.png")
    }

    func testVeryLongNamesAreShortenedToFit() async throws {
        let longBase = String(repeating: "あ", count: 251)   // 251 + ".png" = the 255-unit limit
        let png = try fx.image("long/\(longBase).png")
        let out = try fx.folder("long-out")
        let first = try await engine.convert([png], to: .tiff, outputDirectory: out)
        let second = try await engine.run(.rotateRight, on: [png], outputDirectory: out)
        let third = try await engine.convert([png], to: .tiff, outputDirectory: out)
        for report in [first, second, third] {
            XCTAssertEqual(report.failures.map(\.message), [])
            XCTAssertEqual(report.outputs.count, 1)
        }
        let names = [first, second, third].map { $0.outputs[0].lastPathComponent }
        for name in names {
            XCTAssertLessThanOrEqual(name.utf8.count, 255, name)
            XCTAssertTrue(name.hasPrefix(String(repeating: "あ", count: 70)), name)
        }
        // Writers that go through ImageIO URLs (lossless JPEG rotation) need the shorter names too.
        let jpg = try fx.image("long/\(String(repeating: "b", count: 250)).jpg", type: "public.jpeg")
        let rotated = try await engine.run(.rotateLeft, on: [jpg], outputDirectory: out)
        XCTAssertEqual(rotated.failures.map(\.message), [])
        XCTAssertEqual(rotated.outputs.count, 1)
        XCTAssertTrue(names[1].hasSuffix(" rotated.png"), names[1])
        XCTAssertNotEqual(names[0], names[2])
    }

    func testFileSizeOfFoldersAndMissingFiles() throws {
        try fx.dummy("sized/a.bin", String(repeating: "a", count: 100))
        try fx.dummy("sized/sub/b.bin", String(repeating: "b", count: 50))
        XCTAssertEqual(fx.root.appendingPathComponent("sized").fileSize, 150)
        XCTAssertEqual(fx.root.appendingPathComponent("nope.bin").fileSize, 0)
        XCTAssertEqual(try fx.dummy("empty.bin", "").fileSize, 0)
    }

    // MARK: Reports

    private func failure(_ name: String, _ message: String) -> JobReport.Failure {
        .init(file: URL(fileURLWithPath: "/tmp/\(name)"), message: message)
    }

    func testSummaryWording() {
        var report = JobReport()
        XCTAssertEqual(report.summary, "Nothing to do")
        XCTAssertFalse(report.succeeded)

        report.notes = ["Already optimized"]
        XCTAssertEqual(report.summary, "Already optimized")
        XCTAssertTrue(report.succeeded)

        report = JobReport()
        report.failures = [failure("a.jpg", "Couldn't read “a.jpg”.")]
        XCTAssertEqual(report.summary, "Couldn't read “a.jpg”.")
        report.failures.append(failure("b.jpg", "Other"))
        XCTAssertEqual(report.summary, "2 files failed: Couldn't read “a.jpg”.")
        XCTAssertFalse(report.succeeded)

        report.outputs = [URL(fileURLWithPath: "/tmp/c.png")]
        XCTAssertEqual(report.summary, "Saved c.png · 2 failed")
        report.outputs.append(URL(fileURLWithPath: "/tmp/d.png"))
        report.failures = []
        XCTAssertEqual(report.summary, "Saved 2 files")
        XCTAssertTrue(report.succeeded)

        report = JobReport()
        report.text = ""
        XCTAssertEqual(report.summary, "No text found")
        report.text = "héllo 👋🏽"
        XCTAssertEqual(report.summary, "Copied 7 characters", "counts characters, not bytes")
    }

    func testSizeChangeEdgeCases() {
        var report = JobReport()
        report.outputs = [URL(fileURLWithPath: "/tmp/x.jpg")]
        report.inputBytes = 1000
        report.outputBytes = 250
        XCTAssertNil(report.sizeChangePercent, "only meaningful jobs compare sizes")
        report.comparesSize = true
        XCTAssertEqual(report.sizeChangePercent, -75)
        XCTAssertEqual(report.summary, "Saved x.jpg · -75%")

        report.outputBytes = 3000
        XCTAssertEqual(report.sizeChangePercent, 200)
        XCTAssertEqual(report.summary, "Saved x.jpg · +200%")

        report.outputBytes = 1004
        XCTAssertEqual(report.sizeChangePercent, 0)
        XCTAssertEqual(report.summary, "Saved x.jpg", "0% isn't shown")

        report.inputBytes = 0
        XCTAssertNil(report.sizeChangePercent, "0-byte inputs must not divide by zero")
        report.inputBytes = 1000
        report.outputBytes = 0
        XCTAssertNil(report.sizeChangePercent)
    }

    func testZeroByteInputReportsNoSizeChange() async throws {
        let empty = try fx.dummy("empty.png", "")
        let report = try await engine.convert([empty], to: .jpg, outputDirectory: try fx.folder("out"))
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertNil(report.sizeChangePercent)
    }
}

import Foundation
@testable import TangerineKit
import XCTest

/// Format detection, capability intersection and folder expansion edge cases.
final class InputEdgeCaseTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var fx: KitFixtures!
    private let engine = Engine.shared
    /// Folders made unreadable by a test; permissions are restored so cleanup can delete them.
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

    // MARK: Detection

    func testDetectionIgnoresExtensionCase() throws {
        XCTAssertEqual(FileFormat.detect(try fx.dummy("a.JPG")), .jpg)
        XCTAssertEqual(FileFormat.detect(try fx.dummy("b.Jpeg")), .jpg)
        XCTAssertEqual(FileFormat.detect(try fx.dummy("c.HEIC")), .heic)
        XCTAssertEqual(FileFormat.detect(try fx.dummy("d.TiF")), .tiff)
        XCTAssertEqual(FileFormat.detect(try fx.dummy("e.MD")), .md)
    }

    func testDetectionUsesOnlyTheLastExtension() throws {
        XCTAssertEqual(FileFormat.detect(try fx.dummy("photo.png.jpg")), .jpg)
        XCTAssertNil(FileFormat.detect(try fx.dummy("photo.jpg.zip")))
        XCTAssertEqual(FileFormat.baseName(of: URL(fileURLWithPath: "/x/my.photo.v2.png")), "my.photo.v2")
    }

    func testFilesWithoutAUsableExtensionAreNotDetected() throws {
        // No content sniffing: extensionless files and dotfiles are ignored.
        XCTAssertNil(FileFormat.detect(try fx.image("README", type: "public.png")))
        XCTAssertNil(FileFormat.detect(try fx.dummy(".DS_Store")))
        XCTAssertNil(FileFormat.detect(try fx.dummy(".jpg")))
        XCTAssertNil(FileFormat.detect(try fx.dummy("photo.")))
        XCTAssertNil(FileFormat.detect(try fx.dummy("photo.jpg alias")))
    }

    func testAliasesMapToCanonicalFormats() {
        let expected: [String: FileFormat] = [
            "jpeg": .jpg, "jpe": .jpg, "jfif": .jpg, "tif": .tiff, "heif": .heic, "htm": .html, "xhtml": .html,
            "markdown": .md, "mdown": .md, "aif": .aiff, "qt": .mov, "m2ts": .mts, "mpeg": .mpg, "dng": .raw,
            "cr2": .raw, "m4a": .m4a, "3gp": .threeGP, "text": .txt,
        ]
        for (ext, format) in expected {
            XCTAssertEqual(FileFormat.detect(URL(fileURLWithPath: "/nonexistent/f.\(ext)")), format, ext)
        }
        // ALAC is output-only: an .alac extension isn't a real file type, and ALAC files are .m4a.
        XCTAssertNil(FileFormat.detect(URL(fileURLWithPath: "/nonexistent/f.alac")))
        XCTAssertEqual(FileFormat.alac.fileExtension, "m4a")
        XCTAssertEqual(FileFormat.raw.fileExtension, "dng")
    }

    func testFoldersAreNotFilesExceptRTFD() throws {
        let fakeImageFolder = try fx.folder("Holiday.jpg")
        XCTAssertNil(FileFormat.detect(fakeImageFolder), "a folder named like an image is still a folder")
        let image = try fx.image("Holiday.jpg/inside.png")
        XCTAssertEqual(KitFixtures.paths(engine.expand([fakeImageFolder])), KitFixtures.paths([image]), "and it is expanded like any folder")

        let rtfd = try fx.folder("Notes.rtfd")
        try fx.dummy("Notes.rtfd/TXT.rtf", "{\\rtf1 hi}")
        XCTAssertEqual(FileFormat.detect(rtfd), .rtfd)
        XCTAssertEqual(engine.expand([rtfd]).map(\.lastPathComponent), ["Notes.rtfd"], "RTFD is one document")
    }

    func testContentNotMatchingTheExtension() async throws {
        // ImageIO sniffs content, so a PNG saved as .jpg still converts.
        let mislabeled = try fx.image("actually-png.jpg", type: "public.png")
        let ok = try await engine.convert([mislabeled], to: .png, outputDirectory: try fx.folder("out"))
        XCTAssertEqual(ok.outputs.count, 1, ok.summary)
        XCTAssertTrue(KitFixtures.isDecodableImage(ok.outputs[0]))

        // Text pretending to be an image fails cleanly with a per-file message.
        let fake = try fx.dummy("fake.png", "hello")
        let bad = try await engine.convert([fake], to: .jpg, outputDirectory: try fx.folder("out"))
        XCTAssertTrue(bad.outputs.isEmpty)
        XCTAssertEqual(bad.failures.count, 1)
        XCTAssertFalse(bad.summary.isEmpty)
    }

    // MARK: Capabilities

    func testNoTargetsForEmptyMissingOrUnsupportedSelections() throws {
        XCTAssertEqual(engine.targets(for: []), [])
        XCTAssertEqual(engine.tools(for: []), [])
        XCTAssertEqual(engine.targets(for: [try fx.dummy("a.xyz")]), [])
        XCTAssertEqual(engine.targets(for: [fx.root.appendingPathComponent("missing.jpg")]), [])
        XCTAssertEqual(engine.targets(for: [try fx.folder("empty")]), [])
    }

    func testUnsupportedAndDuplicateFilesDontChangeTargets() throws {
        let jpg = try fx.dummy("a.jpg")
        let alone = engine.targets(for: [jpg])
        XCTAssertFalse(alone.isEmpty)
        XCTAssertEqual(engine.targets(for: [jpg, try fx.dummy("notes.xyz")]), alone, "unknown files are ignored")
        XCTAssertEqual(engine.targets(for: [jpg, jpg, jpg]), alone, "duplicates act like one file")

        // A file selected both directly and through its folder is only processed once.
        let folder = try fx.folder("set")
        let inside = try fx.dummy("set/x.jpg")
        XCTAssertEqual(engine.expand([jpg, jpg]), [jpg])
        XCTAssertEqual(KitFixtures.paths(engine.expand([folder, inside])), KitFixtures.paths([inside]))
        XCTAssertEqual(engine.tools(for: [jpg, jpg]), engine.tools(for: [jpg]), "still one image for the editor")
    }

    func testImageAndPDFSelectionOffersOnlySharedTargets() throws {
        let jpg = try fx.dummy("a.jpg"), pdf = try fx.dummy("b.pdf")
        let targets = engine.targets(for: [jpg, pdf])
        XCTAssertFalse(targets.isEmpty)
        XCTAssertEqual(Array(targets.prefix(2)), [.jpg, .png], "first input's catalog order")
        XCTAssertTrue(targets.contains(.pdf), "the PDF is skipped, the JPG becomes a PDF")
        for target in targets {
            XCTAssertTrue(target == .jpg || engine.targets(from: .jpg).contains(target), "\(target) for JPG")
            XCTAssertTrue(target == .pdf || engine.targets(from: .pdf).contains(target), "\(target) for PDF")
        }
        XCTAssertEqual(engine.targets(for: [pdf, jpg]).first, .png, "order follows the first input")
    }

    func testImageAndVideoSelectionOffersOnlySharedTargets() throws {
        let targets = engine.targets(for: [try fx.dummy("a.jpg"), try fx.dummy("b.mp4")])
        for target in targets {
            XCTAssertTrue(engine.targets(from: .jpg).contains(target) && engine.targets(from: .mp4).contains(target), "\(target)")
        }
        XCTAssertFalse(targets.contains(.mp3))
        XCTAssertFalse(targets.contains(.png))
        // Nothing converts both a document and a video.
        XCTAssertEqual(engine.targets(for: [try fx.dummy("c.docx"), try fx.dummy("d.mov")]), [])
    }

    func testThousandFileFolderIsSampledAndFast() throws {
        let folder = try fx.folder("big")
        for i in 0..<1000 { try fx.dummy("big/f\(i).\(i % 2 == 0 ? "jpg" : "png")") }
        XCTAssertEqual(engine.expand([folder], limit: Engine.capabilitySampleSize).count, 500)
        let start = Date()
        let targets = engine.targets(for: [folder])
        let tools = engine.tools(for: [folder])
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "wheel contents must stay quick for big folders")
        XCTAssertTrue(targets.contains(.png))
        XCTAssertTrue(tools.contains(.mergePDF))
        XCTAssertEqual(engine.expand([folder]).count, 1000, "the full job still sees every file")
    }

    func testToolsForMixedSelections() throws {
        let jpg = try fx.dummy("a.jpg"), pdf = try fx.dummy("b.pdf"), mp4 = try fx.dummy("c.mp4"), md = try fx.dummy("d.md")
        let imagePDF = engine.tools(for: [jpg, pdf])
        XCTAssertTrue(imagePDF.contains(.compress))
        XCTAssertTrue(imagePDF.contains(.mergePDF), "images and PDFs merge into one PDF")
        XCTAssertFalse(imagePDF.contains(.openEditor))
        XCTAssertFalse(imagePDF.contains(.rotateRight), "PDFs can't be rotated by the image tools")

        let imageVideo = engine.tools(for: [jpg, mp4])
        XCTAssertFalse(imageVideo.contains(.mergePDF), "video can't go into a PDF")
        XCTAssertEqual(engine.tools(for: [md]), [], "documents have no tools")
        XCTAssertEqual(engine.tools(for: [jpg, md]), [])
        let one = try fx.folder("one")
        try fx.dummy("one/x.jpg")
        XCTAssertFalse(engine.tools(for: [one]).contains(.mergePDF), "a folder holding a single image can't be merged")
    }

    // MARK: Expansion

    func testExpandSkipsHiddenFilesAndHandlesNestingAndEmptyFolders() throws {
        let album = try fx.folder("album")
        try fx.folder("album/empty")
        try fx.dummy("album/.DS_Store")
        try fx.dummy("album/.hidden/inside.jpg")
        let a = try fx.dummy("album/a.jpg")
        let b = try fx.dummy("album/one/two/three/b.heic")
        XCTAssertEqual(Set(KitFixtures.paths(engine.expand([album]))), Set(KitFixtures.paths([a, b])))
        XCTAssertEqual(engine.expand([try fx.folder("nothing")]), [])
    }

    func testExpandListsFolderContentsInFinderOrder() throws {
        // Merge PDF and batch outputs follow this order, so page2 must come before page10.
        let folder = try fx.folder("scans")
        for n in [10, 2, 1, 12, 3, 11] { try fx.dummy("scans/page\(n).jpg") }
        XCTAssertEqual(KitFixtures.names(engine.expand([folder])),
                       ["page1.jpg", "page2.jpg", "page3.jpg", "page10.jpg", "page11.jpg", "page12.jpg"])
    }

    func testPackagesAreNeverOpened() throws {
        let folder = try fx.folder("stuff")
        try fx.dummy("stuff/Tool.app/Contents/Resources/icon.png")
        try fx.dummy("stuff/Photos Library.photoslibrary/originals/IMG_1.heic")
        try fx.dummy("stuff/Notes.rtfd/TXT.rtf", "{\\rtf1 hi}")
        let photo = try fx.dummy("stuff/photo.jpg")
        XCTAssertEqual(Set(KitFixtures.names(engine.expand([folder]))), ["Notes.rtfd", photo.lastPathComponent])

        // Dropping a package itself must not convert (or trash) the files inside it.
        let library = fx.root.appendingPathComponent("stuff/Photos Library.photoslibrary")
        XCTAssertEqual(engine.expand([library]), [])
        XCTAssertEqual(engine.targets(for: [library]), [])
        XCTAssertEqual(engine.expand([fx.root.appendingPathComponent("stuff/Tool.app")]), [])
    }

    func testSymlinksLoopsAndLinkedFolders() throws {
        let fm = FileManager.default
        let real = try fx.folder("real")
        let photo = try fx.dummy("real/photo.jpg")
        try fm.createSymbolicLink(at: real.appendingPathComponent("loop"), withDestinationURL: real)
        let fileLink = fx.root.appendingPathComponent("real/link.png")
        try fm.createSymbolicLink(at: fileLink, withDestinationURL: try fx.dummy("elsewhere/target.png"))

        let expanded = engine.expand([real])   // must terminate despite the loop
        XCTAssertEqual(Set(KitFixtures.names(expanded)), ["photo.jpg", "link.png"])

        // A dropped symlink to a folder is followed.
        let folderLink = fx.root.appendingPathComponent("shortcut")
        try fm.createSymbolicLink(at: folderLink, withDestinationURL: real)
        XCTAssertEqual(Set(KitFixtures.names(engine.expand([folderLink]))), ["photo.jpg", "link.png"])
        XCTAssertTrue(engine.targets(for: [folderLink]).contains(.png))
        _ = photo
    }

    func testExpandLimitBoundaries() throws {
        let folder = try fx.folder("ten")
        for i in 0..<10 { try fx.dummy("ten/\(i).jpg") }
        let loose = try (0..<3).map { try fx.dummy("loose\($0).png") }
        XCTAssertEqual(engine.expand([folder], limit: 3).count, 3)
        XCTAssertEqual(engine.expand([folder], limit: 10).count, 10)
        XCTAssertEqual(engine.expand([folder], limit: 11).count, 10)
        XCTAssertEqual(engine.expand([folder], limit: 0), [])
        XCTAssertEqual(engine.expand(loose + [folder], limit: 4).count, 4)
        XCTAssertEqual(engine.expand(loose + [folder], limit: 2), Array(loose.prefix(2)))
    }

    func testUnreadableSubfolderDoesntHideTheRest() throws {
        let folder = try fx.folder("mixed")
        let visible = try fx.dummy("mixed/visible.jpg")
        let locked = try fx.folder("mixed/locked")
        try fx.dummy("mixed/locked/secret.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        lockedFolders.append(locked)
        XCTAssertEqual(KitFixtures.paths(engine.expand([folder])), KitFixtures.paths([visible]))
    }
}

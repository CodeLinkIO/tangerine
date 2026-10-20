import CoreGraphics
import ImageIO
@testable import TangerineApp
import TangerineKit
import XCTest

/// The editor window's model, driven like the UI does, against real files.
final class EditorModelTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var fixtures: EditorFixtures!

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        fixtures = EditorFixtures(temp: temp)
    }

    // XCTest keeps every test case alive until the run ends; release the folder so it gets deleted.
    override func tearDown() { fixtures = nil; temp = nil }

    private struct Timeout: Error {}

    @MainActor
    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw Timeout()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    private func open(_ url: URL, onSaved: @escaping (URL) -> Void = { _ in }) async throws -> EditorModel {
        let model = EditorModel(url: url, options: ConversionOptions(), onSaved: onSaved)
        model.load()
        try await waitFor("\(url.lastPathComponent) to load") { model.isFullResolutionReady || model.loadError != nil }
        return model
    }

    @MainActor
    private func estimatedBytes(_ model: EditorModel) async throws -> Int64 {
        var bytes: Int64 = 0
        try await waitFor("the size estimate") {
            if case let .bytes(value) = model.estimate { bytes = value; return true }
            return false
        }
        return bytes
    }

    private func decoded(_ url: URL) throws -> CGImage {
        try ImageCodec.load(url).image
    }

    // MARK: Opening

    @MainActor
    func testOpensUprightWithoutABogusTransparencyHint() async throws {
        // Portrait phone photos are stored sideways with an orientation tag.
        for (name, type) in [("portrait.jpg", "public.jpeg"), ("portrait.heic", "public.heic")] {
            let url = fixtures.write(EditorFixtures.markerImage(width: 300, height: 200), name, type: type,
                                     properties: [kCGImagePropertyOrientation: 6])
            let model = try await open(url)
            XCTAssertEqual(model.sourceSize, CGSize(width: 200, height: 300), name)
            model.exportFormat = .jpg
            XCTAssertNil(model.transparencyHint, "\(name) is opaque, so saving as JPG loses nothing")
            XCTAssertFalse(model.isDirty)
        }
        let logo = fixtures.write(EditorFixtures.markerImage(alpha: true), "logo.png", type: "public.png")
        let model = try await open(logo)
        model.exportFormat = .jpg
        XCTAssertEqual(model.transparencyHint, "JPG has no transparency, so see-through areas become white.")
    }

    @MainActor
    func testUnreadableAndOversizedFilesShowAnError() async throws {
        let text = temp.file("notes.jpg")
        try "not an image".write(to: text, atomically: true, encoding: .utf8)
        let broken = try await open(text)
        XCTAssertNotNil(broken.loadError)
        XCTAssertFalse(broken.isFullResolutionReady)

        // A complete 20000×20000 1-bit PNG: tiny on disk, 400 MP decoded. The preview must not even try.
        func be32(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) } }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let typeAndBody = Array(type.utf8) + body
            return be32(body.count) + typeAndBody + be32(Int(CRC32Reference.checksum(typeAndBody)))
        }
        let raw = Data(count: (1 + 2500) * 20000)
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", be32(20000) + be32(20000) + [1, 0, 0, 0, 0])
        png += chunk("IDAT", [0x78, 0x9C] + [UInt8](deflated) + be32((raw.count % 65521) << 16 | 1))
        png += chunk("IEND", [])
        let bomb = temp.file("bomb.png")
        try Data(png).write(to: bomb)
        let refused = try await open(bomb)
        XCTAssertTrue(refused.loadError?.contains("too large") == true, refused.loadError ?? "no error")
    }

    // MARK: Geometry

    @MainActor
    func testCropAfterRotateExportsWhatTheCanvasShows() async throws {
        var saved: URL?
        let model = try await open(fixtures.write(EditorFixtures.markerImage(), "turn.jpg")) { saved = $0 }
        model.tap(.rotate)
        XCTAssertEqual(model.baseSize, CGSize(width: 100, height: 200))
        model.tap(.crop)
        model.setAspect(.square)
        XCTAssertEqual(model.croppedSize, CGSize(width: 100, height: 100))
        model.updateCrop(CGRect(x: 0, y: 0, width: 1, height: 0.5), ended: true)   // drag the square to the top
        model.commitCrop()
        XCTAssertNil(model.tool)
        XCTAssertTrue(model.isDirty)

        let didSave = await model.saveCopy()
        XCTAssertTrue(didSave)
        let output = try XCTUnwrap(saved)
        XCTAssertEqual(output.lastPathComponent, "turn edited.jpg")
        let image = try decoded(output)
        XCTAssertEqual(CGSize(width: image.width, height: image.height), CGSize(width: 100, height: 100))
        XCTAssertEqual(EditorFixtures.markers(image).red, .topRight, "the stored top-left turns to the top-right")
        XCTAssertNil(EditorFixtures.markers(image).blue, "the bottom half was cropped away")
        XCTAssertFalse(model.isDirty, "saving clears the edited state")
    }

    @MainActor
    func testFlipAndRotateInEitherOrderMatchTheScreen() async throws {
        let url = fixtures.write(EditorFixtures.markerImage(), "mirror.png", type: "public.png")
        let cases: [([String], EditorFixtures.Corner, EditorFixtures.Corner)] = [
            (["flip", "rotate"], .bottomRight, .topRight),
            (["rotate", "flip"], .topLeft, .bottomLeft),
            (["flip", "flipV", "rotate", "rotate"], .topLeft, .topRight),   // 180° twice over
            (["rotateLeft", "flipV"], .topLeft, .bottomLeft),
        ]
        for (steps, red, blue) in cases {
            let model = try await open(url)
            for step in steps {
                switch step {
                case "flip": model.flip(horizontal: true)
                case "flipV": model.flip(horizontal: false)
                case "rotate": model.rotate(clockwise: true)
                default: model.rotate(clockwise: false)
                }
            }
            let destination = temp.file("mirror \(steps.joined(separator: "-")).png")
            try await EditorPipeline(preview: try ImageCodec.load(url)).exporting(model.exportRecipe, from: url, to: destination)
            let shown = EditorFixtures.markers(try decoded(destination))
            XCTAssertEqual(shown.red, red, "\(steps)")
            XCTAssertEqual(shown.blue, blue, "\(steps)")
        }
    }

    // MARK: Undo, redo and the edited state

    @MainActor
    func testUndoRedoSequence() async throws {
        let model = try await open(fixtures.write(EditorFixtures.markerImage(), "steps.jpg"))
        model.rotate(clockwise: true)
        model.flip(horizontal: true)
        model.tap(.crop)
        for step in 1...5 {   // one drag, many updates
            model.updateCrop(CGRect(x: 0.1, y: 0.1, width: 0.8 - 0.05 * Double(step), height: 0.5), ended: step == 5)
        }
        let edited = model.state
        model.undo()
        XCTAssertNil(model.recipe.crop, "a whole drag is one undo step")
        model.undo()
        XCTAssertFalse(model.recipe.flipHorizontal)
        model.undo()
        XCTAssertEqual(model.state, EditorState())
        XCTAssertFalse(model.canUndo)
        XCTAssertFalse(model.isDirty, "undoing everything is the same as no edits")
        model.undo()   // nothing left: harmless
        for _ in 0..<3 { model.redo() }
        XCTAssertEqual(model.state, edited)
        XCTAssertFalse(model.canRedo)

        model.undo()
        model.setResize(.percent(50))
        XCTAssertFalse(model.canRedo, "a new edit clears redo")

        // Escape leaves crop mode with the crop it started with.
        model.commitCrop()
        model.tap(.crop)
        XCTAssertEqual(model.tool, .crop)
        let before = model.recipe.crop
        model.updateCrop(CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2), ended: true)
        model.cancelCrop()
        XCTAssertEqual(model.recipe.crop, before)
        XCTAssertNil(model.tool)

        // Four turns or two flips are no change at all.
        model.resetAll()
        for _ in 0..<4 { model.rotate(clockwise: false) }
        model.flip(horizontal: false)
        model.flip(horizontal: false)
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testUndoingARotationKeepsTheAspectPresetOriented() async throws {
        let model = try await open(fixtures.write(EditorFixtures.markerImage(width: 320, height: 180), "wide.jpg"))
        model.tap(.crop)
        model.setAspect(.r4x3)
        XCTAssertEqual(model.croppedSize, CGSize(width: 240, height: 180))
        model.commitCrop()
        model.tap(.rotate)
        XCTAssertEqual(model.croppedSize, CGSize(width: 180, height: 240), "the crop turns with the image")
        model.undo()
        XCTAssertEqual(model.croppedSize, CGSize(width: 240, height: 180))
        // Re-entering crop mode re-applies the preset; it must still be landscape 4:3, not 3:4.
        model.tap(.crop)
        XCTAssertEqual(model.croppedSize, CGSize(width: 240, height: 180))
        model.redo()
        model.tap(.crop)
        model.tap(.crop)
        XCTAssertEqual(model.croppedSize, CGSize(width: 180, height: 240))
    }

    // MARK: Resize

    @MainActor
    func testCustomSizeFields() async throws {
        // 1920×1080 stored with orientation 6: a 1080×1920 portrait phone photo.
        let url = fixtures.write(EditorFixtures.markerImage(width: 1920, height: 1080), "tall.jpg",
                                 properties: [kCGImagePropertyOrientation: 6])
        let model = try await open(url)
        model.tap(.resize)
        model.startCustomSize()
        XCTAssertTrue(model.state.resize.isCustom)
        XCTAssertEqual(model.finalSize, CGSize(width: 1080, height: 1920))
        XCTAssertFalse(model.isDirty, "opening Custom without changing a value is not an edit")

        model.setCustomHeight(1000)
        XCTAssertEqual(model.finalSize, CGSize(width: 563, height: 1000), "the typed height is kept")
        XCTAssertTrue(model.isDirty)
        model.setCustomWidth(540)
        XCTAssertEqual(model.finalSize, CGSize(width: 540, height: 960))

        model.setCustomWidth(0)
        XCTAssertEqual(model.finalSize.width, 1)
        model.setCustomHeight(-20)
        XCTAssertEqual(model.finalSize.height, 1)

        // Huge values stay within 30000 px per side and the pixel budget, on both sides.
        model.setCustomWidth(1_000_000)
        let huge = model.finalSize
        XCTAssertLessThanOrEqual(max(huge.width, huge.height), 30000)
        XCTAssertLessThanOrEqual(huge.width * huge.height, CGFloat(ImageCodec.maxPixelCount))
        XCTAssertEqual(huge.height / huge.width, 1920.0 / 1080.0, accuracy: 0.01)
        model.toggleCustomLock()
        model.setCustomHeight(500)
        XCTAssertEqual(model.finalSize, CGSize(width: huge.width, height: 500), "unlocked fields are independent")
        model.setCustomWidth(200)   // back to something small before the background estimate renders
        XCTAssertEqual(model.finalSize, CGSize(width: 200, height: 500))
    }

    @MainActor
    func testUpscaleAndPresetsExport() async throws {
        var saved: [URL] = []
        let model = try await open(fixtures.write(EditorFixtures.markerImage(), "small.jpg")) { saved.append($0) }
        model.startCustomSize()
        model.setCustomWidth(500)
        let didSave = await model.saveCopy()
        XCTAssertTrue(didSave)
        model.setResize(.percent(25))
        let didSaveAgain = await model.saveCopy()
        XCTAssertTrue(didSaveAgain)
        model.setResize(.longEdge(1080))
        XCTAssertEqual(model.finalSize, CGSize(width: 200, height: 100), "long-edge presets never upscale")
        let sizes = try saved.map { try decoded($0) }.map { CGSize(width: $0.width, height: $0.height) }
        XCTAssertEqual(sizes, [CGSize(width: 500, height: 250), CGSize(width: 50, height: 25)])
        XCTAssertEqual(saved.map(\.lastPathComponent), ["small edited.jpg", "small edited 2.jpg"])
        XCTAssertEqual(EditorFixtures.markers(try decoded(saved[0])).red, .topLeft)
    }

    // MARK: Saving

    @MainActor
    func testEstimateMatchesTheSavedFile() async throws {
        var saved: URL?
        let model = try await open(fixtures.write(EditorFixtures.markerImage(width: 600, height: 400), "estimate.jpg")) { saved = $0 }
        for format: FileFormat in [.jpg, .png] {
            model.exportFormat = format
            try await waitFor("a new estimate") { model.estimate == .working }
            let estimate = try await estimatedBytes(model)
            let didSave = await model.saveCopy()
            XCTAssertTrue(didSave)
            XCTAssertEqual(try XCTUnwrap(saved).fileSize, estimate, "\(format) estimate is the real size")
        }
    }

    @MainActor
    func testEveryOfferedFormatSaves() async throws {
        var saved: URL?
        let url = fixtures.write(EditorFixtures.markerImage(), "every.png", type: "public.png")
        let model = try await open(url) { saved = $0 }
        model.rotate(clockwise: true)
        for format in model.primaryFormats + model.moreFormats {
            model.exportFormat = format
            let didSave = await model.saveCopy()
            XCTAssertTrue(didSave, "\(format)")
            let output = try XCTUnwrap(saved)
            XCTAssertEqual(output.pathExtension, format.fileExtension)
            if format == .pdf {
                XCTAssertEqual(CGPDFDocument(output as CFURL)?.numberOfPages, 1)
                continue
            }
            let image = try decoded(output)
            if format == .ico || format == .icns {
                XCTAssertEqual(image.width, image.height, "\(format)")
            } else {
                XCTAssertEqual(CGSize(width: image.width, height: image.height), CGSize(width: 100, height: 200), "\(format)")
                XCTAssertEqual(EditorFixtures.markers(image).red, .topRight, "\(format)")
            }
            if [.png, .heic, .tiff].contains(format) {
                XCTAssertNotEqual(EditorFixtures.properties(output)[kCGImagePropertyHasAlpha] as? Bool, true,
                                  "\(format): an opaque image doesn't gain an alpha channel")
            }
        }
    }

    @MainActor
    func testQualityPresetsOrderTheSize() async throws {
        let url = fixtures.write(EditorFixtures.markerImage(width: 400, height: 300), "q.png", type: "public.png")
        let loaded = try ImageCodec.load(url)
        let pipeline = EditorPipeline(preview: loaded)
        pipeline.setFull(loaded)
        var recipe = EditRecipe()
        recipe.straighten = 7   // adds detail so quality matters
        for format: FileFormat in [.jpg, .heic] {
            var sizes: [Int64] = []
            for preset in QualityPreset.allCases {
                sizes.append(try await pipeline.estimateSize(recipe, format: format, quality: preset.imageQuality, options: ConversionOptions()))
            }
            XCTAssertEqual(sizes, sizes.sorted(), "\(format): Small ≤ Balanced ≤ Best")
            XCTAssertLessThan(sizes[0], sizes[2], "\(format)")
        }
    }

    @MainActor
    func testReplaceOriginalWritesUprightPixels() async throws {
        let url = fixtures.write(EditorFixtures.markerImage(), "replace.jpg", properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Canon"],
        ])
        var saved: URL?
        let model = try await open(url) { saved = $0 }
        XCTAssertTrue(model.canReplaceOriginal)
        model.updateCrop(CGRect(x: 0, y: 0, width: 1, height: 0.5), ended: true)   // top half of the 100×200 display
        await model.replaceOriginal()
        XCTAssertEqual(saved, url)
        XCTAssertNil(model.errorMessage)
        try await waitFor("the reload") { model.isFullResolutionReady }
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo, "the replaced file is the new starting point")
        XCTAssertEqual(model.sourceSize, CGSize(width: 100, height: 100))

        let properties = EditorFixtures.properties(url)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int ?? 1, 1, "pixels are upright, so no rotation tag (no double turn)")
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100)
        XCTAssertEqual((properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFMake] as? String, "Canon",
                       "camera metadata survives")
        XCTAssertEqual(EditorFixtures.markers(try decoded(url)).red, .topRight)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        XCTAssertEqual(leftovers, ["replace.jpg"], "no temporary files next to the original")
    }

    @MainActor
    func testReplaceOriginalOnlyWhenItIsSafe() async throws {
        // Only the first frame is edited, so replacing an animated GIF or multi-page TIFF would lose the rest.
        let frames = [EditorFixtures.markerImage(), EditorFixtures.markerImage(alpha: true), EditorFixtures.markerImage()]
        for (name, type) in [("anim.gif", "com.compuserve.gif"), ("pages.tiff", "public.tiff")] {
            let model = try await open(fixtures.writeFrames(frames, name, type: type))
            XCTAssertEqual(model.exportFormat, FileFormat.detect(temp.file(name)))
            XCTAssertFalse(model.canReplaceOriginal, name)
            XCTAssertTrue(model.replaceHelp.contains("first"), model.replaceHelp)
        }

        let single = fixtures.write(EditorFixtures.markerImage(), "single.jpg")
        let model = try await open(single)
        XCTAssertTrue(model.canReplaceOriginal)
        model.exportFormat = .png
        XCTAssertFalse(model.canReplaceOriginal, "replacing keeps the original's format")
        XCTAssertEqual(model.replaceHelp, "Choose JPG to replace the original")

        let locked = fixtures.write(EditorFixtures.markerImage(), "locked.jpg")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let readOnly = try await open(locked)
        XCTAssertFalse(readOnly.canReplaceOriginal)
        await readOnly.replaceOriginal()   // ignored, not an error
        XCTAssertNil(readOnly.errorMessage)
    }

    @MainActor
    func testFormatChoices() {
        for source in [FileFormat.jpg, .png, .heic, .gif, .tiff, .ico, .icns, .svg, .raw, .psd, .webp] {
            let (primary, more) = EditorModel.formatChoices(for: source)
            XCTAssertEqual(primary.first, ImageEngine.editOutputFormat(for: source), "\(source)")
            XCTAssertLessThanOrEqual(primary.count, 4)
            XCTAssertEqual(Set(primary + more).count, primary.count + more.count, "\(source): no duplicates")
            XCTAssertTrue((primary + more).allSatisfy(ImageCodec.writableFormats.contains), "\(source)")
        }
        XCTAssertEqual(EditorModel.formatChoices(for: .ico).primary.first, .png, "icons are edited as PNG")
        XCTAssertEqual(EditorModel.formatChoices(for: .raw).primary.first, .jpg, "camera RAW saves as JPG")
    }
}

/// Bitwise CRC-32 for building PNG fixtures (independent of the engine's table version).
enum CRC32Reference {
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
        }
        return ~crc
    }
}

private extension EditorPipeline {
    /// Exports `recipe` for `url` at full resolution, like Save Copy does.
    func exporting(_ recipe: EditRecipe, from url: URL, to destination: URL) async throws {
        setFull(try ImageCodec.load(url))
        try await export(recipe, format: .png, quality: 0.9, options: ConversionOptions(), to: destination)
    }
}

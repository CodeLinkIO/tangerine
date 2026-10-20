import CoreGraphics
import Foundation
import ImageIO
@testable import TangerineApp
import TangerineKit
import XCTest

/// App-level logic that doesn't need windows: quality presets, preferences, the converter queue and the wheel.
/// Preferences use a throwaway UserDefaults suite, never the app's real domain.
@MainActor
final class AppLogicTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var suiteName: String!
    private var suite: UserDefaults!

    override func setUp() async throws {
        temp = try TemporaryDirectory()
        suiteName = "tangerine.tests.\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        temp = nil
    }

    @discardableResult
    private func dummy(_ path: String) throws -> URL {
        let url = temp.url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
        return url
    }

    // MARK: Quality presets

    func testQualityPresetsAdjustOnlyTheirOptions() {
        var custom = ConversionOptions()
        custom.imageMaxPixelSize = 2048
        custom.stripImageMetadata = true
        custom.pdfDPI = 150
        custom.videoResolution = .p480

        let small = QualityPreset.small.apply(to: custom)
        XCTAssertEqual(small.imageQuality, 0.6)
        XCTAssertEqual(small.videoQuality, 0.45)
        XCTAssertEqual(small.audioBitrateKbps, 128)
        XCTAssertEqual(small.videoResolution, .p480, "Small never raises a lower resolution")
        XCTAssertEqual(QualityPreset.small.apply(to: ConversionOptions()).videoResolution, .p1080, "Small caps Original at 1080p")

        let balanced = QualityPreset.balanced.apply(to: custom)
        XCTAssertEqual(balanced.imageQuality, 0.82)
        XCTAssertEqual(balanced.audioBitrateKbps, 192)
        XCTAssertEqual(balanced.videoResolution, .p480)

        let best = QualityPreset.best.apply(to: ConversionOptions())
        XCTAssertEqual(best.imageQuality, 0.95)
        XCTAssertEqual(best.videoQuality, 0.85)
        XCTAssertEqual(best.audioBitrateKbps, 320)
        XCTAssertEqual(best.videoResolution, .original)

        for preset in QualityPreset.allCases {
            let applied = preset.apply(to: custom)
            XCTAssertEqual(applied.imageMaxPixelSize, 2048, "\(preset)")
            XCTAssertTrue(applied.stripImageMetadata, "\(preset)")
            XCTAssertEqual(applied.pdfDPI, 150, "\(preset)")
        }
    }

    // MARK: Preferences

    func testPreferencesDefaultsWhenNothingIsSaved() {
        let prefs = Preferences(defaults: suite)
        XCTAssertEqual(prefs.convertKey, .shift)
        XCTAssertEqual(prefs.toolsKey, .command)
        XCTAssertTrue(prefs.dragWheelEnabled)
        XCTAssertTrue(prefs.finderShortcutEnabled)
        XCTAssertEqual(prefs.quality, .balanced)
        XCTAssertNil(prefs.outputFolder)
        XCTAssertFalse(prefs.replaceOriginals)
        XCTAssertFalse(prefs.revealInFinder)
        XCTAssertEqual(prefs.options, ConversionOptions())
        XCTAssertTrue(prefs.pinnedTargets.isEmpty)
        XCTAssertEqual(prefs.effectiveOptions.imageQuality, QualityPreset.balanced.imageQuality)
    }

    func testCorruptPreferencesFallBackToDefaults() {
        suite.set("hyper", forKey: "convertKey")
        suite.set(42, forKey: "toolsKey")
        suite.set("ultra", forKey: "quality")
        suite.set("yes", forKey: "dragWheelEnabled")
        suite.set(Data("garbage".utf8), forKey: "conversionOptions")
        suite.set(Data("{".utf8), forKey: "pinnedTargets")
        suite.set("not a bool", forKey: "replaceOriginals")
        let prefs = Preferences(defaults: suite)
        XCTAssertEqual(prefs.convertKey, .shift)
        XCTAssertEqual(prefs.toolsKey, .command)
        XCTAssertEqual(prefs.quality, .balanced)
        XCTAssertTrue(prefs.dragWheelEnabled)
        XCTAssertEqual(prefs.options, ConversionOptions())
        XCTAssertTrue(prefs.pinnedTargets.isEmpty)
        XCTAssertFalse(prefs.replaceOriginals, "anything unreadable must not turn on trashing originals")
    }

    func testOptionsSavedByAnotherVersionKeepTheirValues() throws {
        // Older builds lacked some keys; newer ones may add keys or enum cases.
        let json = #"{"imageQuality":0.5,"pdfDPI":150,"stripImageMetadata":true,"videoResolution":"p1440","futureOption":1}"#
        suite.set(Data(json.utf8), forKey: "conversionOptions")
        let options = Preferences(defaults: suite).options
        XCTAssertEqual(options.imageQuality, 0.5)
        XCTAssertEqual(options.pdfDPI, 150)
        XCTAssertTrue(options.stripImageMetadata)
        XCTAssertEqual(options.videoResolution, .original, "unknown values fall back individually")
        XCTAssertEqual(options.audioBitrateKbps, ConversionOptions().audioBitrateKbps)

        var round = ConversionOptions()
        round.imageMaxPixelSize = 1234
        round.audioSampleRate = 44100
        round.flattenBackground = .black
        let decoded = try JSONDecoder().decode(ConversionOptions.self, from: JSONEncoder().encode(round))
        XCTAssertEqual(decoded, round)
    }

    func testPreferencesPersistAndDropUnknownCategories() {
        let first = Preferences(defaults: suite)
        first.quality = .best
        first.pinnedTargets = [.image: [.webp, .png]]
        first.outputFolder = URL(fileURLWithPath: "/tmp/Tangerine Out", isDirectory: true)
        first.replaceOriginals = true

        let second = Preferences(defaults: suite)
        XCTAssertEqual(second.quality, .best)
        XCTAssertEqual(second.pinnedTargets, [.image: [.webp, .png]])
        XCTAssertEqual(second.outputFolder?.path, "/tmp/Tangerine Out")
        XCTAssertTrue(second.replaceOriginals)

        suite.set(Data(#"{"image":["png"],"hologram":["jpg"]}"#.utf8), forKey: "pinnedTargets")
        XCTAssertEqual(Preferences(defaults: suite).pinnedTargets, [.image: [.png]])
    }

    func testWheelTargetsWithPinnedFormats() {
        let prefs = Preferences(defaults: suite)
        let available: [FileFormat] = [.jpg, .png, .heic, .tiff, .gif, .pdf, .bmp, .ico, .icns, .jp2]
        XCTAssertEqual(prefs.wheelTargets(category: .image, available: available), Array(available.prefix(8)))

        prefs.pinnedTargets = [.image: [.webp, .png, .avif, .gif]]
        XCTAssertEqual(prefs.wheelTargets(category: .image, available: available), [.png, .gif],
                       "pins that are no longer available are skipped")
        prefs.pinnedTargets = [.image: [.webp, .avif]]
        XCTAssertEqual(prefs.wheelTargets(category: .image, available: available), Array(available.prefix(8)),
                       "with no usable pins the catalog order is used")
        prefs.pinnedTargets = [.image: available.reversed()]
        XCTAssertEqual(prefs.wheelTargets(category: .image, available: available).count, TargetCatalog.wheelCapacity)
        XCTAssertEqual(prefs.wheelTargets(category: .audio, available: [.mp3, .wav]), [.mp3, .wav], "other categories unaffected")
        XCTAssertEqual(prefs.wheelTargets(category: .image, available: []), [])
    }

    // MARK: Converter queue

    func testConverterQueueAddsEachSupportedFileOnce() throws {
        let model = ConverterModel()
        let jpg = try dummy("q/a.jpg")
        try dummy("q/notes.xyz")
        try dummy("q/sub/b.png")
        model.add([jpg])
        model.add([jpg, temp.url.appendingPathComponent("q")])
        XCTAssertEqual(model.items.map(\.url.lastPathComponent).sorted(), ["a.jpg", "b.png"])
        XCTAssertTrue(model.items.allSatisfy { $0.target == $0.targets.first || $0.targets.contains($0.target!) })
        XCTAssertEqual(model.pendingCount, 2)

        model.setTarget(.heic, for: try XCTUnwrap(model.items.last).id)
        model.add([try dummy("q/c.jpg")])
        XCTAssertEqual(model.items.last?.target, .heic, "new files default to the target chosen for their siblings")
    }

    func testSetTargetForAllRespectsSelectionAndSupport() throws {
        let model = ConverterModel()
        model.add([try dummy("s/a.jpg"), try dummy("s/b.png"), try dummy("s/c.pdf"), try dummy("s/d.md")])
        model.setTargetForAll(.png)
        let byName = { (name: String) in model.items.first { $0.url.lastPathComponent == name }! }
        XCTAssertEqual(byName("a.jpg").target, .png)
        XCTAssertNotEqual(byName("b.png").target, .png, "a PNG can't become a PNG")
        XCTAssertEqual(byName("c.pdf").target, .png)
        XCTAssertNotEqual(byName("d.md").target, .png, "documents don't convert to PNG")

        model.selection = [byName("a.jpg").id]
        model.setTargetForAll(.heic)
        XCTAssertEqual(byName("a.jpg").target, .heic)
        XCTAssertNotEqual(byName("c.pdf").target, .heic, "only the selection changes")

        model.remove([byName("a.jpg").id])
        XCTAssertTrue(model.selection.isEmpty)
        XCTAssertEqual(model.items.count, 3)
        model.clearFinished()
        XCTAssertEqual(model.items.count, 3, "nothing finished yet")
    }

    func testAllTargetsFollowTheDominantTypeAndNeedTwoItems() throws {
        let model = ConverterModel()
        XCTAssertEqual(model.allTargets, [])
        model.add([try dummy("t/only.pdf")])
        XCTAssertEqual(model.allTargets, Engine.shared.targets(from: .pdf), "one item: all of its targets")

        model.add([try dummy("t/a.jpg"), try dummy("t/b.jpg"), try dummy("t/c.heic")])
        let targets = model.allTargets
        XCTAssertEqual(targets.first, .jpg, "images dominate, so image order: JPG first")
        for target in targets {
            XCTAssertGreaterThanOrEqual(model.items.filter { $0.targets.contains(target) }.count, 2, "\(target)")
        }
        XCTAssertFalse(targets.contains(.docx), "only the PDF converts to DOCX")
    }

    func testAllTargetsTieGoesToTheFirstAddedType() throws {
        let pdf = try dummy("tie/a.pdf"), jpg = try dummy("tie/b.jpg")
        let pdfFirst = ConverterModel()
        pdfFirst.add([pdf, jpg])
        XCTAssertEqual(Array(pdfFirst.allTargets.prefix(2)), [.png, .txt], "PDF came first: PDF order (PNG, …, TXT)")
        let imageFirst = ConverterModel()
        imageFirst.add([jpg, pdf])
        XCTAssertEqual(Array(imageFirst.allTargets.prefix(2)), [.png, .heic], "image came first: image order (PNG, HEIC…)")
    }

    func testFeaturedTargetsAreFewAndIncludeTheCurrentChoice() throws {
        let model = ConverterModel()
        model.add([try dummy("f/a.jpg")])
        var item = model.items[0]
        XCTAssertLessThanOrEqual(model.featuredTargets(for: item).count, 5)
        let rare = try XCTUnwrap(item.targets.last)
        model.setTarget(rare, for: item.id)
        item = model.items[0]
        let featured = model.featuredTargets(for: item)
        XCTAssertTrue(featured.contains(rare))
        XCTAssertLessThanOrEqual(featured.count, 6)
        XCTAssertEqual(featured.count, Set(featured).count)
    }

    func testCancellingTheConverterReturnsTheItemToReady() async throws {
        // OCR on a large image is slow enough to cancel mid-way.
        let width = 3000, height = 3000
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = temp.url.appendingPathComponent("scan.png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let model = ConverterModel()
        model.outputFolder = temp.url.appendingPathComponent("out", isDirectory: true)
        model.add([url])
        model.setTarget(.txt, for: model.items[0].id)
        model.convertAll()
        let deadline = Date().addingTimeInterval(10)
        while case .ready = model.items[0].status, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        guard case .working = model.items[0].status else { throw XCTSkip("finished before it could be cancelled") }
        model.cancel()
        while model.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(model.isRunning)
        XCTAssertEqual(model.items[0].status, .ready, "a cancelled item isn't a failure")
        XCTAssertEqual(model.pendingCount, 1)
    }

    // MARK: Wheel

    func testWheelGeometryFindsPetals() {
        let center = CGPoint(x: 136, y: 136)
        XCTAssertNil(WheelGeometry.index(at: center, center: center, count: 8), "the center hole selects nothing")
        XCTAssertNil(WheelGeometry.index(at: CGPoint(x: center.x + WheelGeometry.inner - 5, y: center.y), center: center, count: 8))
        XCTAssertNil(WheelGeometry.index(at: CGPoint(x: 200, y: 0), center: center, count: 0))
        for count in 1...12 {
            for index in 0..<count {
                let label = WheelGeometry.labelPoint(index: index, count: count, center: center)
                XCTAssertEqual(WheelGeometry.index(at: label, center: center, count: count), index, "count \(count)")
                // Far beyond the rim still picks the same petal (quick flicks).
                let far = CGPoint(x: center.x + (label.x - center.x) * 10, y: center.y + (label.y - center.y) * 10)
                XCTAssertEqual(WheelGeometry.index(at: far, center: center, count: count), index, "count \(count) far")
            }
        }
        // Exactly between two petals lands on one of the neighbours, never out of range.
        for count in [2, 3, 8, 9] {
            let a = WheelGeometry.centerAngle(index: 0, count: count) - .pi / CGFloat(count)
            let point = CGPoint(x: center.x + cos(a) * 80, y: center.y + sin(a) * 80)
            let index = WheelGeometry.index(at: point, center: center, count: count)
            XCTAssertTrue(index == 0 || index == 1, "count \(count): \(String(describing: index))")
        }
        XCTAssertEqual(WheelGeometry.index(at: CGPoint(x: center.x, y: center.y + 60), center: center, count: 8), 0, "12 o'clock is first")
    }

    func testWheelItemsForEveryCategoryStayWithinCapacity() throws {
        let samples = ["a.jpg", "b.mp4", "c.mp3", "d.pdf", "e.md", "f.heic"]
        for name in samples {
            let file = try dummy("w/\(name)")
            let convert = WheelController.items(for: .convert, files: [file])
            XCTAssertFalse(convert.isEmpty, name)
            XCTAssertLessThanOrEqual(convert.count, TargetCatalog.wheelCapacity + 1, name)
            XCTAssertEqual(convert.last, .more, name)
            let formats = convert.compactMap { if case let .convert(format) = $0 { format } else { nil } }
            XCTAssertEqual(formats.count, Set(formats).count, "\(name): duplicate petals")
            XCTAssertTrue(formats.allSatisfy(Engine.shared.targets(for: [file]).contains), name)

            let tools = WheelController.items(for: .tools, files: [file])
            XCTAssertLessThanOrEqual(tools.count, TargetCatalog.wheelCapacity + 1, name)
        }
        let image = try dummy("w/g.png")
        XCTAssertEqual(WheelController.items(for: .tools, files: [image]).first, .tool(.openEditor))
        XCTAssertEqual(WheelController.items(for: .tools, files: [try dummy("w/h.md")]), [])

        let many = try (1...12).map { try dummy("w/many/\($0).jpg") }
        let manyTools = WheelController.items(for: .tools, files: many)
        XCTAssertFalse(manyTools.contains(.tool(.openEditor)))
        XCTAssertTrue(manyTools.contains(.tool(.mergePDF)))
        XCTAssertLessThanOrEqual(WheelController.items(for: .convert, files: many).count, TargetCatalog.wheelCapacity + 1)

        let unsupported = try dummy("w/x.xyz")
        XCTAssertEqual(WheelController.items(for: .convert, files: [unsupported]), [])
        XCTAssertEqual(WheelController.items(for: .tools, files: [unsupported]), [])
        XCTAssertEqual(WheelController.items(for: .convert, files: []), [])
    }

    func testWheelSummary() throws {
        XCTAssertEqual(WheelController.summary(of: [try dummy("sum/a.jpeg")]), "JPG")
        XCTAssertEqual(WheelController.summary(of: [temp.url.appendingPathComponent("sum", isDirectory: true)]), "Folder")
        XCTAssertEqual(WheelController.summary(of: [try dummy("sum/b.png"), try dummy("sum/c.md")]), "2 items")
        XCTAssertEqual(WheelController.summary(of: [try dummy("sum/d.xyz")]), "XYZ")
    }
}

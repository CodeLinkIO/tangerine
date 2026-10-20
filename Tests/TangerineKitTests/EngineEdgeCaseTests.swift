import CoreGraphics
import ImageIO
@testable import TangerineKit
import XCTest

/// Batch behavior around output names and folders.
final class EngineEdgeCaseTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let engine = Engine.shared

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    // XCTest keeps every test case alive until the run ends; release the folder so it gets deleted.
    override func tearDown() { temp = nil }

    private func image(_ name: String, type: String, shade: Double) throws -> URL {
        let context = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: shade, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        let url = temp.file(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testSameNamedInputsInOneBatchKeepEveryOutput() async throws {
        // "photo.jpg", "photo.png"… all become "photo.heic"; parallel jobs must not overwrite each other.
        let types = [("jpg", "public.jpeg"), ("png", "public.png"), ("tiff", "public.tiff"), ("bmp", "com.microsoft.bmp"),
                     ("gif", "com.compuserve.gif"), ("tga", "com.truevision.tga-image")]
        let inputs = try types.enumerated().map { index, type in
            try image("photo.\(type.0)", type: type.1, shade: Double(index) / Double(types.count))
        }
        let report = try await engine.convert(inputs, to: .heic)
        XCTAssertTrue(report.failures.isEmpty, report.failures.map(\.message).joined(separator: ", "))
        XCTAssertEqual(Set(report.outputs).count, inputs.count, "every input gets its own file: \(report.outputs.map(\.lastPathComponent))")
        XCTAssertTrue(report.outputs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Same base name from different folders into one chosen output folder.
        let out = temp.url.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let albums = try (1...4).map { try image("album\($0)/IMG_0001.jpg", type: "public.jpeg", shade: Double($0) / 4) }
        let merged = try await engine.convert(albums, to: .png, outputDirectory: out)
        XCTAssertEqual(Set(merged.outputs.map(\.lastPathComponent)), ["IMG_0001.png", "IMG_0001 2.png", "IMG_0001 3.png", "IMG_0001 4.png"])
        let tools = try await engine.run(.rotateRight, on: albums, outputDirectory: out)
        XCTAssertEqual(Set(tools.outputs).count, 4, "tools too: \(tools.outputs.map(\.lastPathComponent))")
    }

    func testReadOnlySourceFolderSavesElsewhere() throws {
        let folder = temp.url.appendingPathComponent("readonly", isDirectory: true)
        let photo = try image("readonly/photo.jpg", type: "public.jpeg", shade: 0.5)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        let directory = Engine.outputDirectory(for: photo, preferred: nil)
        XCTAssertNotEqual(directory.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(directory, FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first)
        XCTAssertEqual(Engine.outputDirectory(for: photo, preferred: temp.url), temp.url, "a chosen folder always wins")
    }
}

import CoreGraphics
import Foundation
import ImageIO
@testable import TangerineCLI
import TangerineKit
import XCTest

/// Runs the built `tangerine` binary end to end (exit codes, messages) plus a few parser unit tests.
final class CLITests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    override func tearDown() { temp = nil }

    private var binary: URL {
        get throws {
            let url = Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("tangerine")
            guard FileManager.default.isExecutableFile(atPath: url.path) else { throw XCTSkip("tangerine binary not built at \(url.path)") }
            return url
        }
    }

    private struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    private func tangerine(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = try binary
        process.arguments = arguments
        process.currentDirectoryURL = temp.url
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }

    @discardableResult
    private func png(_ name: String, width: Int = 64, height: Int = 48) throws -> URL {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.6, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let url = temp.file(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func contents() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: temp.url.path))
    }

    // MARK: Commands

    func testNoArgumentsHelpAndUnknownCommands() throws {
        let none = try tangerine([])
        XCTAssertEqual(none.status, 1)
        XCTAssertTrue(none.err.contains("Usage:"), none.err)

        for help in ["help", "--help", "-h"] {
            let run = try tangerine([help])
            XCTAssertEqual(run.status, 0, help)
            XCTAssertTrue(run.out.contains("tangerine convert"), help)
            XCTAssertTrue(run.out.contains("--quality 1-100"), "usage matches what the parser accepts")
        }

        let unknown = try tangerine(["transmogrify"])
        XCTAssertEqual(unknown.status, 1)
        XCTAssertTrue(unknown.err.contains("Unknown command"), unknown.err)
    }

    func testInvalidConvertArgumentsFailWithoutWritingAnything() throws {
        try png("a.png")
        let before = try contents()
        let cases: [([String], String)] = [
            (["convert", "a.png"], "Missing --to"),
            (["convert", "a.png", "--to"], "--to needs a value"),
            (["convert", "a.png", "--to", "xyz"], "Unknown format"),
            (["convert", "a.png", "--to", "jpg", "--quality", "0"], "--quality must be 1–100"),
            (["convert", "a.png", "--to", "jpg", "--quality", "101"], "--quality must be 1–100"),
            (["convert", "a.png", "--to", "jpg", "--quality", "-5"], "--quality must be 1–100"),
            (["convert", "a.png", "--to", "jpg", "--quality", "abc"], "--quality must be 1–100"),
            (["convert", "a.png", "--to", "jpg", "--quality", "nan"], "--quality must be 1–100"),
            (["convert", "a.png", "--to", "jpg", "--max-size", "0"], "--max-size must be a positive number"),
            (["convert", "a.png", "--to", "jpg", "--max-size", "-3"], "--max-size must be a positive number"),
            (["convert", "a.png", "--to", "jpg", "--dpi", "0"], "--dpi must be 36–1200"),
            (["convert", "a.png", "--to", "jpg", "--dpi", "5000"], "--dpi must be 36–1200"),
            (["convert", "a.png", "--to", "mp3", "--bitrate", "0"], "--bitrate must be a positive number"),
            (["convert", "a.png", "--to", "mp4", "--resolution", "999p"], "--resolution must be"),
            (["convert", "a.png", "--to", "mp4", "--codec", "vp9"], "--codec must be"),
            (["convert", "--to", "jpg"], "No input files"),
            (["convert", "missing.png", "--to", "jpg"], "No such file: missing.png"),
            (["convert", "a.png", "--to", "jpg", "--strip-metdata"], "Unknown option “--strip-metdata”"),
            (["convert", "a.png", "--to=jpg"], "Unknown option"),
            (["convert", "a.png", "--to", "png"], "Can't convert"),
        ]
        for (arguments, message) in cases {
            let run = try tangerine(arguments)
            XCTAssertEqual(run.status, 1, arguments.joined(separator: " "))
            XCTAssertTrue(run.err.contains(message), "\(arguments.joined(separator: " ")) → \(run.err)")
        }
        XCTAssertEqual(try contents(), before, "failed commands write nothing")
    }

    func testOutPointingToAFileFails() throws {
        try png("a.png")
        let file = temp.file("taken")
        try Data("keep me".utf8).write(to: file)
        let run = try tangerine(["convert", "a.png", "--to", "jpg", "--out", "taken"])
        XCTAssertEqual(run.status, 1)
        XCTAssertFalse(run.err.isEmpty)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep me")
    }

    func testSuccessfulConvertPrintsOutputsAndAppliesOptions() throws {
        try png("big.png", width: 400, height: 200)
        let run = try tangerine(["convert", "big.png", "--to", "JPEG", "--out", "out/", "--quality", "50", "--max-size", "100",
                                 "--strip-metadata"])
        XCTAssertEqual(run.status, 0, run.err)
        let path = run.out.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(path.hasSuffix("/out/big.jpg"), path)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 100)
        XCTAssertTrue(run.err.contains("Saved big.jpg"), run.err)
    }

    func testPartialFailureExitsOneButKeepsGoodOutputs() throws {
        try png("good.png")
        try Data("not an image".utf8).write(to: temp.file("bad.png"))
        let run = try tangerine(["convert", "good.png", "bad.png", "--to", "jpg"])
        XCTAssertEqual(run.status, 1)
        XCTAssertTrue(run.err.contains("error: bad.png"), run.err)
        XCTAssertTrue(run.out.contains("good.jpg"), run.out)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file("good.jpg").path))
    }

    func testFileNamesStartingWithDashes() throws {
        try png("-dash.png")
        try png("--odd.png")
        let run = try tangerine(["convert", "--to", "jpg", "-dash.png", "--", "--odd.png"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file("-dash.jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.file("--odd.jpg").path))
    }

    func testToolCommand() throws {
        try png("a.png")
        let cases: [([String], String)] = [
            (["tool"], "Unknown tool"),
            (["tool", "nope", "a.png"], "Unknown tool"),
            (["tool", "openEditor", "a.png"], "opens in the app"),
            (["tool", "compress"], "No input files"),
            (["tool", "compress", "a.xyz"], "No such file"),
        ]
        for (arguments, message) in cases {
            let run = try tangerine(arguments)
            XCTAssertEqual(run.status, 1, arguments.joined(separator: " "))
            XCTAssertTrue(run.err.contains(message), "\(arguments.joined(separator: " ")) → \(run.err)")
        }
        let rotate = try tangerine(["tool", "rotateRight", "a.png", "--out", "rotated"])
        XCTAssertEqual(rotate.status, 0, rotate.err)
        XCTAssertTrue(rotate.out.contains("/rotated/a rotated.png"), rotate.out)
    }

    func testFormatsCommand() throws {
        try png("a.png")
        let run = try tangerine(["formats", "a.png"])
        XCTAssertEqual(run.status, 0)
        XCTAssertTrue(run.out.contains("Convert to: JPG"), run.out)
        XCTAssertTrue(run.out.contains("compress"), run.out)
        let empty = try tangerine(["formats"])
        XCTAssertEqual(empty.status, 0)
        XCTAssertTrue(empty.out.contains("Convert to: —"), empty.out)
    }

    // MARK: Parser

    func testFormatNamesAcceptExtensionsAliasesAndDisplayNames() {
        let expected: [String: FileFormat] = [
            "jpg": .jpg, "JPEG": .jpg, ".png": .png, "tif": .tiff, "Markdown": .md, "md": .md, "alac": .alac,
            "m4a": .m4a, "3gp": .threeGP, "Web Archive": .webarchive, "htm": .html,
        ]
        for (name, format) in expected { XCTAssertEqual(FileFormat.parse(name), format, name) }
        XCTAssertNil(FileFormat.parse("nope"))
        XCTAssertNil(FileFormat.parse(""))
    }

    func testArgumentsParsing() throws {
        let parsed = try Arguments(["a.png", "--to", "jpg", "--strip-metadata", "-b.png", "--", "--to", "--c.png"])
        XCTAssertEqual(parsed.positional, ["a.png", "-b.png", "--to", "--c.png"])
        XCTAssertEqual(parsed.value("--to"), "jpg")
        XCTAssertThrowsError(try Arguments(["--qualty", "50"]))
        XCTAssertThrowsError(try Arguments(["--out"]))
        var options = try Arguments(["--quality", "100", "--dpi", "36", "--max-size", "1"])
        let parsedOptions = try options.conversionOptions()
        XCTAssertEqual(parsedOptions.imageQuality, 1)
        XCTAssertEqual(parsedOptions.pdfDPI, 36)
        XCTAssertEqual(parsedOptions.imageMaxPixelSize, 1)
    }
}

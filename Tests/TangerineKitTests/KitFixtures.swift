import CoreGraphics
import Foundation
import ImageIO
@testable import TangerineKit
import XCTest

/// Fixtures generated on the fly in a temporary folder (no binary fixtures in the repo).
struct KitFixtures {
    let root: URL

    init(_ temp: TemporaryDirectory) { root = temp.url }

    /// `root/<path>`, creating intermediate folders.
    func url(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A file whose content doesn't matter (capability checks only look at the extension).
    @discardableResult
    func dummy(_ path: String, _ contents: String = "x") throws -> URL {
        let url = try url(path)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// A real, decodable image.
    @discardableResult
    func image(_ path: String, type: String = "public.png", width: Int = 64, height: Int = 48,
               color: CGColor = CGColor(srgbRed: 0.9, green: 0.4, blue: 0.1, alpha: 1)) throws -> URL {
        let url = try url(path)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Encoded in memory: ImageIO can't open some long (but valid) file names for writing.
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url)
        return url
    }

    static func isDecodableImage(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }

    static func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    /// Paths with symlinks resolved, so /var/… and /private/var/… compare equal.
    static func paths(_ urls: [URL]) -> [String] { urls.map { $0.resolvingSymlinksInPath().path } }
}

/// Test double for MP3 → ALAC that writes `<name>.m4a` next to the input and drops `dropWhileRunning`
/// into the folder mid-job, like a user saving a new file there.
struct FakeAudioBackend: ConversionBackend {
    let id = "fake-audio"
    let dropWhileRunning: URL

    func supports(from: FileFormat, to: FileFormat) -> Bool { from == .mp3 && to == .alac }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL] {
        if !FileManager.default.fileExists(atPath: dropWhileRunning.path) {
            try Data("new".utf8).write(to: dropWhileRunning)
        }
        let destination = output.file(extension: to.fileExtension)
        try Data(input.path.utf8).write(to: destination)
        return [destination]
    }
}

/// Test double that "converts" PNG to JPG (and anything to TXT) by writing the input path into the
/// output, picking the output name first and writing later, like the real backends.
final class FakeConversionBackend: ConversionBackend, @unchecked Sendable {
    let id = "fake"
    var delayNanoseconds: UInt64 = 0
    var progressSteps: [Double] = []
    var failingNames: Set<String> = []
    let started = Locked<[URL]>([])
    let running = Locked<(now: Int, peak: Int)>((0, 0))

    func supports(from: FileFormat, to: FileFormat) -> Bool {
        (from == .png && to == .jpg) || (from != .txt && to == .txt)
    }

    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL] {
        started.mutate { $0.append(input) }
        running.mutate { $0.now += 1; $0.peak = max($0.peak, $0.now) }
        defer { running.mutate { $0.now -= 1 } }
        let destination = output.file(extension: to.fileExtension)
        let steps = progressSteps.isEmpty ? [1.0] : progressSteps
        for step in steps {
            context.progress(step)
            if delayNanoseconds > 0 { try await Task.sleep(nanoseconds: delayNanoseconds / UInt64(steps.count)) }
        }
        if failingNames.contains(input.lastPathComponent) {
            throw ConversionError.failed("Boom: \(input.lastPathComponent)")
        }
        try Data(input.path.utf8).write(to: destination)
        return [destination]
    }
}

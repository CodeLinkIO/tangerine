import AVFoundation
import ImageIO
@testable import TangerineKit
import XCTest

/// Batch behavior for audio, which the engine runs several files at a time, and targets that depend on content.
final class EngineMediaBatchTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
    }

    // XCTest keeps every test case alive until the run ends; release the folder so it gets deleted.
    override func tearDown() { temp = nil }

    /// Writes a 16-bit sine in the container implied by `name` (WAV, AIFF or CAF).
    private func tone(_ name: String, seconds: Double = 2, frequency: Float = 440) throws -> URL {
        let url = temp.file(name)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: url.pathExtension == "aiff",
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.3 * sinf(2 * .pi * frequency * Float(i) / 44_100)
        }
        try file.write(from: buffer)
        return url
    }

    func testSameNamedFilesInOneBatchGetSeparateOutputs() async throws {
        // "song.wav", "song.aiff" and "song.caf" all become "song.m4a"; none may overwrite another.
        let inputs = [try tone("song.wav", seconds: 1), try tone("song.aiff", seconds: 2), try tone("Song.caf", seconds: 3)]
        let report = try await Engine.shared.convert(inputs, to: .m4a)
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures.map(\.message))")
        let names = report.outputs.map(\.lastPathComponent)
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, 3, "\(names)")
        var durations: [Double] = []
        for output in report.outputs {
            durations.append(try await AVURLAsset(url: output).load(.duration).seconds.rounded())
        }
        XCTAssertEqual(durations.sorted(), [1, 2, 3], "every input kept its own output")
    }

    /// A short animated GIF, for making a clip without sound.
    private func animation(_ name: String) throws -> URL {
        let url = temp.file(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil))
        for shade in [0.2, 0.5, 0.8] {
            let context = CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(srgbRed: shade, green: 0.4, blue: 0.1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
            CGImageDestinationAddImage(destination, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testTargetsAndToolsFollowWhatTheFileHolds() async throws {
        let engine = Engine.shared
        let wav = try tone("voice.wav")

        // An MP4 that only holds sound offers audio formats, and nothing that needs a picture.
        let song = temp.file("song.mp4")
        let m4aReport = try await engine.convert([wav], to: .m4a)
        let m4a = try XCTUnwrap(m4aReport.outputs.first)
        try FileManager.default.moveItem(at: m4a, to: song)
        var targets = engine.targets(for: [song])
        XCTAssertTrue(targets.contains(.m4a) && targets.contains(.wav), "\(targets)")
        XCTAssertFalse(targets.contains { $0.category == .video || $0 == .gif }, "\(targets)")
        XCTAssertEqual(engine.tools(for: [song]), [.compress])

        // A clip without sound offers no audio formats and no Mute.
        try XCTSkipUnless(engine.targets(from: .gif).contains(.mp4), "needs ffmpeg with an H.264 encoder")
        let clipReport = try await engine.convert([try animation("clip.gif")], to: .mp4)
        let clip = try XCTUnwrap(clipReport.outputs.first, "\(clipReport.failures.map(\.message))")
        targets = engine.targets(for: [clip])
        XCTAssertTrue(targets.contains(.mov) && targets.contains(.gif), "\(targets)")
        XCTAssertFalse(targets.contains { $0.category == .audio }, "\(targets)")
        XCTAssertEqual(engine.tools(for: [clip]), [.compress])
        // Containers only ffmpeg reads are checked too.
        let mkvReport = try await engine.convert([clip], to: .mkv)
        let mkv = try XCTUnwrap(mkvReport.outputs.first, "\(mkvReport.failures.map(\.message))")
        XCTAssertFalse(engine.targets(for: [mkv]).contains { $0.category == .audio }, "\(engine.targets(for: [mkv]))")

        // Picture and sound: everything, including Mute.
        let both = temp.file("both.mp4")
        try await FFmpeg.shared.run(["-i", clip.path, "-i", wav.path, "-map", "0:v", "-map", "1:a",
                                     "-c:v", "copy", "-c:a", "aac", "-shortest", both.path])
        targets = engine.targets(for: [both])
        XCTAssertTrue(targets.contains(.m4a) && targets.contains(.mov) && targets.contains(.gif), "\(targets)")
        XCTAssertEqual(engine.tools(for: [both]), [.compress, .mute])

        // A target is only offered when every file can make it.
        XCTAssertFalse(engine.targets(for: [both, clip]).contains(.m4a))
        XCTAssertTrue(engine.targets(for: [both, clip]).contains(.mov))
    }
}

import AVFoundation
@testable import TangerineKit
import XCTest

/// Batch behavior for audio, which the engine runs several files at a time.
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
}

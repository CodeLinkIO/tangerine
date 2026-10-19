import AVFoundation
import CoreVideo
import Foundation
import TangerineCore
import XCTest

/// Builds small audio/video files with Apple frameworks only, so native tests never depend on ffmpeg.
actor Fixtures {
    static let shared = Fixtures()

    let directory: URL
    private var cache: [String: URL] = [:]

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TangerineMediaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Stereo 440 Hz sine WAV.
    func wav(seconds: Double = 1.5, sampleRate: Double = 44_100, channels: Int = 2, bitDepth: Int = 16) throws -> URL {
        let key = "sine-\(seconds)-\(Int(sampleRate))-\(channels)-\(bitDepth).wav"
        if let url = cache[key] { return url }
        let url = directory.appendingPathComponent(key)
        try Self.writeSine(to: url, seconds: seconds, sampleRate: sampleRate, channels: channels, bitDepth: bitDepth)
        cache[key] = url
        return url
    }

    /// 2-second 320×240 H.264 + AAC MP4.
    func mp4() async throws -> URL {
        if let url = cache["clip.mp4"] { return url }
        let silent = directory.appendingPathComponent("video-only.mov")
        try await Self.writeVideo(to: silent, seconds: 2, size: CGSize(width: 320, height: 240))
        let audio = try wav(seconds: 2)

        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent), audioAsset = AVURLAsset(url: audio)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audioTrack, at: .zero)

        let url = directory.appendingPathComponent("clip.mp4")
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        session.outputURL = url
        session.outputFileType = .mp4
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error ?? ConversionError.failed("fixture export") }
        cache["clip.mp4"] = url
        return url
    }

    /// Long ffmpeg-generated video for cancellation tests.
    func longVideo() async throws -> URL {
        if let url = cache["long.mp4"] { return url }
        let url = directory.appendingPathComponent("long.mp4")
        try await FFmpeg.shared.run(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi",
                                     "-i", "sine=frequency=440", "-t", "20", "-c:v", "libx264", "-preset", "ultrafast",
                                     "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path])
        cache["long.mp4"] = url
        return url
    }

    /// A fresh empty folder for one test's outputs.
    func outputFolder() throws -> URL {
        let url = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Writers

    private static func writeSine(to url: URL, seconds: Double, sampleRate: Double, channels: Int, bitDepth: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<channels {
            let samples = buffer.floatChannelData![channel]
            for i in 0..<Int(frames) {
                samples[i] = 0.4 * sinf(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
    }

    private static func writeVideo(to url: URL, seconds: Double, size: CGSize) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let fps = 30
        for frame in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
            let buffer = try XCTUnwrap(pixelBuffer)
            fill(buffer, frame: frame)
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.failed("fixture video") }
    }

    /// Orange background with a white square that moves each frame, so frames differ.
    private static func fill(_ buffer: CVPixelBuffer, frame: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let squareX = (frame * 5) % (width - 40)
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let inSquare = x >= squareX && x < squareX + 40 && y >= 100 && y < 140
                let pixel = row + x * 4
                pixel[0] = inSquare ? 255 : 40   // B
                pixel[1] = inSquare ? 255 : 91   // G
                pixel[2] = 255                   // R
                pixel[3] = 255                   // A
            }
        }
    }
}

/// Collects progress callbacks from any thread.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []

    var callback: @Sendable (Double) -> Void { { [self] value in lock.lock(); values.append(value); lock.unlock() } }

    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Facts about a media file, read with AVFoundation.
struct MediaInfo {
    var duration: Double
    var videoTracks: Int
    var audioTracks: Int
    var audioSubtype: FourCharCode?
    var videoSize: CGSize?

    static func read(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var subtype: FourCharCode?
        if let track = audio.first, let description = try await track.load(.formatDescriptions).first {
            subtype = CMFormatDescriptionGetMediaSubType(description)
        }
        var size: CGSize?
        if let track = video.first { size = try await track.load(.naturalSize) }
        return MediaInfo(duration: duration, videoTracks: video.count, audioTracks: audio.count,
                         audioSubtype: subtype, videoSize: size)
    }
}

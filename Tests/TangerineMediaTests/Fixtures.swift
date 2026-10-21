import AVFoundation
import CoreVideo
import Foundation
import TangerineCore
@testable import TangerineMedia
import XCTest

/// Builds small audio/video files with Apple frameworks only, so native tests never depend on ffmpeg.
actor Fixtures {
    static let shared = Fixtures()

    let directory: URL
    private var cache: [String: URL] = [:]
    /// Removed when the test process exits; the clips add up to ~100 MB per run.
    private nonisolated(unsafe) static var directoryToRemove: URL?

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TangerineMediaTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.directoryToRemove = directory
        atexit { if let url = Fixtures.directoryToRemove { try? FileManager.default.removeItem(at: url) } }
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
        let url = directory.appendingPathComponent("clip.mp4")
        try await Self.mux(video: silent, audio: try wav(seconds: 2), seconds: 2, to: url)
        cache["clip.mp4"] = url
        return url
    }

    /// Silent H.264 MOV (no audio track) written with AVAssetWriter. `transform` becomes the track's
    /// preferred transform, e.g. a 90° rotation like a portrait phone recording.
    func silentVideo(seconds: Double = 1, width: Int = 160, height: Int = 120, fps: Int = 30,
                     transform: CGAffineTransform = .identity) async throws -> URL {
        let key = "silent-\(seconds)-\(width)x\(height)-\(fps)-\(transform.b).mov"
        if let url = cache[key] { return url }
        let url = directory.appendingPathComponent(key)
        try await Self.writeVideo(to: url, seconds: seconds, size: CGSize(width: width, height: height), fps: fps,
                                  transform: transform)
        cache[key] = url
        return url
    }

    /// Small H.264 + AAC MP4 with the given video properties.
    func clip(seconds: Double = 1, width: Int = 160, height: Int = 120, fps: Int = 30,
              transform: CGAffineTransform = .identity) async throws -> URL {
        let key = "clip-\(seconds)-\(width)x\(height)-\(fps)-\(transform.b).mp4"
        if let url = cache[key] { return url }
        let silent = try await silentVideo(seconds: seconds, width: width, height: height, fps: fps, transform: transform)
        let url = directory.appendingPathComponent(key)
        try await Self.mux(video: silent, audio: try wav(seconds: max(seconds, 0.1)), seconds: seconds, to: url)
        cache[key] = url
        return url
    }

    /// An MP4 that only holds AAC audio (what some recorders and downloaders produce).
    func audioOnlyMP4(seconds: Double = 1.5, sampleRate: Double = 44_100, channels: Int = 2) async throws -> URL {
        let key = "audio-only-\(seconds)-\(Int(sampleRate))-\(channels).mp4"
        if let url = cache[key] { return url }
        let url = directory.appendingPathComponent(key)
        let source = try wav(seconds: seconds, sampleRate: sampleRate, channels: channels)
        try await NativeAudioBackend.encode(source, to: .m4a, writingTo: url, options: ConversionOptions())
        cache[key] = url
        return url
    }

    /// MOV with uncompressed (LPCM) audio, like screen recordings and pro cameras; MP4 can't hold it as-is.
    func lpcmMOV() async throws -> URL {
        if let url = cache["lpcm.mov"] { return url }
        let video = AVURLAsset(url: try await silentVideo()), audio = AVURLAsset(url: try wav(seconds: 1))
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600))
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await video.loadTracks(withMediaType: .video)[0], at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: try await audio.loadTracks(withMediaType: .audio)[0], at: .zero)
        let url = directory.appendingPathComponent("lpcm.mov")
        try await Self.export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mov, to: url)
        cache["lpcm.mov"] = url
        return url
    }

    /// A long native video made by repeating the 2-second clip, for cancellation tests without ffmpeg.
    func longNativeVideo(repeats: Int = 60) async throws -> URL {
        let key = "long-native-\(repeats).mov"
        if let url = cache[key] { return url }
        let asset = AVURLAsset(url: try await mp4())
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        for index in 0..<repeats {
            try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset,
                                                  at: CMTimeMultiply(duration, multiplier: Int32(index)))
        }
        let url = directory.appendingPathComponent(key)
        try await Self.export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mov, to: url)
        cache[key] = url
        return url
    }

    /// Builds a fixture with ffmpeg (lavfi sources); skips the test when ffmpeg isn't installed.
    func ffmpegFixture(_ name: String, _ arguments: [String]) async throws -> URL {
        try XCTSkipUnless(FFmpeg.fixtures.isAvailable, "ffmpeg not installed")
        if let url = cache[name] { return url }
        let url = directory.appendingPathComponent(name)
        try await FFmpeg.fixtures.run(arguments + [url.path])
        cache[name] = url
        return url
    }

    /// Copies a fixture under a new name into a fresh folder.
    func copy(_ url: URL, named name: String) throws -> URL {
        let target = try outputFolder().appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: target)
        return target
    }

    /// Writes raw bytes (empty, garbage or truncated media) into a fresh folder.
    func file(named name: String, contents: Data) throws -> URL {
        let target = try outputFolder().appendingPathComponent(name)
        try contents.write(to: target)
        return target
    }

    /// Long ffmpeg-generated video for cancellation tests.
    func longVideo() async throws -> URL {
        if let url = cache["long.mp4"] { return url }
        let url = directory.appendingPathComponent("long.mp4")
        try await FFmpeg.fixtures.run(["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30", "-f", "lavfi",
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

    private static func mux(video: URL, audio: URL, seconds: Double, to url: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: audio)
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        let (videoRange, transform) = try await videoTrack.load(.timeRange, .preferredTransform)
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(videoRange.duration,
                                                                     CMTime(seconds: seconds, preferredTimescale: 600)))
        let videoCopy = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try videoCopy.insertTimeRange(range, of: videoTrack, at: .zero)
        videoCopy.preferredTransform = transform
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(range, of: audioTrack, at: .zero)
        try await export(composition, preset: AVAssetExportPresetHighestQuality, fileType: .mp4, to: url)
    }

    private static func export(_ asset: AVAsset, preset: String, fileType: AVFileType, to url: URL) async throws {
        let session = try XCTUnwrap(AVAssetExportSession(asset: asset, presetName: preset))
        session.outputURL = url
        session.outputFileType = fileType
        await withCheckedContinuation { continuation in session.exportAsynchronously { continuation.resume() } }
        guard session.status == .completed else { throw session.error ?? ConversionError.failed("fixture export") }
    }

    private static func writeVideo(to url: URL, seconds: Double, size: CGSize, fps: Int = 30,
                                   transform: CGAffineTransform = .identity) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<max(1, Int(seconds * Double(fps))) {
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
        let squareX = (frame * 5) % max(1, width - 40)
        let squareY = min(100, max(0, height / 2 - 20))
        for y in 0..<height {
            let row = base + y * stride
            for x in 0..<width {
                let inSquare = x >= squareX && x < squareX + 40 && y >= squareY && y < squareY + 40
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
    private let forward: (@Sendable (Double) -> Void)?

    /// `forward` also receives every value, e.g. to cancel a job once it's under way.
    init(_ forward: (@Sendable (Double) -> Void)? = nil) {
        self.forward = forward
    }

    var callback: @Sendable (Double) -> Void {
        { [self] value in
            lock.lock(); values.append(value); lock.unlock()
            forward?(value)
        }
    }

    var all: [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

/// Facts about a media file, read with AVFoundation.
struct MediaInfo {
    var duration: Double
    var videoTracks: Int
    var audioTracks: Int
    var audioSubtype: FourCharCode?
    var videoSize: CGSize?
    /// Size as displayed, after the track's preferred transform (rotation).
    var displaySize: CGSize?
    var videoSubtype: FourCharCode?
    var audioChannels: Int?
    var audioSampleRate: Double?

    static func read(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var subtype: FourCharCode?, channels: Int?, rate: Double?
        if let track = audio.first, let description = try await track.load(.formatDescriptions).first {
            subtype = CMFormatDescriptionGetMediaSubType(description)
            if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                channels = Int(basic.mChannelsPerFrame)
                rate = basic.mSampleRate
            }
        }
        var size: CGSize?, display: CGSize?, videoSubtype: FourCharCode?
        if let track = video.first {
            let (natural, transform, descriptions) = try await track.load(.naturalSize, .preferredTransform, .formatDescriptions)
            size = natural
            let rotated = CGRect(origin: .zero, size: natural).applying(transform)
            display = CGSize(width: abs(rotated.width).rounded(), height: abs(rotated.height).rounded())
            videoSubtype = descriptions.first.map(CMFormatDescriptionGetMediaSubType)
        }
        return MediaInfo(duration: duration, videoTracks: video.count, audioTracks: audio.count,
                         audioSubtype: subtype, videoSize: size, displaySize: display, videoSubtype: videoSubtype,
                         audioChannels: channels, audioSampleRate: rate)
    }
}

extension FFmpeg {
    /// The ffmpeg that makes and checks test files. Set TANGERINE_FIXTURE_FFMPEG to a full build (Homebrew's)
    /// to test a lighter one through TANGERINE_FFMPEG, such as the copy bundled in the app.
    static let fixtures: FFmpeg = ProcessInfo.processInfo.environment["TANGERINE_FIXTURE_FFMPEG"]
        .map { FFmpeg(path: $0) } ?? .shared
}

import AVFoundation
import ImageIO
@testable import TangerineCore
@testable import TangerineMedia
import XCTest

final class NativeAudioTests: XCTestCase {
    private let backend = NativeAudioBackend()

    private func convert(_ input: URL, to: FileFormat, options: ConversionOptions = ConversionOptions()) async throws -> URL {
        let from = try XCTUnwrap(FileFormat.detect(input))
        XCTAssertTrue(backend.supports(from: from, to: to), "\(from) → \(to)")
        let plan = OutputPlan(directory: try await Fixtures.shared.outputFolder(), baseName: "out")
        let outputs = try await backend.convert(input, from: from, to: to, output: plan, context: ConversionContext(options: options))
        let url = try XCTUnwrap(outputs.first)
        XCTAssertEqual(url.pathExtension, to.fileExtension)
        XCTAssertGreaterThan(url.fileSize, 0)
        return url
    }

    func testWAVToLossyAndLosslessFormats() async throws {
        let wav = try await Fixtures.shared.wav()
        let expected: [FileFormat: FourCharCode] = [
            .m4a: kAudioFormatMPEG4AAC, .alac: kAudioFormatAppleLossless, .flac: kAudioFormatFLAC,
            .aiff: kAudioFormatLinearPCM, .caf: kAudioFormatLinearPCM, .m4r: kAudioFormatMPEG4AAC,
        ]
        for (target, codec) in expected {
            let url = try await convert(wav, to: target)
            let info = try await MediaInfo.read(url)
            XCTAssertEqual(info.audioTracks, 1, "\(target)")
            XCTAssertEqual(info.duration, 1.5, accuracy: 0.1, "\(target)")
            XCTAssertEqual(info.audioSubtype, codec, "\(target)")
        }
    }

    func testFLACRoundTripKeeps24Bit() async throws {
        let wav24 = try await Fixtures.shared.wav(bitDepth: 24)
        let flac = try await convert(wav24, to: .flac)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(flac), 24)
        let back = try await convert(flac, to: .wav)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(back), 24)
    }

    func testSampleRateOption() async throws {
        var options = ConversionOptions()
        options.audioSampleRate = 22_050
        let url = try await convert(try await Fixtures.shared.wav(), to: .aiff, options: options)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 22_050)
    }

    func testRingtoneIsTrimmedTo40Seconds() async throws {
        let long = try await Fixtures.shared.wav(seconds: 45, sampleRate: 8_000, channels: 1)
        let ringtone = try await convert(long, to: .m4r)
        let info = try await MediaInfo.read(ringtone)
        XCTAssertLessThanOrEqual(info.duration, 40.5)
        XCTAssertGreaterThan(info.duration, 39)
    }

    func testDoesNotClaimFFmpegFormats() {
        XCTAssertFalse(backend.supports(from: .ogg, to: .wav))
        XCTAssertFalse(backend.supports(from: .wav, to: .mp3))
        XCTAssertFalse(backend.supports(from: .wav, to: .wav))
        XCTAssertFalse(backend.supports(from: .mp4, to: .m4a))
    }
}

final class AVVideoTests: XCTestCase {
    private let backend = AVVideoBackend()

    private func convert(_ input: URL, to: FileFormat, progress: ProgressLog? = nil) async throws -> URL {
        let from = try XCTUnwrap(FileFormat.detect(input))
        XCTAssertTrue(backend.supports(from: from, to: to), "\(from) → \(to)")
        let plan = OutputPlan(directory: try await Fixtures.shared.outputFolder(), baseName: "out")
        let context = ConversionContext(progress: (progress ?? ProgressLog()).callback)
        let outputs = try await backend.convert(input, from: from, to: to, output: plan, context: context)
        let url = try XCTUnwrap(outputs.first)
        XCTAssertGreaterThan(url.fileSize, 0)
        return url
    }

    func testMP4ToMOVPassthrough() async throws {
        let progress = ProgressLog()
        let mov = try await convert(try await Fixtures.shared.mp4(), to: .mov, progress: progress)
        XCTAssertEqual(mov.pathExtension, "mov")
        let info = try await MediaInfo.read(mov)
        XCTAssertEqual(info.videoTracks, 1)
        XCTAssertEqual(info.audioTracks, 1)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        XCTAssertEqual(progress.all.last, 1)
    }

    func testMP4ToM4VAndAudioExtraction() async throws {
        let mp4 = try await Fixtures.shared.mp4()
        let m4v = try await MediaInfo.read(try await convert(mp4, to: .m4v))
        XCTAssertEqual(m4v.videoTracks, 1)

        for target in [FileFormat.m4a, .wav, .aiff, .flac, .alac, .caf, .m4r] {
            let info = try await MediaInfo.read(try await convert(mp4, to: target))
            XCTAssertEqual(info.videoTracks, 0, "\(target)")
            XCTAssertEqual(info.audioTracks, 1, "\(target)")
            XCTAssertEqual(info.duration, 2, accuracy: 0.15, "\(target)")
        }
    }

    func testNativeGIF() async throws {
        let out = try await Fixtures.shared.outputFolder().appendingPathComponent("native.gif")
        try await AVHelpers.writeGIF(from: AVURLAsset(url: try await Fixtures.shared.mp4()), to: out, fps: 10, width: 160,
                                     progress: { _ in })
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 20)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(properties?[kCGImagePropertyPixelWidth] as? Int, 160)
    }

    func testGIFRoutesToFFmpegWhenAvailable() {
        XCTAssertEqual(backend.supports(from: .mp4, to: .gif), !FFmpeg.shared.isAvailable)
        let none = AVVideoBackend(ffmpeg: FFmpeg(path: nil))
        XCTAssertTrue(none.supports(from: .mp4, to: .gif))
        XCTAssertFalse(none.supports(from: .mkv, to: .mp4))
        XCTAssertFalse(none.supports(from: .mp4, to: .mp3))
    }

    func testReencodePresetsMatchOptions() {
        var options = ConversionOptions()
        options.videoCodec = .hevc
        options.videoResolution = .p1080
        XCTAssertEqual(AVVideoBackend.reencodePreset(options), AVAssetExportPresetHEVC1920x1080)
        options.videoCodec = .h264
        options.videoResolution = .p720
        XCTAssertEqual(AVVideoBackend.reencodePreset(options), AVAssetExportPreset1280x720)
    }
}

final class MediaToolTests: XCTestCase {
    private let tools = MediaToolBackend()

    private func run(_ tool: ToolID, _ input: URL) async throws -> ToolOutput {
        let format = try XCTUnwrap(FileFormat.detect(input))
        XCTAssertTrue(tools.supports(tool, format: format))
        let folder = try await Fixtures.shared.outputFolder()
        return try await tools.run(tool, inputs: [input], output: OutputPlan(directory: folder, baseName: "clip"),
                                   context: ConversionContext())
    }

    func testMuteDropsAudio() async throws {
        let result = try await run(.mute, try await Fixtures.shared.mp4())
        let url = try XCTUnwrap(result.files.first)
        XCTAssertEqual(url.lastPathComponent, "clip muted.mp4")
        let info = try await MediaInfo.read(url)
        XCTAssertEqual(info.videoTracks, 1)
        XCTAssertEqual(info.audioTracks, 0)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
    }

    func testCompressWAVMakesSmallerM4A() async throws {
        let wav = try await Fixtures.shared.wav()
        let result = try await run(.compress, wav)
        let url = try XCTUnwrap(result.files.first)
        XCTAssertEqual(url.lastPathComponent, "clip compressed.m4a")
        XCTAssertLessThan(url.fileSize, wav.fileSize)
        XCTAssertNil(result.note)
    }

    func testCompressReportsAlreadyOptimized() async throws {
        // A 32 kbps AAC file can't get smaller by re-encoding at 128 kbps.
        let folder = try await Fixtures.shared.outputFolder()
        let small = folder.appendingPathComponent("small.m4a")
        try await NativeAudioBackend.encode(try await Fixtures.shared.wav(channels: 1), to: .m4a, writingTo: small,
                                            options: ConversionOptions(), bitrateKbps: 32)
        let result = try await run(.compress, small)
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.note, "Already optimized")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.contains("compressed") }
        XCTAssertTrue(leftovers.isEmpty, "\(leftovers)")
    }

    func testCompressVideo() async throws {
        let mp4 = try await Fixtures.shared.mp4()
        let result = try await run(.compress, mp4)
        if let url = result.files.first {
            XCTAssertEqual(url.lastPathComponent, "clip compressed.mp4")
            XCTAssertLessThan(url.fileSize, mp4.fileSize)
            let info = try await MediaInfo.read(url)
            XCTAssertEqual(info.videoTracks, 1)
        } else {
            XCTAssertEqual(result.note, "Already optimized")
        }
    }

    func testCompressVideoWithoutFFmpeg() async throws {
        let native = MediaToolBackend(ffmpeg: FFmpeg(path: nil))
        let mp4 = try await Fixtures.shared.mp4()
        let folder = try await Fixtures.shared.outputFolder()
        let result = try await native.run(.compress, inputs: [mp4], output: OutputPlan(directory: folder, baseName: "clip"),
                                          context: ConversionContext())
        XCTAssertTrue(result.files.count == 1 || result.note == "Already optimized")
        XCTAssertFalse(native.supports(.compress, format: .mkv))
        XCTAssertFalse(native.supports(.mute, format: .webm))
    }

    func testCompressRealisticVideoShrinks() async throws {
        try XCTSkipUnless(FFmpeg.fixtures.hasEncoder("libx264"))
        let long = try await Fixtures.shared.longVideo()
        let result = try await run(.compress, long)
        let url = try XCTUnwrap(result.files.first, result.note ?? "no output")
        XCTAssertLessThan(url.fileSize, long.fileSize / 2)
        let info = try await MediaInfo.read(url)
        XCTAssertEqual(info.duration, 20, accuracy: 0.2)
    }

    func testToolSupport() {
        XCTAssertTrue(tools.supports(.compress, format: .mov))
        XCTAssertTrue(tools.supports(.compress, format: .flac))
        XCTAssertFalse(tools.supports(.mute, format: .mp3))
        XCTAssertFalse(tools.supports(.rotateRight, format: .mp4))
    }
}

final class FFmpegMediaTests: XCTestCase {
    private let backend = FFmpegMediaBackend()

    override func setUpWithError() throws {
        try XCTSkipUnless(FFmpeg.shared.isAvailable, "ffmpeg not installed")
    }

    private func convert(_ input: URL, to: FileFormat, options: ConversionOptions = ConversionOptions(),
                         requires encoders: [String] = []) async throws -> URL {
        for encoder in encoders {
            try XCTSkipUnless(FFmpeg.shared.hasEncoder(encoder), "ffmpeg lacks \(encoder)")
        }
        let from = try XCTUnwrap(FileFormat.detect(input))
        XCTAssertTrue(backend.supports(from: from, to: to), "\(from) → \(to)")
        let plan = OutputPlan(directory: try await Fixtures.shared.outputFolder(), baseName: "out")
        let progress = ProgressLog()
        let outputs = try await backend.convert(input, from: from, to: to, output: plan,
                                                context: ConversionContext(options: options, progress: progress.callback))
        let url = try XCTUnwrap(outputs.first)
        XCTAssertEqual(url.pathExtension, to.fileExtension)
        XCTAssertGreaterThan(url.fileSize, 0)
        XCTAssertEqual(progress.all.last, 1)
        try await assertDecodes(url)
        return url
    }

    /// Uses ffmpeg itself to verify containers AVFoundation can't open.
    private func assertDecodes(_ url: URL) async throws {
        let result = try await Shell.execute(FFmpeg.fixtures.path!, ["-v", "error", "-i", url.path, "-f", "null", "-"])
        XCTAssertEqual(result.status, 0, "\(url.lastPathComponent) failed to decode: \(result.stderr)")
    }

    func testVideoContainers() async throws {
        let mp4 = try await Fixtures.shared.mp4()
        _ = try await convert(mp4, to: .mkv)
        _ = try await convert(mp4, to: .webm, requires: ["libvpx-vp9", "libopus"])
        _ = try await convert(mp4, to: .avi, requires: ["mpeg4"])
        _ = try await convert(mp4, to: .wmv, requires: ["wmv2", "wmav2"])
    }

    func testMKVBackToMP4AndResolutionCap() async throws {
        let mkv = try await convert(try await Fixtures.shared.mp4(), to: .mkv)
        var options = ConversionOptions()
        options.videoResolution = .p480
        options.videoCodec = .hevc
        let mp4 = try await convert(mkv, to: .mp4, options: options)
        let info = try await MediaInfo.read(mp4)
        XCTAssertEqual(info.videoTracks, 1)
        XCTAssertEqual(info.audioTracks, 1)
        XCTAssertEqual(info.videoSize, CGSize(width: 320, height: 240), "smaller sources are not upscaled")
    }

    func testPaletteGIF() async throws {
        let gif = try await convert(try await Fixtures.shared.mp4(), to: .gif)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(gif as CFURL, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 10)
    }

    func testAudioTargets() async throws {
        let wav = try await Fixtures.shared.wav()
        let mp4 = try await Fixtures.shared.mp4()
        let mp3 = try await convert(wav, to: .mp3, requires: ["libmp3lame"])
        let mp3Info = try await MediaInfo.read(mp3)
        XCTAssertEqual(mp3Info.duration, 1.5, accuracy: 0.1)
        _ = try await convert(mp4, to: .mp3, requires: ["libmp3lame"])
        _ = try await convert(wav, to: .opus, requires: ["libopus"])
        _ = try await convert(wav, to: .wma, requires: ["wmav2"])
        let ogg = try await convert(wav, to: .ogg)
        // ffmpeg-only input back to a native format.
        let back = try await convert(ogg, to: .wav)
        let backInfo = try await MediaInfo.read(back)
        XCTAssertEqual(backInfo.audioTracks, 1)
    }

    func testMisnamedVorbisGoesToFFmpeg() async throws {
        // Core Audio accepts an Ogg Vorbis file named .mp3 and writes a few milliseconds of noise.
        let vorbis = FFmpeg.fixtures.hasEncoder("libvorbis") ? ["-c:a", "libvorbis"] : ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
        let ogg = try await Fixtures.shared.ffmpegFixture("vorbis.ogg", ["-f", "lavfi", "-i", "sine=frequency=440:duration=1.5"] + vorbis)
        let disguised = try await Fixtures.shared.outputFolder().appendingPathComponent("vorbis.mp3")
        try FileManager.default.copyItem(at: ogg, to: disguised)
        let outputs = try await NativeAudioBackend().convert(disguised, from: .mp3, to: .wav,
                                                             output: OutputPlan(for: disguised), context: ConversionContext())
        let info = try await MediaInfo.read(try XCTUnwrap(outputs.first))
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.1)
    }

    func testNativeAudioFallsBackToFFmpeg() async throws {
        // An Ogg file with an .mp3 name: Core Audio refuses it, ffmpeg probes the real contents.
        let ogg = try await convert(try await Fixtures.shared.wav(), to: .ogg)
        let folder = try await Fixtures.shared.outputFolder()
        let disguised = folder.appendingPathComponent("disguised.mp3")
        try FileManager.default.copyItem(at: ogg, to: disguised)
        let outputs = try await NativeAudioBackend().convert(disguised, from: .mp3, to: .wav,
                                                             output: OutputPlan(for: disguised), context: ConversionContext())
        let info = try await MediaInfo.read(try XCTUnwrap(outputs.first))
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.1)
    }

    func testCancellationStopsFFmpeg() async throws {
        try XCTSkipUnless(FFmpeg.shared.hasEncoder("libvpx-vp9") && FFmpeg.fixtures.hasEncoder("libx264"))
        let long = try await Fixtures.shared.longVideo()
        let folder = try await Fixtures.shared.outputFolder()
        let task = Task {
            try await backend.convert(long, from: .mp4, to: .webm, output: OutputPlan(directory: folder, baseName: "slow"),
                                      context: ConversionContext())
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch ConversionError.cancelled {
            // expected
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    func testSupportMatrix() {
        XCTAssertTrue(backend.supports(from: .mkv, to: .mp4))
        XCTAssertTrue(backend.supports(from: .webm, to: .mp3) == FFmpeg.shared.hasEncoder("libmp3lame"))
        XCTAssertFalse(backend.supports(from: .mp3, to: .mp4), "audio can't become video")
        XCTAssertFalse(backend.supports(from: .png, to: .webp), "images belong to the image engine")
        XCTAssertFalse(FFmpegMediaBackend(ffmpeg: FFmpeg(path: nil)).supports(from: .mkv, to: .mp4))
    }

    func testEngineOrderPrefersNative() {
        let first = { (from: FileFormat, to: FileFormat) in
            MediaEngine.conversionBackends.first { $0.supports(from: from, to: to) }?.id
        }
        XCTAssertEqual(first(.wav, .flac), "afconvert")
        XCTAssertEqual(first(.mov, .mp4), "avfoundation-video")
        XCTAssertEqual(first(.wav, .mp3), "ffmpeg-media")
        XCTAssertEqual(first(.mp4, .gif), "ffmpeg-media")
        XCTAssertEqual(first(.mkv, .mp4), "ffmpeg-media")
    }
}

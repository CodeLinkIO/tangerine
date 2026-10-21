import AVFoundation
import ImageIO
@testable import TangerineCore
@testable import TangerineMedia
import XCTest

// MARK: - Helpers

/// Converts with the first backend that claims `from → to`, the way TangerineKit's Engine routes jobs.
@discardableResult
private func engineConvert(_ input: URL, to: FileFormat, options: ConversionOptions = ConversionOptions(),
                           backends: [any ConversionBackend] = MediaEngine.conversionBackends,
                           folder: URL? = nil, baseName: String? = nil, progress: ProgressLog? = nil,
                           file: StaticString = #filePath, line: UInt = #line) async throws -> URL {
    let from = try XCTUnwrap(FileFormat.detect(input), file: file, line: line)
    let backend = try XCTUnwrap(backends.first { $0.supports(from: from, to: to) }, "\(from) → \(to) isn't offered",
                                file: file, line: line)
    let directory = if let folder { folder } else { try await Fixtures.shared.outputFolder() }
    let plan = baseName.map { OutputPlan(directory: directory, baseName: $0) } ?? OutputPlan(for: input, directory: directory)
    let context = ConversionContext(options: options, progress: (progress ?? ProgressLog()).callback)
    let outputs = try await backend.convert(input, from: from, to: to, output: plan, context: context)
    let url = try XCTUnwrap(outputs.first, file: file, line: line)
    XCTAssertEqual(url.pathExtension, to.fileExtension, file: file, line: line)
    XCTAssertGreaterThan(url.fileSize, 0, file: file, line: line)
    return url
}

/// Whether any of `backends` offers `from → to`.
private func offered(_ from: FileFormat, _ to: FileFormat,
                     backends: [any ConversionBackend] = MediaEngine.conversionBackends) -> Bool {
    backends.contains { $0.supports(from: from, to: to) }
}

private func runTool(_ tool: ToolID, _ input: URL, backend: MediaToolBackend = MediaToolBackend(), folder: URL? = nil,
                     progress: ProgressLog? = nil) async throws -> ToolOutput {
    let directory = if let folder { folder } else { try await Fixtures.shared.outputFolder() }
    return try await backend.run(tool, inputs: [input], output: OutputPlan(for: input, directory: directory),
                                 context: ConversionContext(progress: (progress ?? ProgressLog()).callback))
}

/// Visible files in `folder`.
private func contents(_ folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
}

/// Expects `work` to throw a `ConversionError` with a readable message and returns the message.
@discardableResult
private func expectFailure(_ label: String, file: StaticString = #filePath, line: UInt = #line,
                           _ work: () async throws -> Any) async -> String {
    do {
        let result = try await work()
        XCTFail("\(label): expected an error, got \(result)", file: file, line: line)
    } catch let error as ConversionError {
        let message = error.localizedDescription
        XCTAssertFalse(message.isEmpty, label, file: file, line: line)
        // No raw tool output: log prefixes, four-char codes, bare error numbers or temp paths.
        for junk in ["@ 0x", "('", "unknown error", "could not be completed", FileManager.default.temporaryDirectory.path] {
            XCTAssertFalse(message.contains(junk), "\(label): unreadable error “\(message)”", file: file, line: line)
        }
        return message
    } catch {
        XCTFail("\(label): expected a ConversionError, got \(error)", file: file, line: line)
    }
    return ""
}

private func assertMonotonic(_ values: [Double], _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertFalse(values.isEmpty, "\(label): no progress", file: file, line: line)
    XCTAssertTrue(values.allSatisfy { (0...1).contains($0) }, "\(label): out of range \(values)", file: file, line: line)
    if let index = values.indices.dropFirst().first(where: { values[$0] < values[$0 - 1] - 0.000_1 }) {
        XCTFail("\(label): progress went backwards at \(index): \(values)", file: file, line: line)
    }
    XCTAssertEqual(values.last, 1, "\(label): \(values)", file: file, line: line)
}

/// Decodes `url` fully with ffmpeg; skips the check when ffmpeg is missing.
private func assertDecodes(_ url: URL, file: StaticString = #filePath, line: UInt = #line) async throws {
    guard let ffmpeg = FFmpeg.fixtures.path else { return }
    let result = try await Shell.execute(ffmpeg, ["-v", "error", "-i", url.path, "-f", "null", "-"])
    XCTAssertEqual(result.status, 0, "\(url.lastPathComponent) doesn't decode: \(result.stderr)", file: file, line: line)
}

/// ffmpeg's one-line description of the first audio stream, e.g. "Audio: mp3, 44100 Hz, stereo, fltp, 128 kb/s".
private func ffmpegAudioStream(_ url: URL) async throws -> String {
    guard let ffmpeg = FFmpeg.fixtures.path else { return "" }
    let result = try await Shell.execute(ffmpeg, ["-hide_banner", "-i", url.path])
    return result.stderr.split(separator: "\n").first { $0.contains("Audio:") }.map(String.init) ?? ""
}

/// Processes whose command line mentions `token` (e.g. a per-test folder name).
private func processes(mentioning token: String) async throws -> [String] {
    let result = try await Shell.execute("/usr/bin/pgrep", ["-fl", token])
    return result.stdout.split(separator: "\n").map(String.init).filter { !$0.contains("pgrep") }
}

private func gifFrames(_ url: URL) throws -> (count: Int, width: Int, height: Int, delay: Double) {
    let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
    return (CGImageSourceGetCount(source), properties?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            properties?[kCGImagePropertyPixelHeight] as? Int ?? 0,
            gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0)
}

private let noFFmpeg = FFmpeg(path: nil)
private let nativeBackends: [any ConversionBackend] = [AVVideoBackend(ffmpeg: noFFmpeg), NativeAudioBackend(ffmpeg: noFFmpeg),
                                                        FFmpegMediaBackend(ffmpeg: noFFmpeg)]
private let audioTargets = TargetCatalog.orderedTargets(for: .audio)
/// A 90° clockwise rotation, as written by phones recording in portrait.
private let portrait = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 120, ty: 0)

/// H.264 encoder for ffmpeg-built fixtures.
private var fixtureH264: String { FFmpeg.fixtures.hasEncoder("libx264") ? "libx264" : "h264_videotoolbox" }

// MARK: - Unusual content

final class MediaContentEdgeCaseTests: XCTestCase {
    func testVideoWithoutAudioFailsClearlyForAudioTargets() async throws {
        let silent = try await Fixtures.shared.silentVideo()
        let folder = try await Fixtures.shared.outputFolder()
        for target in [FileFormat.m4a, .wav, .aiff, .flac, .m4r, .mp3, .ogg, .opus, .wma] where offered(.mov, target) {
            let message = await expectFailure("\(target)") { try await engineConvert(silent, to: target, folder: folder) }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("no audio"), "\(target): \(message)")
        }
        XCTAssertEqual(contents(folder), [])
    }

    func testMuteAndConvertSilentVideo() async throws {
        let silent = try await Fixtures.shared.silentVideo()
        let mutedFiles = try await runTool(.mute, silent).files
        let muted = try XCTUnwrap(mutedFiles.first)
        var info = try await MediaInfo.read(muted)
        XCTAssertEqual(info.videoTracks, 1)
        XCTAssertEqual(info.audioTracks, 0)
        XCTAssertEqual(info.duration, 1, accuracy: 0.1)

        info = try await MediaInfo.read(try await engineConvert(silent, to: .mp4))
        XCTAssertEqual(info.videoTracks, 1)
        XCTAssertEqual(info.audioTracks, 0)
        if FFmpeg.shared.isAvailable {
            for target in [FileFormat.mkv, .webm, .avi, .wmv] where offered(.mov, target) {
                try await assertDecodes(try await engineConvert(silent, to: target))
            }
        }
    }

    func testAudioOnlyMP4() async throws {
        let audioOnly = try await Fixtures.shared.audioOnlyMP4()
        for target in [FileFormat.m4a, .wav, .flac, .m4r, .mp3, .opus] where offered(.mp4, target) {
            let url = try await engineConvert(audioOnly, to: target)
            if target != .opus {
                let info = try await MediaInfo.read(url)
                XCTAssertEqual(info.audioTracks, 1, "\(target)")
                XCTAssertEqual(info.duration, 1.5, accuracy: 0.1, "\(target)")
            }
        }
        // A container change keeps the audio and yields an audio-only movie.
        let mov = try await MediaInfo.read(try await engineConvert(audioOnly, to: .mov))
        XCTAssertEqual(mov.audioTracks, 1)
        XCTAssertEqual(mov.videoTracks, 0)
        // Targets that need a picture fail clearly.
        for target in [FileFormat.gif, .webm, .mkv] where offered(.mp4, target) {
            let message = await expectFailure("\(target)") { try await engineConvert(audioOnly, to: target) }
            XCTAssertTrue(message.localizedCaseInsensitiveContains("no video"), "\(target): \(message)")
        }
        let message = await expectFailure("mute") { try await runTool(.mute, audioOnly) }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("no video"), message)
    }

    func testThreeGPInput() async throws {
        let folder = try await Fixtures.shared.outputFolder()
        let threeGP = folder.appendingPathComponent("phone.3gp")
        try await AVHelpers.export(AVURLAsset(url: try await Fixtures.shared.clip()), preset: AVAssetExportPresetPassthrough,
                                   to: threeGP, fileType: .mobile3GPP, progress: { _ in })
        for target in [FileFormat.mp4, .mov, .m4a, .wav, .gif] {
            try await engineConvert(threeGP, to: target)
        }
        let mutedFiles = try await runTool(.mute, threeGP).files
        let muted = try XCTUnwrap(mutedFiles.first)
        XCTAssertEqual(muted.pathExtension, "3gp")
        let info = try await MediaInfo.read(muted)
        XCTAssertEqual(info.audioTracks, 0)
        XCTAssertEqual(info.videoTracks, 1)
    }

    func testEmptyAndNonMediaFilesFailCleanly() async throws {
        let cases: [(String, Data)] = [
            ("empty.mp4", Data()), ("notes.mp4", Data("just some text, not a movie\n".utf8)),
            ("empty.mov", Data()), ("empty.wav", Data()), ("notes.mp3", Data("ID3? no.".utf8)),
            ("random.m4a", Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })),
            ("empty.mkv", Data()), ("notes.ogg", Data("OggS but not really".utf8)),
        ]
        for (name, data) in cases {
            let input = try await Fixtures.shared.file(named: name, contents: data)
            let folder = input.deletingLastPathComponent()
            let format = try XCTUnwrap(FileFormat.detect(input))
            let targets: [FileFormat] = format.category == .video ? [.mov, .m4v, .m4a, .wav, .gif, .mp3, .webm]
                : [.m4a, .flac, .wav, .m4r, .mp3, .opus]
            for target in targets where target != format && offered(format, target) {
                await expectFailure("\(name) → \(target)") { try await engineConvert(input, to: target, folder: folder) }
            }
            let tools = MediaToolBackend()
            for tool in [ToolID.compress, .mute] where tools.supports(tool, format: format) {
                await expectFailure("\(name) \(tool)") { try await runTool(tool, input, folder: folder) }
            }
            XCTAssertEqual(contents(folder), [name], "\(name): leftovers")
        }
    }

    func testFFmpegErrorsAreReadable() async throws {
        try XCTSkipUnless(FFmpeg.shared.isAvailable, "ffmpeg not installed")
        let input = try await Fixtures.shared.file(named: "fake.mkv", contents: Data("hello".utf8))
        let message = await expectFailure("garbage mkv") { try await engineConvert(input, to: .mp4) }
        XCTAssertFalse(message.contains(input.path), "error leaks the full path: \(message)")
        XCTAssertFalse(message.contains("@ 0x"), "error leaks ffmpeg internals: \(message)")
        XCTAssertTrue(message.localizedCaseInsensitiveContains("damaged") || message.localizedCaseInsensitiveContains("invalid"),
                      message)
    }

    func testTruncatedVideoFailsOrProducesShorterOutput() async throws {
        // A normal export (index at the end) and a fast-start one (index first) behave differently when cut short.
        let clip = try await Fixtures.shared.mp4()
        let fastStart = try await engineConvert(clip, to: .mov)
        for source in [clip, fastStart] {
            let data = try Data(contentsOf: source)
            let name = "cut." + source.pathExtension
            let input = try await Fixtures.shared.file(named: name, contents: data.prefix(data.count / 2))
            let folder = input.deletingLastPathComponent()
            let format = try XCTUnwrap(FileFormat.detect(input))
            for target in [FileFormat.mp4, .mov, .m4a, .wav] where target != format {
                do {
                    let url = try await engineConvert(input, to: target, folder: folder)
                    let info = try await MediaInfo.read(url)
                    XCTAssertLessThanOrEqual(info.duration, 2.1, "\(name) → \(target)")
                } catch let error as ConversionError {
                    XCTAssertFalse(error.localizedDescription.isEmpty)
                }
            }
            let outputs = contents(folder).filter { $0 != name }
            for output in outputs {
                XCTAssertGreaterThan(folder.appendingPathComponent(output).fileSize, 0, "\(output) is empty")
            }
        }
    }

    func testSingleFrameVideo() async throws {
        let clip = try await Fixtures.shared.clip(seconds: 1.0 / 30)
        var options = ConversionOptions()
        options.videoResolution = .p480
        for (target, options) in [(FileFormat.mov, ConversionOptions()), (.m4v, options), (.gif, ConversionOptions())] {
            try await engineConvert(clip, to: target, options: options)
        }
        let native = try await Fixtures.shared.outputFolder().appendingPathComponent("one.gif")
        try await AVHelpers.writeGIF(from: AVURLAsset(url: clip), to: native, fps: 12, width: 160, progress: { _ in })
        XCTAssertEqual(try gifFrames(native).count, 1)
        let muted = try await runTool(.mute, clip).files
        let info = try await MediaInfo.read(try XCTUnwrap(muted.first))
        XCTAssertEqual(info.videoTracks, 1)
    }

    func testVeryShortAudio() async throws {
        let blip = try await Fixtures.shared.wav(seconds: 0.05)
        for target in audioTargets where target != .wav && offered(.wav, target) {
            if target == .flac, !FFmpeg.shared.isAvailable {
                // afconvert writes an unreadable FLAC for under one block (~0.1 s); only ffmpeg can make it.
                let folder = try await Fixtures.shared.outputFolder()
                await expectFailure("short flac") { try await engineConvert(blip, to: .flac, folder: folder) }
                XCTAssertEqual(contents(folder), [])
                continue
            }
            let url = try await engineConvert(blip, to: target)
            try await assertDecodes(url)
            if target != .opus, target != .ogg, target != .wma {
                XCTAssertNotNil(try? AVAudioFile(forReading: url), "\(target) isn't readable")
            }
        }
        // Without ffmpeg the short FLAC fails cleanly instead of leaving a broken file.
        let native = NativeAudioBackend(ffmpeg: noFFmpeg)
        let folder = try await Fixtures.shared.outputFolder()
        let message = await expectFailure("short flac without ffmpeg") {
            try await native.convert(blip, from: .wav, to: .flac, output: OutputPlan(directory: folder, baseName: "blip"),
                                     context: ConversionContext())
        }
        XCTAssertTrue(message.contains("FLAC"), message)
        XCTAssertEqual(contents(folder), [])
    }

    func testRingtonesAreTrimmedFromEveryRoute() async throws {
        let long = try await Fixtures.shared.wav(seconds: 45, sampleRate: 8_000, channels: 1)
        var sources = [try await Fixtures.shared.audioOnlyMP4(seconds: 45, sampleRate: 8_000, channels: 1)]
        if FFmpeg.shared.isAvailable {
            sources.append(try await engineConvert(long, to: .ogg))
            if offered(.wav, .mp3) { sources.append(try await engineConvert(long, to: .mp3)) }
        }
        for source in sources {
            let progress = ProgressLog()
            let ringtone = try await engineConvert(source, to: .m4r, progress: progress)
            let info = try await MediaInfo.read(ringtone)
            XCTAssertLessThanOrEqual(info.duration, 40.5, source.lastPathComponent)
            XCTAssertGreaterThan(info.duration, 39, source.lastPathComponent)
            XCTAssertEqual(info.audioSubtype, kAudioFormatMPEG4AAC)
            assertMonotonic(progress.all, "m4r from \(source.pathExtension)")
        }
    }
}

// MARK: - Unusual properties

final class MediaPropertyEdgeCaseTests: XCTestCase {
    func testOddPixelDimensions() async throws {
        let odd = try await Fixtures.shared.silentVideo(width: 321, height: 241)
        let passthrough = try await MediaInfo.read(try await engineConvert(odd, to: .mp4))
        XCTAssertEqual(passthrough.videoSize?.width ?? 0, 321, accuracy: 1)

        var options = ConversionOptions()
        options.videoResolution = .p480
        let reencoded = try await MediaInfo.read(try await engineConvert(odd, to: .m4v, options: options))
        XCTAssertEqual(reencoded.videoTracks, 1)

        try XCTSkipUnless(FFmpeg.shared.isAvailable, "ffmpeg not installed")
        let mkv = try await engineConvert(odd, to: .mkv)
        for codec in VideoCodec.allCases {
            options = ConversionOptions()
            options.videoCodec = codec
            let mp4 = try await engineConvert(mkv, to: .mp4, options: options)
            let info = try await MediaInfo.read(mp4)
            XCTAssertEqual(info.videoSize, CGSize(width: 320, height: 240), "\(codec): yuv420p needs even sizes")
            try await assertDecodes(mp4)
        }
        for target in [FileFormat.webm, .avi, .wmv] where offered(.mkv, target) {
            try await assertDecodes(try await engineConvert(mkv, to: target))
        }
        let compressed = try await runTool(.compress, odd)
        if let url = compressed.files.first { try await assertDecodes(url) }
    }

    func testPortraitVideoStaysPortrait() async throws {
        let clip = try await Fixtures.shared.clip(transform: portrait)
        let source = try await MediaInfo.read(clip)
        XCTAssertEqual(source.displaySize, CGSize(width: 120, height: 160), "fixture should be portrait")

        var outputs = [("mov", try await engineConvert(clip, to: .mov))]
        var options = ConversionOptions()
        options.videoResolution = .p480
        outputs.append(("m4v 480p", try await engineConvert(clip, to: .m4v, options: options)))
        options.videoCodec = .hevc
        options.videoResolution = .original
        outputs.append(("hevc mov", try await engineConvert(clip, to: .mov, options: options)))
        outputs += try await runTool(.mute, clip).files.map { ("mute", $0) }
        if let compressed = try await runTool(.compress, clip).files.first { outputs.append(("compress", compressed)) }
        if FFmpeg.shared.isAvailable {
            let mkv = try await engineConvert(clip, to: .mkv)
            outputs.append(("mkv → mp4", try await engineConvert(mkv, to: .mp4)))
            outputs.append(("mkv → mov 480p", try await engineConvert(mkv, to: .mov, options: options)))
        }
        for (label, url) in outputs {
            let info = try await MediaInfo.read(url)
            let size = try XCTUnwrap(info.displaySize, label)
            XCTAssertLessThan(size.width, size.height, "\(label) lost the portrait orientation: \(size)")
        }

        let native = try await Fixtures.shared.outputFolder().appendingPathComponent("portrait.gif")
        try await AVHelpers.writeGIF(from: AVURLAsset(url: clip), to: native, fps: 10, width: 480, progress: { _ in })
        var gif = try gifFrames(native)
        XCTAssertLessThan(gif.width, gif.height, "native GIF")
        if offered(.mp4, .gif, backends: [FFmpegMediaBackend()]) {
            gif = try gifFrames(try await engineConvert(clip, to: .gif))
            XCTAssertLessThan(gif.width, gif.height, "ffmpeg GIF")
        }
    }

    func testHighFrameRateVideo() async throws {
        let fast = try await Fixtures.shared.silentVideo(seconds: 0.5, fps: 120)
        var options = ConversionOptions()
        options.videoResolution = .p720
        let reencoded = try await MediaInfo.read(try await engineConvert(fast, to: .mp4, options: options))
        XCTAssertEqual(reencoded.duration, 0.5, accuracy: 0.05)

        let native = try await Fixtures.shared.outputFolder().appendingPathComponent("fast.gif")
        try await AVHelpers.writeGIF(from: AVURLAsset(url: fast), to: native, fps: 120, width: 160, progress: { _ in })
        XCTAssertEqual(try gifFrames(native).count, 15, "native GIFs are capped at 30 fps")

        if FFmpeg.shared.isAvailable {
            options = ConversionOptions()
            options.gifFPS = 50
            let gif = try gifFrames(try await engineConvert(fast, to: .gif, options: options))
            XCTAssertEqual(Double(gif.count), 25, accuracy: 2)
            XCTAssertEqual(gif.delay, 0.02, accuracy: 0.001)
        }
    }

    func testSurroundAudio() async throws {
        let surround = try await Fixtures.shared.ffmpegFixture("surround.wav", [
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "1",
            "-af", "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-c:a", "pcm_s16le",
        ])
        for target in audioTargets where target != .wav && offered(.wav, target) {
            let url = try await engineConvert(surround, to: target)
            try await assertDecodes(url)
            if target == .mp3 || target == .wma {
                let stream = try await ffmpegAudioStream(url)
                XCTAssertTrue(stream.contains("stereo"), "\(target) should downmix: \(stream)")
            }
        }
        let movie = try await Fixtures.shared.ffmpegFixture("surround.mp4", [
            "-f", "lavfi", "-i", "testsrc=size=160x120:rate=30", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "1", "-af", "pan=5.1|c0=c0|c1=c0|c2=c0|c3=c0|c4=c0|c5=c0", "-c:v", fixtureH264, "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-shortest",
        ])
        let wav = try await MediaInfo.read(try await engineConvert(movie, to: .wav))
        XCTAssertEqual(wav.audioChannels, 2, "PCM extraction mixes down to stereo")
        for target in [FileFormat.m4a, .mov, .mp3, .webm, .wmv, .mkv] where offered(.mp4, target) {
            try await assertDecodes(try await engineConvert(movie, to: target))
        }
    }

    func testMonoAudioToEveryTarget() async throws {
        let mono = try await Fixtures.shared.wav(seconds: 1, channels: 1)
        for target in audioTargets where target != .wav && offered(.wav, target) {
            let url = try await engineConvert(mono, to: target)
            try await assertDecodes(url)
        }
        if offered(.mp4, .mp3) {
            try await assertDecodes(try await engineConvert(try await Fixtures.shared.audioOnlyMP4(channels: 1), to: .mp3))
        }
    }

    func testUnusualSampleRates() async throws {
        for (rate, channels) in [(8_000.0, 1), (96_000.0, 2)] {
            let source = try await Fixtures.shared.wav(seconds: 1, sampleRate: rate, channels: channels)
            for target in audioTargets where target != .wav && offered(.wav, target) {
                let url = try await engineConvert(source, to: target)
                try await assertDecodes(url)
                if [.flac, .aiff, .caf, .alac].contains(target) {
                    let info = try await MediaInfo.read(url)
                    XCTAssertEqual(info.audioSampleRate, rate, "\(target) at \(rate) should stay lossless")
                }
            }
        }
    }

    func testTwentyFourBitLosslessRoundTrips() async throws {
        let wav24 = try await Fixtures.shared.wav(bitDepth: 24)
        let aiff = try await engineConvert(wav24, to: .aiff)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(aiff), 24)
        let flac = try await engineConvert(aiff, to: .flac)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(flac), 24)
        let aiffAgain = try await engineConvert(flac, to: .aiff)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(aiffAgain), 24)
        let alac = try await engineConvert(aiffAgain, to: .alac)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(alac), 24)
        let back = try await engineConvert(alac, to: .wav)
        XCTAssertEqual(NativeAudioBackend.sourceBitDepth(back), 24)
        let info = try await MediaInfo.read(back)
        XCTAssertEqual(info.duration, 1.5, accuracy: 0.01)
        XCTAssertEqual(info.audioChannels, 2)
    }

    func testSampleRateOptionAcrossBackends() async throws {
        var options = ConversionOptions()
        options.audioSampleRate = 22_050
        let wav = try await Fixtures.shared.wav()
        for target in [FileFormat.m4a, .flac, .aiff, .m4r, .mp3, .wma] where offered(.wav, target) {
            let url = try await engineConvert(wav, to: target, options: options)
            if target == .wma {
                let stream = try await ffmpegAudioStream(url)
                XCTAssertTrue(stream.contains("22050 Hz"), stream)
            } else {
                let info = try await MediaInfo.read(url)
                XCTAssertEqual(info.audioSampleRate, 22_050, "\(target)")
            }
        }
        let fromVideo = try await MediaInfo.read(try await engineConvert(try await Fixtures.shared.mp4(), to: .wav, options: options))
        XCTAssertEqual(fromVideo.audioSampleRate, 22_050)
    }
}

// MARK: - Options

final class MediaOptionEdgeCaseTests: XCTestCase {
    func testNativeResolutionsNeverUpscale() async throws {
        let clip = try await Fixtures.shared.mp4()    // 320×240
        for codec in VideoCodec.allCases {
            for resolution in VideoResolution.allCases {
                var options = ConversionOptions()
                options.videoCodec = codec
                options.videoResolution = resolution
                let label = "\(codec) \(resolution)"
                let info = try await MediaInfo.read(try await engineConvert(clip, to: .mov, options: options))
                let size = try XCTUnwrap(info.videoSize, label)
                XCTAssertLessThanOrEqual(size.width, 320, "\(label) upscaled to \(size)")
                XCTAssertLessThanOrEqual(size.height, 240, "\(label) upscaled to \(size)")
            }
        }
        // A larger source is brought down to the requested height.
        let wide = try await Fixtures.shared.silentVideo(seconds: 0.3, width: 960, height: 540)
        var options = ConversionOptions()
        options.videoResolution = .p480
        let downscaled = try await MediaInfo.read(try await engineConvert(wide, to: .mp4, options: options))
        let size = try XCTUnwrap(downscaled.videoSize)
        XCTAssertLessThanOrEqual(size.height, 480)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.02)
    }

    func testFFmpegResolutionsAndCodecs() async throws {
        try XCTSkipUnless(FFmpeg.shared.isAvailable, "ffmpeg not installed")
        let small = try await engineConvert(try await Fixtures.shared.mp4(), to: .mkv)
        let large = try await Fixtures.shared.ffmpegFixture("hd.mkv", [
            "-f", "lavfi", "-i", "testsrc=size=1280x720:rate=30", "-t", "0.5", "-c:v", fixtureH264, "-pix_fmt", "yuv420p",
        ])
        let tall = try await Fixtures.shared.ffmpegFixture("tall.mkv", [
            "-f", "lavfi", "-i", "testsrc=size=720x1280:rate=30", "-t", "0.5", "-c:v", fixtureH264, "-pix_fmt", "yuv420p",
        ])
        let expected: [VideoResolution: (small: CGSize, large: CGSize, tall: CGSize)] = [
            .original: (CGSize(width: 320, height: 240), CGSize(width: 1280, height: 720), CGSize(width: 720, height: 1280)),
            .p2160: (CGSize(width: 320, height: 240), CGSize(width: 1280, height: 720), CGSize(width: 720, height: 1280)),
            .p1080: (CGSize(width: 320, height: 240), CGSize(width: 1280, height: 720), CGSize(width: 720, height: 1280)),
            .p720: (CGSize(width: 320, height: 240), CGSize(width: 1280, height: 720), CGSize(width: 720, height: 1280)),
            .p480: (CGSize(width: 320, height: 240), CGSize(width: 854, height: 480), CGSize(width: 480, height: 854)),
        ]
        for codec in VideoCodec.allCases {
            for resolution in VideoResolution.allCases {
                var options = ConversionOptions()
                options.videoCodec = codec
                options.videoResolution = resolution
                let label = "\(codec) \(resolution)"
                let sizes = try XCTUnwrap(expected[resolution])
                for (source, size) in [(small, sizes.small), (large, sizes.large), (tall, sizes.tall)] {
                    let info = try await MediaInfo.read(try await engineConvert(source, to: .mp4, options: options))
                    XCTAssertEqual(info.videoSize, size, "\(label) \(source.lastPathComponent)")
                    XCTAssertEqual(info.videoSubtype, codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264, label)
                }
            }
        }
    }

    func testVideoQualityExtremes() async throws {
        try XCTSkipUnless(FFmpeg.shared.isAvailable, "ffmpeg not installed")
        let mkv = try await engineConvert(try await Fixtures.shared.clip(), to: .mkv)
        for quality in [-1.0, 0, 1, 5] {
            for codec in VideoCodec.allCases {
                var options = ConversionOptions()
                options.videoQuality = quality
                options.videoCodec = codec
                try await assertDecodes(try await engineConvert(mkv, to: .mp4, options: options))
            }
            var options = ConversionOptions()
            options.videoQuality = quality
            for target in [FileFormat.webm, .avi, .wmv] where offered(.mkv, target) {
                try await assertDecodes(try await engineConvert(mkv, to: target, options: options))
            }
        }
    }

    func testGIFOptionExtremes() async throws {
        let clip = try await Fixtures.shared.mp4()    // 2 s, 320×240
        for (fps, width) in [(0, 0), (1, -10), (1_000, 10_000), (12, 16)] {
            let label = "fps \(fps) width \(width)"
            let native = try await Fixtures.shared.outputFolder().appendingPathComponent("native.gif")
            try await AVHelpers.writeGIF(from: AVURLAsset(url: clip), to: native, fps: fps, width: width, progress: { _ in })
            var gif = try gifFrames(native)
            XCTAssertTrue((1...60).contains(gif.count), "native \(label): \(gif.count) frames")
            XCTAssertTrue((16...320).contains(gif.width), "native \(label): width \(gif.width)")

            guard offered(.mp4, .gif, backends: [FFmpegMediaBackend()]) else { continue }
            var options = ConversionOptions()
            options.gifFPS = fps
            options.gifWidth = width
            gif = try gifFrames(try await engineConvert(clip, to: .gif, options: options))
            XCTAssertTrue((1...100).contains(gif.count), "ffmpeg \(label): \(gif.count) frames")
            XCTAssertTrue((16...320).contains(gif.width), "ffmpeg \(label): width \(gif.width)")
        }
    }

    func testAudioBitrateExtremes() async throws {
        let wav = try await Fixtures.shared.wav(seconds: 1)
        let clip = try await Fixtures.shared.mp4()
        for kbps in [8, 0, -1, 320, 100_000] {
            var options = ConversionOptions()
            options.audioBitrateKbps = kbps
            for target in [FileFormat.m4a, .m4r, .mp3, .ogg, .opus, .wma] where offered(.wav, target) {
                try await assertDecodes(try await engineConvert(wav, to: target, options: options))
            }
            for target in [FileFormat.m4a, .mp3, .webm, .mkv, .avi] where offered(.mp4, target) {
                try await assertDecodes(try await engineConvert(clip, to: target, options: options))
            }
        }
    }
}

// MARK: - Files and folders

final class MediaFileSystemEdgeCaseTests: XCTestCase {
    private var lockedFolders: [URL] = []

    override func tearDown() {
        for folder in lockedFolders {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        }
        super.tearDown()
    }

    func testAwkwardFileNames() async throws {
        let names = ["my clip", "ünïcødé 🎬 ﬁlm", "it's \"quoted\" `tick`", "-i", "-y -f null", "%d %s %%", "file:clip",
                     "a|b;c&d $(echo hi)", "e\u{301}cole", " leading and trailing ", "dots.in.name.."]
        let clip = try await Fixtures.shared.clip()
        let wav = try await Fixtures.shared.wav(seconds: 0.5)
        for name in names {
            let video = try await Fixtures.shared.copy(clip, named: name + ".mp4")
            let audio = try await Fixtures.shared.copy(wav, named: name + ".wav")
            var outputs: [URL] = []
            for target in [FileFormat.mov, .m4a, .mkv, .gif] where offered(.mp4, target) {
                outputs.append(try await engineConvert(video, to: target))
            }
            for target in [FileFormat.flac, .m4r, .mp3] where offered(.wav, target) {
                outputs.append(try await engineConvert(audio, to: target))
            }
            outputs += try await runTool(.mute, video).files
            outputs += try await runTool(.compress, audio).files
            for output in outputs {
                XCTAssertTrue(output.lastPathComponent.hasPrefix(name), "\(name): \(output.lastPathComponent)")
                XCTAssertGreaterThan(output.fileSize, 0, output.lastPathComponent)
            }
        }
    }

    func testExistingOutputsAreNeverOverwritten() async throws {
        let clip = try await Fixtures.shared.copy(try await Fixtures.shared.clip(), named: "clip.mp4")
        let folder = clip.deletingLastPathComponent()
        let wav = try await Fixtures.shared.wav(seconds: 0.5)
        let sentinel = Data("keep me".utf8)
        for name in ["clip.mov", "clip.m4a", "clip.mkv", "clip.mp3", "clip muted.mp4", "clip compressed.mp4"] {
            try sentinel.write(to: folder.appendingPathComponent(name))
        }
        var outputs = [try await engineConvert(clip, to: .mov, folder: folder),
                       try await engineConvert(clip, to: .m4a, folder: folder)]
        if FFmpeg.shared.isAvailable {
            outputs.append(try await engineConvert(clip, to: .mkv, folder: folder))
            if offered(.wav, .mp3) { outputs.append(try await engineConvert(wav, to: .mp3, folder: folder, baseName: "clip")) }
        }
        outputs += try await runTool(.mute, clip, folder: folder).files
        outputs += try await runTool(.compress, clip, folder: folder).files
        for output in outputs {
            XCTAssertTrue(output.deletingPathExtension().lastPathComponent.hasSuffix(" 2"), output.lastPathComponent)
        }
        for name in ["clip.mov", "clip.m4a", "clip.mkv", "clip.mp3", "clip muted.mp4", "clip compressed.mp4"] {
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), sentinel, "\(name) was overwritten")
        }
    }

    func testReadOnlyOutputFolderFailsCleanly() async throws {
        let clip = try await Fixtures.shared.clip()
        let wav = try await Fixtures.shared.wav(seconds: 0.5)
        let folder = try await Fixtures.shared.outputFolder()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        lockedFolders.append(folder)

        for target in [FileFormat.mov, .m4v, .m4a, .wav, .m4r, .gif, .mkv, .mp3, .webm] where offered(.mp4, target) {
            let message = await expectFailure("mp4 → \(target)") { try await engineConvert(clip, to: target, folder: folder) }
            XCTAssertFalse(message.contains("empty file"), "\(target): misleading error: \(message)")
        }
        for target in [FileFormat.flac, .m4a, .m4r, .aiff, .mp3, .ogg] where offered(.wav, target) {
            await expectFailure("wav → \(target)") { try await engineConvert(wav, to: target, folder: folder) }
        }
        let gif = folder.appendingPathComponent("native.gif")
        await expectFailure("native gif") {
            try await AVHelpers.writeGIF(from: AVURLAsset(url: clip), to: gif, fps: 10, width: 160, progress: { _ in })
        }
        for (tool, input) in [(ToolID.mute, clip), (.compress, clip), (.compress, wav)] {
            await expectFailure("\(tool)") { try await runTool(tool, input, folder: folder) }
        }
        XCTAssertEqual(contents(folder), [])
    }
}

// MARK: - Cancellation and progress

final class MediaCancellationTests: XCTestCase {
    private enum Trigger: CustomStringConvertible {
        /// The task is already cancelled when the job starts (e.g. Cancel pressed while a batch moves on).
        case beforeStart
        case after(Double)
        /// As soon as progress shows the job is under way.
        case midway

        var description: String {
            switch self {
            case .beforeStart: "before start"
            case let .after(seconds): "after \(seconds)s"
            case .midway: "mid-way"
            }
        }
    }

    /// Lets a progress callback cancel the task that is reporting it.
    private final class TaskHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Error>?
        private var pending = false

        func set(_ task: Task<Void, Error>) {
            lock.lock(); self.task = task; let cancelNow = pending; lock.unlock()
            if cancelNow { task.cancel() }
        }

        func cancel() {
            lock.lock(); let task = task; if task == nil { pending = true }; lock.unlock()
            task?.cancel()
        }
    }

    /// Runs `work`, cancels it per `trigger`, expects `ConversionError.cancelled` and returns the seconds it took to stop.
    private func cancel(_ trigger: Trigger, _ label: String,
                        _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) async throws -> Void)
        async throws -> Double {
        let handle = TaskHandle()
        let start = Date()
        let task = Task {
            if case .beforeStart = trigger { withUnsafeCurrentTask { $0?.cancel() } }
            try await work { fraction in
                if case .midway = trigger, fraction > 0.01, fraction < 0.9 { handle.cancel() }
            }
        }
        handle.set(task)
        if case let .after(seconds) = trigger {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.cancel()
        }
        do {
            try await task.value
            XCTFail("\(label) \(trigger): finished instead of cancelling")
        } catch ConversionError.cancelled {
            // expected
        } catch {
            XCTFail("\(label) \(trigger): expected ConversionError.cancelled, got \(error)")
        }
        return Date().timeIntervalSince(start)
    }

    private func assertCleanedUp(_ folder: URL, _ label: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        XCTAssertEqual(contents(folder), [], "\(label): partial output left behind", file: file, line: line)
        let running = try await processes(mentioning: folder.lastPathComponent)
        XCTAssertEqual(running, [], "\(label): orphaned process", file: file, line: line)
    }

    func testCancellingNativeVideoExportCleansUp() async throws {
        let long = try await Fixtures.shared.longNativeVideo()
        var hevc = ConversionOptions()
        hevc.videoCodec = .hevc
        hevc.videoResolution = .p1080    // H.264 → HEVC always re-encodes
        let options = hevc
        for trigger in [Trigger.beforeStart, .midway] {
            let folder = try await Fixtures.shared.outputFolder()
            let elapsed = try await cancel(trigger, "AV export") { progress in
                try await engineConvert(long, to: .mp4, options: options, folder: folder, progress: ProgressLog(progress))
            }
            if case .beforeStart = trigger { XCTAssertLessThan(elapsed, 1, "the export ran anyway") }
            try await assertCleanedUp(folder, "AV export \(trigger)")
        }
    }

    func testCancellingAudioJobsCleansUp() async throws {
        let long = try await Fixtures.shared.wav(seconds: 600, sampleRate: 22_050, channels: 1)
        let movie = try await Fixtures.shared.longNativeVideo()
        let jobs: [(String, FileFormat, URL, Trigger)] = [
            ("afconvert", .m4a, long, .after(0.15)), ("afconvert", .flac, long, .after(0.15)),
            ("ringtone", .m4r, long, .midway), ("extract", .aiff, movie, .midway), ("extract", .m4a, movie, .midway),
        ]
        for (label, target, input, trigger) in jobs {
            for trigger in [Trigger.beforeStart, trigger] {
                let folder = try await Fixtures.shared.outputFolder()
                let elapsed = try await cancel(trigger, "\(label) \(target)") { progress in
                    try await engineConvert(input, to: target, backends: nativeBackends, folder: folder,
                                            progress: ProgressLog(progress))
                }
                if case .beforeStart = trigger { XCTAssertLessThan(elapsed, 1, "\(label) \(target): the job ran anyway") }
                try await assertCleanedUp(folder, "\(label) \(target) \(trigger)")
            }
        }
    }

    func testCancellingNativeGIFCleansUp() async throws {
        let long = try await Fixtures.shared.longNativeVideo()
        for trigger in [Trigger.beforeStart, .midway] {
            let folder = try await Fixtures.shared.outputFolder()
            _ = try await cancel(trigger, "native GIF") { progress in
                _ = try await AVVideoBackend(ffmpeg: noFFmpeg).convert(long, from: .mov, to: .gif,
                                                                       output: OutputPlan(directory: folder, baseName: "long"),
                                                                       context: ConversionContext(progress: progress))
            }
            try await assertCleanedUp(folder, "native GIF \(trigger)")
        }
    }

    func testCancellingFFmpegStopsTheProcess() async throws {
        try XCTSkipUnless(FFmpeg.fixtures.hasEncoder("libx264"), "needs ffmpeg with libx264 for the fixture")
        let long = try await Fixtures.shared.longVideo()
        var reencode = ConversionOptions()
        reencode.videoResolution = .p480    // makes MKV re-encode instead of copying streams
        let options = reencode
        for trigger in [Trigger.beforeStart, .midway] {
            // MP3 finishes before ffmpeg's first progress report, so it's only cancelled before start.
            let targets: [FileFormat] = if case .midway = trigger { [.webm, .mkv] } else { [.webm, .mkv, .mp3] }
            for target in targets where offered(.mp4, target) {
                let folder = try await Fixtures.shared.outputFolder()
                let elapsed = try await cancel(trigger, "ffmpeg \(target)") { progress in
                    try await engineConvert(long, to: target, options: options, backends: [FFmpegMediaBackend()],
                                            folder: folder, progress: ProgressLog(progress))
                }
                if case .beforeStart = trigger { XCTAssertLessThan(elapsed, 1, "\(target): ffmpeg ran anyway") }
                try await assertCleanedUp(folder, "ffmpeg \(target) \(trigger)")
            }
            let folder = try await Fixtures.shared.outputFolder()
            let elapsed = try await cancel(trigger, "compress") { progress in
                _ = try await runTool(.compress, long, folder: folder, progress: ProgressLog(progress))
            }
            if case .beforeStart = trigger { XCTAssertLessThan(elapsed, 1, "compress: ffmpeg ran anyway") }
            try await assertCleanedUp(folder, "compress \(trigger)")
        }
    }

    func testProgressIsMonotonicAndEndsAtOne() async throws {
        let clip = try await Fixtures.shared.mp4()
        var reencode = ConversionOptions()
        reencode.videoResolution = .p480
        var jobs: [(String, URL, FileFormat, ConversionOptions)] = [
            ("passthrough", clip, .mov, ConversionOptions()), ("re-encode", clip, .m4v, reencode),
            ("LPCM MOV → MP4", try await Fixtures.shared.lpcmMOV(), .mp4, ConversionOptions()),
            ("extract", clip, .m4a, ConversionOptions()), ("extract pcm", clip, .wav, ConversionOptions()),
            ("afconvert", try await Fixtures.shared.wav(), .flac, ConversionOptions()),
        ]
        if FFmpeg.shared.isAvailable {
            jobs += [("ffmpeg gif", clip, .gif, ConversionOptions()), ("ffmpeg mkv", clip, .mkv, reencode),
                     ("ffmpeg webm", clip, .webm, ConversionOptions()), ("ffmpeg mp3", clip, .mp3, ConversionOptions())]
        }
        for (label, input, target, options) in jobs where offered(FileFormat.detect(input)!, target) {
            let progress = ProgressLog()
            let output = try await engineConvert(input, to: target, options: options, progress: progress)
            assertMonotonic(progress.all, label)
            if target == .mp4 {
                // Passing LPCM through makes an MP4 that only Apple software opens.
                let info = try await MediaInfo.read(output)
                XCTAssertEqual(info.audioSubtype, kAudioFormatMPEG4AAC, "\(label): LPCM becomes AAC in MP4")
                XCTAssertEqual(info.videoTracks, 1, label)
                try await assertDecodes(output)
            }
        }
        let native = ProgressLog()
        _ = try await AVVideoBackend(ffmpeg: noFFmpeg).convert(clip, from: .mp4, to: .gif,
                                                               output: OutputPlan(directory: try await Fixtures.shared.outputFolder(),
                                                                                  baseName: "native"),
                                                               context: ConversionContext(progress: native.callback))
        assertMonotonic(native.all, "native gif")
        for tool in [ToolID.compress, .mute] {
            let progress = ProgressLog()
            _ = try await runTool(tool, clip, progress: progress)
            assertMonotonic(progress.all, "\(tool)")
        }
    }
}

// MARK: - Compress

final class MediaCompressEdgeCaseTests: XCTestCase {
    func testCompressNeverKeepsALargerFile() async throws {
        let first = try await runTool(.compress, try await Fixtures.shared.clip(seconds: 2))
        var inputs = [try await Fixtures.shared.silentVideo(), try await Fixtures.shared.audioOnlyMP4(),
                      try await Fixtures.shared.clip(transform: portrait)]
        if let compressed = first.files.first { inputs.append(compressed) }
        let small = try await Fixtures.shared.outputFolder().appendingPathComponent("tiny.m4a")
        try await NativeAudioBackend.encode(try await Fixtures.shared.wav(channels: 1), to: .m4a, writingTo: small,
                                            options: ConversionOptions(), bitrateKbps: 32)
        inputs.append(small)
        if FFmpeg.shared.isAvailable {
            var options = ConversionOptions()
            options.audioBitrateKbps = 48
            let wav = try await Fixtures.shared.wav()
            for target in [FileFormat.mp3, .opus, .ogg] where offered(.wav, target) {
                inputs.append(try await engineConvert(wav, to: target, options: options))
            }
        }
        for input in inputs {
            let folder = try await Fixtures.shared.outputFolder()
            let result = try await runTool(.compress, input, folder: folder)
            if let output = result.files.first {
                XCTAssertLessThan(output.fileSize, input.fileSize, "\(input.lastPathComponent) grew")
                XCTAssertNil(result.note)
                let info = try await MediaInfo.read(output)
                XCTAssertGreaterThan(info.duration, 0.5, input.lastPathComponent)
            } else {
                XCTAssertEqual(result.note, "Already optimized", input.lastPathComponent)
                XCTAssertEqual(contents(folder), [], "\(input.lastPathComponent): leftovers")
            }
        }
    }
}

// MARK: - Without ffmpeg

final class MediaWithoutFFmpegTests: XCTestCase {
    private let ffmpegOnlyTargets: Set<FileFormat> = [.mp3, .ogg, .opus, .wma, .mkv, .webm, .avi, .wmv]

    func testOnlyNativeConversionsAreOffered() {
        let media = FileFormat.allCases.filter { $0.category == .audio || $0.category == .video }
        for from in media {
            for to in FileFormat.allCases where offered(from, to, backends: nativeBackends) {
                XCTAssertFalse(MediaFormats.ffmpegOnlyVideoInputs.contains(from) || MediaFormats.ffmpegOnlyAudioInputs.contains(from),
                               "\(from) → \(to) needs ffmpeg")
                XCTAssertFalse(ffmpegOnlyTargets.contains(to), "\(from) → \(to) needs ffmpeg")
            }
        }
        for from in [FileFormat.mp4, .mov, .m4v, .threeGP] {
            for to in [FileFormat.mov, .gif, .m4a, .wav, .aiff, .flac, .m4r] where to != from {
                XCTAssertTrue(offered(from, to, backends: nativeBackends), "\(from) → \(to) should work without ffmpeg")
            }
        }
        for from in [FileFormat.mp3, .wav, .flac, .m4a, .aiff] {
            XCTAssertTrue(offered(from, from == .m4a ? .wav : .m4a, backends: nativeBackends), "\(from)")
        }
        let tools = MediaToolBackend(ffmpeg: noFFmpeg)
        for format in [FileFormat.mkv, .webm, .avi, .ogg, .opus, .wma] {
            XCTAssertFalse(tools.supports(.compress, format: format), "compress \(format)")
            XCTAssertFalse(tools.supports(.mute, format: format), "mute \(format)")
        }
        for format in [FileFormat.mp4, .mov, .wav, .mp3, .flac] {
            XCTAssertTrue(tools.supports(.compress, format: format), "compress \(format)")
        }
    }

    func testEdgeCasesWithoutFFmpegFailCleanly() async throws {
        let tools = MediaToolBackend(ffmpeg: noFFmpeg)
        let clip = try await Fixtures.shared.clip()
        // Real conversions still work.
        for target in [FileFormat.mov, .gif, .m4a, .wav, .m4r] {
            try await engineConvert(clip, to: target, backends: nativeBackends)
        }
        let muted = try await runTool(.mute, clip, backend: tools)
        XCTAssertEqual(muted.files.count, 1)
        let compressed = try await runTool(.compress, clip, backend: tools)
        XCTAssertTrue(compressed.files.count == 1 || compressed.note == "Already optimized")

        // Broken inputs fail with a message and leave nothing behind.
        let silent = try await Fixtures.shared.silentVideo()
        let audioOnly = try await Fixtures.shared.audioOnlyMP4()
        let cases: [(URL, FileFormat)] = [
            (try await Fixtures.shared.file(named: "empty.mp4", contents: Data()), .mov),
            (try await Fixtures.shared.file(named: "notes.mp4", contents: Data("text".utf8)), .m4a),
            (try await Fixtures.shared.file(named: "notes.mov", contents: Data("text".utf8)), .gif),
            (try await Fixtures.shared.file(named: "empty.wav", contents: Data()), .flac),
            (try await Fixtures.shared.file(named: "notes.mp3", contents: Data("text".utf8)), .m4a),
            (silent, .m4a), (silent, .wav), (audioOnly, .gif),
        ]
        for (input, target) in cases {
            let folder = try await Fixtures.shared.outputFolder()
            await expectFailure("\(input.lastPathComponent) → \(target)") {
                try await engineConvert(input, to: target, backends: nativeBackends, folder: folder)
            }
            XCTAssertEqual(contents(folder), [], input.lastPathComponent)
        }
        for (tool, input) in [(ToolID.mute, audioOnly), (.mute, cases[0].0), (.compress, cases[1].0), (.compress, cases[3].0)] {
            let folder = try await Fixtures.shared.outputFolder()
            await expectFailure("\(tool) \(input.lastPathComponent)") { try await runTool(tool, input, backend: tools, folder: folder) }
            XCTAssertEqual(contents(folder), [])
        }
    }

    func testBrokenFFmpegBinaryDegradesGracefully() async throws {
        // An ffmpeg that can't run (wrong architecture, damaged download) reports no encoders.
        let broken = FFmpeg(path: "/usr/bin/false")
        XCTAssertTrue(broken.encoders.isEmpty)
        let backends: [any ConversionBackend] = [AVVideoBackend(ffmpeg: broken), NativeAudioBackend(ffmpeg: broken),
                                                 FFmpegMediaBackend(ffmpeg: broken)]
        XCTAssertTrue(offered(.mp4, .gif, backends: backends), "the native GIF writer should take over")
        XCTAssertFalse(offered(.mp4, .mp3, backends: backends))
        XCTAssertFalse(offered(.mkv, .mp4, backends: backends))
        let clip = try await Fixtures.shared.clip()
        let gif = try gifFrames(try await engineConvert(clip, to: .gif, backends: backends))
        XCTAssertGreaterThan(gif.count, 1)

        let tools = MediaToolBackend(ffmpeg: broken)
        XCTAssertFalse(tools.supports(.mute, format: .mkv))
        XCTAssertFalse(tools.supports(.compress, format: .ogg))
        let compressed = try await runTool(.compress, clip, backend: tools)
        XCTAssertTrue(compressed.files.count == 1 || compressed.note == "Already optimized")
        let muted = try await runTool(.mute, clip, backend: tools)
        XCTAssertEqual(muted.files.count, 1)

        // A disguised file that Core Audio rejects falls back to ffmpeg, which fails cleanly.
        let disguised = try await Fixtures.shared.file(named: "fake.mp3", contents: Data("OggS".utf8))
        await expectFailure("disguised") { try await engineConvert(disguised, to: .wav, backends: backends) }
    }
}

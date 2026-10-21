import AVFoundation
import Foundation
import TangerineCore

/// Converts between audio formats Core Audio understands, using the built-in `afconvert`.
public struct NativeAudioBackend: ConversionBackend {
    public let id = "afconvert"
    static let afconvert = "/usr/bin/afconvert"
    /// Used as a fallback when Core Audio can't decode a file.
    let ffmpeg: FFmpeg

    public init(ffmpeg: FFmpeg = .shared) {
        self.ffmpeg = ffmpeg
    }

    public func supports(from: FileFormat, to: FileFormat) -> Bool {
        from != to && MediaFormats.nativeAudioInputs.contains(from) && MediaFormats.nativeAudioOutputs.contains(to)
            && FileManager.default.isExecutableFile(atPath: Self.afconvert)
    }

    public func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                        context: ConversionContext) async throws -> [URL] {
        guard supports(from: from, to: to) else {
            throw ConversionError.unsupported(from: from, to: to.displayName)
        }
        let out = output.file(extension: to.fileExtension)
        context.progress(0)
        let fallback = FFmpegMediaBackend(ffmpeg: ffmpeg)
        if MediaFormats.hasFFmpegOnlyContainer(input), fallback.supports(from: from, to: to) {
            try await fallback.convert(input, to: to, writingTo: out, context: context)
            context.progress(1)
            return [out]
        }
        do {
            if to == .m4r {
                try await Self.makeRingtone(from: input, to: out, options: context.options, progress: context.progress)
            } else {
                try await Self.encode(input, to: to, writingTo: out, options: context.options,
                                      bitDepth: Self.sourceBitDepth(input))
            }
        } catch ConversionError.cancelled {
            throw ConversionError.cancelled
        } catch {
            // Core Audio rejects some files it nominally supports (odd MP3 headers, AMR variants); ffmpeg is more lenient.
            guard fallback.supports(from: from, to: to) else { throw mediaError(error) }
            removePartial(out)
            try await fallback.convert(input, to: to, writingTo: out, context: context)
        }
        context.progress(1)
        return [out]
    }

    /// Encodes with afconvert into an exact path. `to` must be one of `MediaFormats.nativeAudioOutputs` except m4r,
    /// or m4r when the source is already short enough.
    static func encode(_ input: URL, to: FileFormat, writingTo out: URL, options: ConversionOptions,
                       bitDepth: Int = 16, bitrateKbps: Int? = nil) async throws {
        let rate = options.audioSampleRate.map { "@\($0)" } ?? ""
        let depth = bitDepth > 16 ? 24 : 16
        var args: [String]
        var bitrateArgs: [String] = []
        switch to {
        case .m4a, .m4r:
            args = ["-f", "m4af", "-d", "aac\(rate)", "-q", "127"]
            bitrateArgs = ["-b", "\((bitrateKbps ?? options.audioBitrateKbps) * 1000)"]
        case .alac: args = ["-f", "m4af", "-d", "alac\(rate)"]
        case .wav: args = ["-f", "WAVE", "-d", "LEI\(depth)\(rate)"]
        case .aiff: args = ["-f", "AIFF", "-d", "BEI\(depth)\(rate)"]
        case .caf: args = ["-f", "caff", "-d", "LEI\(depth)\(rate)"]
        case .flac: args = ["-f", "flac", "-d", "flac\(rate)"]
        default: throw ConversionError.unsupported(from: FileFormat.detect(input), to: to.displayName)
        }
        do {
            try await runAfconvert(args + bitrateArgs + [input.path, out.path])
        } catch ConversionError.cancelled {
            removePartial(out)
            throw ConversionError.cancelled
        } catch where !bitrateArgs.isEmpty {
            // AAC only accepts certain bitrates for a given rate/channel count; let the encoder pick.
            removePartial(out)
            do {
                try await runAfconvert(args + [input.path, out.path])
            } catch {
                removePartial(out)
                throw error
            }
        } catch {
            removePartial(out)
            throw error
        }
        try requireOutput(out)
        // afconvert can exit 0 yet write a file nothing can read, e.g. FLAC from under ~0.1 s of audio.
        guard (try? AVAudioFile(forReading: out)) != nil else {
            removePartial(out)
            throw ConversionError.failed("Couldn't write a valid \(to.displayName) file.")
        }
    }

    /// Runs afconvert, translating its terse errors such as "Couldn't open input file ('typ?')".
    private static func runAfconvert(_ arguments: [String]) async throws {
        do {
            try await Shell.run(afconvert, arguments)
        } catch let ConversionError.failed(message) where message.contains("Couldn't open input file") {
            throw ConversionError.failed("This file is damaged or isn't a supported audio file.")
        } catch let ConversionError.failed(message) where message.contains("ExtAudioFileCreateWithURL failed (-54)") {
            throw ConversionError.failed("Permission denied.")
        }
    }

    /// iPhone ringtones are AAC in an `.m4r` file and may be at most 40 seconds long.
    static func makeRingtone(from input: URL, to out: URL, options: ConversionOptions,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration).seconds
        guard duration > MediaFormats.ringtoneMaxSeconds else {
            try await encode(input, to: .m4r, writingTo: out, options: options)
            return
        }
        // Trim to an uncompressed temp file, then encode.
        let temp = try TemporaryDirectory()
        let trimmed = temp.file("ringtone.caf")
        try await AVHelpers.writePCM(from: asset, to: trimmed, fileType: .caf, maxDuration: MediaFormats.ringtoneMaxSeconds,
                                     progress: { progress($0 * 0.8) })
        try await encode(trimmed, to: .m4r, writingTo: out, options: options)
    }

    /// Bit depth of lossless sources so WAV/AIFF output doesn't throw away resolution.
    static func sourceBitDepth(_ url: URL) -> Int {
        guard let file = try? AVAudioFile(forReading: url) else { return 16 }
        let description = file.fileFormat.streamDescription.pointee
        switch description.mFormatID {
        case kAudioFormatLinearPCM:
            return Int(description.mBitsPerChannel)
        case kAudioFormatFLAC, kAudioFormatAppleLossless:
            // These codecs store the source depth in the format flags: 1 = 16, 2 = 20, 3 = 24, 4 = 32 bit.
            return description.mFormatFlags >= 2 ? 24 : 16
        default:
            return 16
        }
    }
}

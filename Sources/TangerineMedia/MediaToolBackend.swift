import AVFoundation
import Foundation
import TangerineCore

/// One-shot tools for video and audio: Compress and Mute.
public struct MediaToolBackend: ToolBackend {
    public let id = "media-tools"
    let ffmpeg: FFmpeg

    /// Compressed video is capped at 1080p (short side).
    static let compressedVideoSide = 1080
    static let compressedAudioKbps = 128

    public init(ffmpeg: FFmpeg = .shared) {
        self.ffmpeg = ffmpeg
    }

    public func supports(_ tool: ToolID, format: FileFormat) -> Bool {
        switch tool {
        case .compress: canRead(video: format) || canRead(audio: format)
        case .mute: canRead(video: format)
        default: false
        }
    }

    public func run(_ tool: ToolID, inputs: [URL], output: OutputPlan, context: ConversionContext) async throws -> ToolOutput {
        guard let input = inputs.first, let format = FileFormat.detect(input), supports(tool, format: format) else {
            throw ConversionError.unsupported(from: inputs.first.flatMap(FileFormat.detect), to: tool.title)
        }
        context.progress(0)
        defer { context.progress(1) }
        do {
            switch tool {
            case .compress where canRead(video: format):
                return try await compressVideo(input, format: format, output: output, context: context)
            case .compress:
                return try await compressAudio(input, format: format, output: output, context: context)
            default:
                return try await mute(input, format: format, output: output, context: context)
            }
        } catch {
            throw mediaError(error)
        }
    }

    // MARK: - Compress

    private func compressVideo(_ input: URL, format: FileFormat, output: OutputPlan,
                               context: ConversionContext) async throws -> ToolOutput {
        let out = output.file(extension: "mp4", suffix: "compressed")
        var lastError: Error?
        if let encoder = ["hevc_videotoolbox", "libx265", "h264_videotoolbox", "libx264"].first(where: ffmpeg.hasEncoder) {
            let backend = FFmpegMediaBackend(ffmpeg: ffmpeg)
            var args = ["-i", input.path, "-map", "0:v:0", "-map", "0:a:0?",
                        "-vf", backend.scaleFilter(.p1080), "-c:v", encoder]
            switch encoder {
            case "hevc_videotoolbox": args += ["-q:v", "50", "-tag:v", "hvc1"]
            case "libx265": args += ["-preset", "medium", "-crf", "28", "-tag:v", "hvc1"]
            case "h264_videotoolbox": args += ["-q:v", "55"]
            default: args += ["-preset", "medium", "-crf", "26"]
            }
            let aac = ffmpeg.hasEncoder("aac_at") ? "aac_at" : "aac"
            args += ["-pix_fmt", "yuv420p", "-c:a", aac, "-b:a", "\(Self.compressedAudioKbps)k",
                     "-movflags", "+faststart", out.path]
            do {
                try await FFmpegRunner.run(ffmpeg, args, progress: context.progress)
                try requireOutput(out)
                return keepIfSmaller(out, than: input)
            } catch ConversionError.cancelled {
                removePartial(out)
                throw ConversionError.cancelled
            } catch {
                removePartial(out)
                lastError = error
            }
        }
        guard MediaFormats.avVideoInputs.contains(format) else {
            throw lastError ?? ConversionError.engineMissing("ffmpeg")
        }
        let presets = AVAssetExportSession.allExportPresets()
        let preset = presets.contains(AVAssetExportPresetHEVC1920x1080) ? AVAssetExportPresetHEVC1920x1080
            : AVAssetExportPreset1920x1080
        try await AVHelpers.export(AVURLAsset(url: input), preset: preset, to: out, fileType: .mp4,
                                   progress: context.progress)
        try requireOutput(out)
        return keepIfSmaller(out, than: input)
    }

    private func compressAudio(_ input: URL, format: FileFormat, output: OutputPlan,
                               context: ConversionContext) async throws -> ToolOutput {
        let out = output.file(extension: "m4a", suffix: "compressed")
        if MediaFormats.nativeAudioInputs.contains(format) {
            try await NativeAudioBackend.encode(input, to: .m4a, writingTo: out, options: context.options,
                                                bitrateKbps: Self.compressedAudioKbps)
        } else {
            var options = context.options
            options.audioBitrateKbps = Self.compressedAudioKbps
            try await FFmpegMediaBackend(ffmpeg: ffmpeg)
                .convert(input, to: .m4a, writingTo: out, context: ConversionContext(options: options, progress: context.progress))
        }
        return keepIfSmaller(out, than: input)
    }

    /// Deletes `out` and reports "Already optimized" when compression didn't help.
    private func keepIfSmaller(_ out: URL, than input: URL) -> ToolOutput {
        if out.fileSize >= input.fileSize {
            removePartial(out)
            return ToolOutput(note: "Already optimized")
        }
        return ToolOutput(files: [out])
    }

    // MARK: - Mute

    private func mute(_ input: URL, format: FileFormat, output: OutputPlan, context: ConversionContext) async throws -> ToolOutput {
        let out = output.file(extension: format.fileExtension, suffix: "muted")
        var lastError: Error?
        if MediaFormats.avVideoInputs.contains(format), let fileType = Self.containerType(format) {
            do {
                let composition = try await Self.videoOnlyComposition(of: AVURLAsset(url: input))
                try await AVHelpers.export(composition, preset: AVAssetExportPresetPassthrough, to: out,
                                           fileType: fileType, progress: context.progress)
                try requireOutput(out)
                return ToolOutput(files: [out])
            } catch ConversionError.cancelled {
                throw ConversionError.cancelled
            } catch {
                removePartial(out)
                lastError = error
            }
        }
        guard ffmpegWorks else { throw lastError ?? ConversionError.engineMissing("ffmpeg") }
        do {
            try await FFmpegRunner.run(ffmpeg, ["-i", input.path, "-map", "0:v", "-c", "copy", "-an", out.path],
                                       progress: context.progress)
            try requireOutput(out)
        } catch {
            removePartial(out)
            throw error
        }
        return ToolOutput(files: [out])
    }

    static func containerType(_ format: FileFormat) -> AVFileType? {
        format == .threeGP ? .mobile3GPP : AVHelpers.fileType(for: format)
    }

    static func videoOnlyComposition(of asset: AVAsset) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty else { throw ConversionError.failed("This file has no video.") }
        for track in tracks {
            guard let copy = composition.addMutableTrack(withMediaType: .video,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let (range, transform) = try await track.load(.timeRange, .preferredTransform)
            try copy.insertTimeRange(range, of: track, at: range.start)
            copy.preferredTransform = transform
        }
        return composition
    }

    // MARK: - Capabilities

    /// Installed and actually runs (a binary for the wrong architecture reports no encoders).
    private var ffmpegWorks: Bool { ffmpeg.isAvailable && !ffmpeg.encoders.isEmpty }

    private func canRead(video format: FileFormat) -> Bool {
        MediaFormats.avVideoInputs.contains(format)
            || (ffmpegWorks && MediaFormats.ffmpegOnlyVideoInputs.contains(format))
    }

    private func canRead(audio format: FileFormat) -> Bool {
        MediaFormats.nativeAudioInputs.contains(format)
            || (ffmpeg.isAvailable && MediaFormats.ffmpegOnlyAudioInputs.contains(format) && ffmpeg.hasEncoder("aac"))
    }
}

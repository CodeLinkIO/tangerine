import AVFoundation
import Foundation
import TangerineCore

/// Converts MP4/MOV/M4V/3GP natively: container changes (passthrough when possible), re-encodes via
/// export presets, audio extraction, and a GIF fallback when ffmpeg isn't installed.
public struct AVVideoBackend: ConversionBackend {
    public let id = "avfoundation-video"
    let ffmpeg: FFmpeg

    public init(ffmpeg: FFmpeg = .shared) {
        self.ffmpeg = ffmpeg
    }

    public func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard from != to, MediaFormats.avVideoInputs.contains(from) else { return false }
        if MediaFormats.avVideoOutputs.contains(to) { return true }
        // ffmpeg's palette-based GIFs look much better, so only claim GIF when ffmpeg can't make one
        // (missing, or a binary that doesn't run and so reports no encoders).
        if to == .gif { return !ffmpeg.hasEncoder("gif") }
        return MediaFormats.nativeAudioOutputs.contains(to)
    }

    public func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                        context: ConversionContext) async throws -> [URL] {
        guard supports(from: from, to: to) else {
            throw ConversionError.unsupported(from: from, to: to.displayName)
        }
        let asset = AVURLAsset(url: input)
        let out = output.file(extension: to.fileExtension)
        context.progress(0)
        do {
            switch to {
            case .mp4, .mov, .m4v:
                try await convertVideo(asset, input: input, from: from, to: to, writingTo: out, context: context)
            case .gif:
                try await AVHelpers.writeGIF(from: asset, to: out, fps: context.options.gifFPS,
                                             width: context.options.gifWidth, progress: context.progress)
            default:
                try await Self.extractAudio(from: asset, to: to, writingTo: out, options: context.options,
                                            progress: context.progress)
            }
        } catch {
            throw mediaError(error)
        }
        try requireOutput(out)
        context.progress(1)
        return [out]
    }

    private func convertVideo(_ asset: AVURLAsset, input: URL, from: FileFormat, to: FileFormat, writingTo out: URL,
                              context: ConversionContext) async throws {
        guard let fileType = AVHelpers.fileType(for: to) else {
            throw ConversionError.unsupported(from: from, to: to.displayName)
        }
        var presets: [String] = []
        if context.options.videoResolution == .original, await Self.canPassThrough(asset, to: to) {
            presets.append(AVAssetExportPresetPassthrough)
        }
        presets.append(Self.reencodePreset(context.options))

        var lastError: Error?
        for preset in presets {
            do {
                try await AVHelpers.export(asset, preset: preset, to: out, fileType: fileType, progress: context.progress)
                try requireOutput(out)
                return
            } catch ConversionError.cancelled {
                throw ConversionError.cancelled
            } catch {
                lastError = error
                removePartial(out)
            }
        }
        let fallback = FFmpegMediaBackend(ffmpeg: ffmpeg)
        if fallback.supports(from: from, to: to) {
            try await fallback.convert(input, to: to, writingTo: out, context: context)
            return
        }
        throw lastError ?? ConversionError.failed("Couldn't convert this video.")
    }

    /// Extracts the audio track(s) into any native audio format.
    static func extractAudio(from asset: AVAsset, to: FileFormat, writingTo out: URL, options: ConversionOptions,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        switch to {
        case .wav, .aiff, .caf:
            guard let fileType = AVHelpers.fileType(for: to) else { break }
            try await AVHelpers.writePCM(from: asset, to: out, fileType: fileType, sampleRate: options.audioSampleRate,
                                         progress: progress)
        default:
            // Decode once to PCM, then let afconvert encode AAC/ALAC/FLAC with the user's bitrate.
            let temp = try TemporaryDirectory()
            let pcm = temp.file("audio.caf")
            let limit = to == .m4r ? MediaFormats.ringtoneMaxSeconds : nil
            try await AVHelpers.writePCM(from: asset, to: pcm, fileType: .caf, maxDuration: limit,
                                         progress: { progress($0 * 0.8) })
            try await NativeAudioBackend.encode(pcm, to: to, writingTo: out, options: options)
        }
    }

    /// Passthrough happily copies LPCM audio (screen recordings, cameras) or ProRes into an MP4, but the result
    /// only opens in Apple software (ffmpeg rejects it), so MP4/M4V only pass through standard MP4 codecs.
    static func canPassThrough(_ asset: AVAsset, to: FileFormat) async -> Bool {
        guard to == .mp4 || to == .m4v else { return true }
        let video: Set<FourCharCode> = [kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_MPEG4Video]
        let audio: Set<FourCharCode> = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                                        kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD, kAudioFormatAppleLossless,
                                        kAudioFormatAC3, kAudioFormatEnhancedAC3, kAudioFormatMPEGLayer3]
        for (mediaType, allowed) in [(AVMediaType.video, video), (.audio, audio)] {
            for track in (try? await asset.loadTracks(withMediaType: mediaType)) ?? [] {
                let descriptions = (try? await track.load(.formatDescriptions)) ?? []
                if descriptions.contains(where: { !allowed.contains(CMFormatDescriptionGetMediaSubType($0)) }) { return false }
            }
        }
        return true
    }

    /// Export preset matching the requested codec and resolution.
    static func reencodePreset(_ options: ConversionOptions) -> String {
        let preset: String = switch (options.videoCodec, options.videoResolution) {
        case (.hevc, .original): AVAssetExportPresetHEVCHighestQuality
        case (.hevc, .p2160): AVAssetExportPresetHEVC3840x2160
        case (.hevc, .p1080): AVAssetExportPresetHEVC1920x1080
        case (_, .p720): AVAssetExportPreset1280x720
        case (_, .p480): AVAssetExportPreset640x480
        case (.h264, .original): AVAssetExportPresetHighestQuality
        case (.h264, .p2160): AVAssetExportPreset3840x2160
        case (.h264, .p1080): AVAssetExportPreset1920x1080
        }
        return AVAssetExportSession.allExportPresets().contains(preset) ? preset : AVAssetExportPresetHighestQuality
    }
}

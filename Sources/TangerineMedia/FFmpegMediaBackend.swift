import Foundation
import TangerineCore

/// Converts audio and video with ffmpeg. Covers containers and codecs macOS can't encode
/// (MP3, OGG, Opus, WMA, MKV, WebM, AVI, WMV) and makes better GIFs than ImageIO.
public struct FFmpegMediaBackend: ConversionBackend {
    public let id = "ffmpeg-media"
    let ffmpeg: FFmpeg

    public init(ffmpeg: FFmpeg = .shared) {
        self.ffmpeg = ffmpeg
    }

    public func supports(from: FileFormat, to: FileFormat) -> Bool {
        guard ffmpeg.isAvailable, from != to else { return false }
        let fromVideo = MediaFormats.videoInputs.contains(from)
        guard fromVideo || MediaFormats.audioInputs.contains(from) else { return false }
        if MediaFormats.ffmpegVideoOutputs.contains(to) { return fromVideo && canEncode(to) }
        if MediaFormats.ffmpegAudioOutputs.contains(to) { return canEncode(to) }
        return false
    }

    public func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                        context: ConversionContext) async throws -> [URL] {
        guard supports(from: from, to: to) else {
            throw ConversionError.unsupported(from: from, to: to.displayName)
        }
        let out = output.file(extension: to.fileExtension)
        try await convert(input, to: to, writingTo: out, context: context)
        return [out]
    }

    /// Converts into an exact path; used by other backends as a fallback.
    func convert(_ input: URL, to: FileFormat, writingTo out: URL, context: ConversionContext) async throws {
        context.progress(0)
        if to == .mkv {
            // Most streams fit in Matroska as-is, which is lossless and near-instant.
            do {
                try await FFmpegRunner.run(ffmpeg, ["-i", input.path, "-map", "0:v:0", "-map", "0:a?", "-c", "copy", out.path],
                                           progress: context.progress)
                try requireOutput(out)
                context.progress(1)
                return
            } catch ConversionError.cancelled {
                removePartial(out)
                throw ConversionError.cancelled
            } catch {
                removePartial(out)
            }
        }
        let limit: Double? = switch to {
        case .gif: MediaFormats.gifMaxSeconds
        case .m4r: MediaFormats.ringtoneMaxSeconds
        default: nil
        }
        do {
            try await FFmpegRunner.run(ffmpeg, arguments(input: input, to: to, output: out, options: context.options),
                                       durationLimit: limit, progress: context.progress)
            try requireOutput(out)
        } catch {
            removePartial(out)
            throw error
        }
        context.progress(1)
    }

    // MARK: - Encoder selection

    func canEncode(_ to: FileFormat) -> Bool {
        switch to {
        case .mp4, .mov, .m4v: videoEncoder(.h264) != nil && aacEncoder != nil
        case .mkv: videoEncoder(.h264) != nil
        case .webm: first(["libvpx-vp9", "libvpx"]) != nil && first(["libopus", "libvorbis", "opus"]) != nil
        case .avi: ffmpeg.hasEncoder("mpeg4")
        case .wmv: ffmpeg.hasEncoder("wmv2") && ffmpeg.hasEncoder("wmav2")
        case .gif: ffmpeg.hasEncoder("gif")
        case .mp3: ffmpeg.hasEncoder("libmp3lame")
        case .m4a, .m4r: aacEncoder != nil
        case .alac: first(["alac", "alac_at"]) != nil
        case .wav, .caf: ffmpeg.hasEncoder("pcm_s16le")
        case .aiff: ffmpeg.hasEncoder("pcm_s16be")
        case .flac: ffmpeg.hasEncoder("flac")
        case .ogg: first(["libvorbis", "libopus", "vorbis"]) != nil
        case .opus: first(["libopus", "opus"]) != nil
        case .wma: ffmpeg.hasEncoder("wmav2")
        default: false
        }
    }

    private func first(_ names: [String]) -> String? {
        names.first(where: ffmpeg.hasEncoder)
    }

    private var aacEncoder: String? { first(["aac_at", "aac"]) }

    private func videoEncoder(_ codec: VideoCodec) -> String? {
        switch codec {
        case .h264: first(["h264_videotoolbox", "libx264"])
        case .hevc: first(["hevc_videotoolbox", "libx265"])
        }
    }

    // MARK: - Arguments

    func arguments(input: URL, to: FileFormat, output: URL, options: ConversionOptions) -> [String] {
        let bitrate = max(options.audioBitrateKbps, 32)
        var args: [String] = []

        switch to {
        case .gif:
            args = ["-t", format(MediaFormats.gifMaxSeconds), "-i", input.path]
            let fps = max(1, min(options.gifFPS, 50))
            let width = max(16, options.gifWidth)
            args += ["-vf", "fps=\(fps),scale='min(\(width),iw)':-1:flags=lanczos,split[s0][s1];"
                + "[s0]palettegen=stats_mode=diff[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle",
                     "-loop", "0"]
            return args + [output.path]
        default:
            args = ["-i", input.path]
        }

        if MediaFormats.ffmpegVideoOutputs.contains(to) {
            args += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", scaleFilter(options.videoResolution)]
            switch to {
            case .webm:
                let q = clampedQuality(options)
                if ffmpeg.hasEncoder("libvpx-vp9") {
                    args += ["-c:v", "libvpx-vp9", "-crf", "\(Int(44 - q * 20))", "-b:v", "0",
                             "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]
                } else {
                    args += ["-c:v", "libvpx", "-crf", "10", "-b:v", "4M"]
                }
                args += ["-pix_fmt", "yuv420p"]
                let audio = first(["libopus", "libvorbis", "opus"]) ?? "libopus"
                args += ["-c:a", audio, "-b:a", "\(min(bitrate, 256))k"]
                if audio == "opus" { args += ["-strict", "-2"] }
            case .avi:
                args += ["-c:v", "mpeg4", "-q:v", "\(mpeg4Scale(options))", "-vtag", "XVID", "-pix_fmt", "yuv420p"]
                args += ffmpeg.hasEncoder("libmp3lame")
                    ? ["-c:a", "libmp3lame", "-b:a", "\(min(bitrate, 320))k"]
                    : ["-c:a", "pcm_s16le"]
            case .wmv:
                args += ["-c:v", "wmv2", "-q:v", "\(mpeg4Scale(options))", "-pix_fmt", "yuv420p",
                         "-c:a", "wmav2", "-b:a", "\(min(bitrate, 192))k"]
            default: // mp4, mov, m4v, mkv (re-encode)
                args += videoCodecArguments(options)
                args += ["-c:a", aacEncoder ?? "aac", "-b:a", "\(min(bitrate, 320))k"]
                if to != .mkv { args += ["-movflags", "+faststart"] }
                if to == .m4v { args += ["-f", "mp4"] }
            }
            return args + [output.path]
        }

        // Audio targets.
        args += ["-vn", "-map", "0:a:0"]
        switch to {
        case .mp3: args += ["-c:a", "libmp3lame", "-b:a", "\(min(bitrate, 320))k"]
        case .m4a: args += ["-c:a", aacEncoder ?? "aac", "-b:a", "\(min(bitrate, 320))k", "-f", "ipod"]
        case .m4r: args += ["-t", format(MediaFormats.ringtoneMaxSeconds), "-c:a", aacEncoder ?? "aac",
                            "-b:a", "\(min(bitrate, 320))k", "-f", "ipod"]
        case .alac: args += ["-c:a", first(["alac", "alac_at"]) ?? "alac", "-f", "ipod"]
        case .wav: args += ["-c:a", "pcm_s16le"]
        case .aiff: args += ["-c:a", "pcm_s16be"]
        case .caf: args += ["-c:a", "pcm_s16le", "-f", "caf"]
        case .flac: args += ["-c:a", "flac"]
        case .ogg:
            if ffmpeg.hasEncoder("libvorbis") {
                args += ["-c:a", "libvorbis", "-q:a", "6"]
            } else if ffmpeg.hasEncoder("libopus") {
                args += ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"]
            } else {
                args += ["-c:a", "vorbis", "-strict", "-2", "-ac", "2"]
            }
            args += ["-f", "ogg"]
        case .opus:
            args += ffmpeg.hasEncoder("libopus")
                ? ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"]
                : ["-c:a", "opus", "-strict", "-2"]
        case .wma: args += ["-c:a", "wmav2", "-b:a", "\(min(bitrate, 192))k"]
        default: break
        }
        // Opus only supports a few sample rates; ffmpeg picks a valid one automatically.
        if let rate = options.audioSampleRate, to != .opus, !(to == .ogg && !ffmpeg.hasEncoder("libvorbis")) {
            args += ["-ar", "\(rate)"]
        }
        return args + [output.path]
    }

    private func clampedQuality(_ options: ConversionOptions) -> Double {
        min(max(options.videoQuality, 0), 1)
    }

    /// Quality scale for MPEG-4 part 2 encoders: 2 (best) … 31 (worst).
    private func mpeg4Scale(_ options: ConversionOptions) -> Int {
        max(2, min(31, Int((12 - clampedQuality(options) * 10).rounded())))
    }

    private func videoCodecArguments(_ options: ConversionOptions) -> [String] {
        let q = clampedQuality(options)
        let codec: VideoCodec = videoEncoder(options.videoCodec) != nil ? options.videoCodec : .h264
        var args: [String]
        switch videoEncoder(codec) {
        case "h264_videotoolbox": args = ["-c:v", "h264_videotoolbox", "-q:v", "\(Int(35 + q * 45))"]
        case "hevc_videotoolbox": args = ["-c:v", "hevc_videotoolbox", "-q:v", "\(Int(30 + q * 45))"]
        case "libx265": args = ["-c:v", "libx265", "-preset", "medium", "-crf", "\(Int(36 - q * 16))"]
        default: args = ["-c:v", "libx264", "-preset", "medium", "-crf", "\(Int(34 - q * 18))"]
        }
        if codec == .hevc { args += ["-tag:v", "hvc1"] }
        return args + ["-pix_fmt", "yuv420p"]
    }

    /// Keeps dimensions even (required by yuv420p) and caps the short side for presets like 1080p.
    func scaleFilter(_ resolution: VideoResolution) -> String {
        guard let side = resolution.maxHeight else { return "scale=trunc(iw/2)*2:trunc(ih/2)*2" }
        return "scale='if(gte(iw,ih),-2,min(\(side),trunc(iw/2)*2))':'if(gte(iw,ih),min(\(side),trunc(ih/2)*2),-2)'"
    }

    private func format(_ seconds: Double) -> String {
        String(format: "%.0f", seconds)
    }
}

import Foundation
import TangerineCore

/// Which media formats each engine can read and write.
enum MediaFormats {
    /// Containers AVFoundation can open.
    static let avVideoInputs: Set<FileFormat> = [.mp4, .mov, .m4v, .threeGP]
    /// Containers AVAssetExportSession can write.
    static let avVideoOutputs: Set<FileFormat> = [.mp4, .mov, .m4v]
    /// Containers only ffmpeg can open.
    static let ffmpegOnlyVideoInputs: Set<FileFormat> = [.mkv, .webm, .avi, .wmv, .flv, .mpg, .mts]
    static var videoInputs: Set<FileFormat> { avVideoInputs.union(ffmpegOnlyVideoInputs) }

    /// Audio files Core Audio (`afconvert`, AVFoundation) can decode.
    static let nativeAudioInputs: Set<FileFormat> = [.mp3, .m4a, .aac, .wav, .aiff, .flac, .caf, .amr, .m4r]
    /// Audio files only ffmpeg can decode.
    static let ffmpegOnlyAudioInputs: Set<FileFormat> = [.ogg, .opus, .wma]
    static var audioInputs: Set<FileFormat> { nativeAudioInputs.union(ffmpegOnlyAudioInputs) }

    /// Audio targets Core Audio can encode.
    static let nativeAudioOutputs: Set<FileFormat> = [.m4a, .alac, .m4r, .wav, .aiff, .flac, .caf]

    /// Video targets (including GIF) ffmpeg can produce.
    static let ffmpegVideoOutputs: Set<FileFormat> = [.mp4, .mov, .m4v, .mkv, .webm, .avi, .wmv, .gif]
    /// Audio targets ffmpeg can produce.
    static let ffmpegAudioOutputs: Set<FileFormat> = [.mp3, .m4a, .alac, .m4r, .wav, .aiff, .flac, .caf, .ogg, .opus, .wma]

    /// iPhone ringtones must be 40 seconds or shorter.
    static let ringtoneMaxSeconds: Double = 40
    /// Native GIF export stops after this many seconds to keep files reasonable.
    static let gifMaxSeconds: Double = 30

    /// True when the first bytes show a container only ffmpeg reads (Ogg, Matroska/WebM, ASF), whatever the
    /// extension says. Core Audio can accept such a file and write a few milliseconds of noise.
    static func hasFFmpegOnlyContainer(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 4)) ?? Data())
        return [Array("OggS".utf8), [0x1A, 0x45, 0xDF, 0xA3], [0x30, 0x26, 0xB2, 0x75]].contains(head)
    }
}

/// Removes a partially written file, ignoring errors.
func removePartial(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Turns AVFoundation and task-cancellation errors into `ConversionError`s, so users see
/// "Cannot Open: This media may be damaged." rather than just "Cannot Open".
func mediaError(_ error: Error) -> Error {
    switch error {
    case is ConversionError: return error
    case is CancellationError: return ConversionError.cancelled
    default:
        let error = error as NSError
        let description = error.localizedDescription
        guard let reason = error.localizedFailureReason,
              !description.localizedCaseInsensitiveContains(reason.trimmingCharacters(in: .punctuationCharacters)) else {
            return ConversionError.failed(description)
        }
        return ConversionError.failed("\(description): \(reason)")
    }
}

/// Throws when the output is missing or empty, which some encoders produce on silent failure.
func requireOutput(_ url: URL) throws {
    guard url.fileSize > 0 else {
        removePartial(url)
        throw ConversionError.failed("The converter produced an empty file.")
    }
}

import Foundation
import TangerineCore

/// WebP encoding through libwebp's `cwebp`/`gif2webp` (preferred, BSD-licensed and bundleable)
/// or ffmpeg built with libwebp.
public enum WebPTools {
    public static let cwebp = Shell.which("cwebp", extraDirectories: Shell.bundledToolDirectories)
    public static let gif2webp = Shell.which("gif2webp", extraDirectories: Shell.bundledToolDirectories)

    public static var canEncode: Bool { cwebp != nil || FFmpeg.shared.hasEncoder("libwebp") }
    public static var canEncodeAnimation: Bool { gif2webp != nil || FFmpeg.shared.hasEncoder("libwebp") }

    /// Encodes a PNG/JPEG/TIFF still as WebP.
    static func encode(_ input: URL, to output: URL, quality: Double) async throws {
        let q = String(Int((quality * 100).rounded()))
        if let cwebp {
            try await Shell.run(cwebp, ["-quiet", "-q", q, "-alpha_q", "100", "-metadata", "icc", input.path, "-o", output.path])
        } else if FFmpeg.shared.hasEncoder("libwebp") {
            try await FFmpeg.shared.run(["-i", input.path, "-c:v", "libwebp", "-quality", q, "-frames:v", "1", output.path])
        } else {
            throw ConversionError.engineMissing("webp")
        }
    }

    /// Converts an animated GIF to an animated WebP.
    static func encodeAnimatedGIF(_ input: URL, to output: URL, quality: Double) async throws {
        let q = String(Int((quality * 100).rounded()))
        if let gif2webp {
            try await Shell.run(gif2webp, ["-quiet", "-q", q, "-mixed", input.path, "-o", output.path])
        } else if FFmpeg.shared.hasEncoder("libwebp") {
            try await FFmpeg.shared.run(["-i", input.path, "-c:v", "libwebp", "-quality", q, "-loop", "0", output.path])
        } else {
            throw ConversionError.engineMissing("webp")
        }
    }
}

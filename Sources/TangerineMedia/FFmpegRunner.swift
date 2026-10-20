import Foundation
import TangerineCore

/// Runs ffmpeg with `-progress pipe:1` so long video jobs can report progress.
///
/// Core's `Shell` only returns output once the process exits; this runner streams stdout
/// (progress key/value lines) and stderr (to learn the input duration and keep error text).
enum FFmpegRunner {
    /// `durationLimit` caps the expected duration when the arguments trim the input (e.g. `-t 30`).
    static func run(_ ffmpeg: FFmpeg, _ arguments: [String], durationLimit: Double? = nil,
                    progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let path = ffmpeg.path else { throw ConversionError.engineMissing("ffmpeg") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"] + arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let state = State(durationLimit: durationLimit, progress: progress)
        out.fileHandleForReading.readabilityHandler = { state.consumeProgress($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { state.consumeLog($0.availableData) }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    state.consumeLog(err.fileHandleForReading.readDataToEndOfFile())
                    if state.isCancelled {
                        continuation.resume(throwing: ConversionError.cancelled)
                    } else if proc.terminationStatus != 0 {
                        continuation.resume(throwing: ConversionError.failed(state.errorSummary))
                    } else {
                        continuation.resume()
                    }
                }
                do {
                    try process.run()
                    // Cancelled before ffmpeg started: the cancel handler found nothing to stop.
                    if state.isCancelled { process.terminate() }
                } catch {
                    continuation.resume(throwing: ConversionError.failed("Couldn't start ffmpeg: \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            state.cancel()
            if process.isRunning { process.terminate() }
        }
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let progress: @Sendable (Double) -> Void
        private var log = ""
        private var pendingProgress = ""
        private var duration: Double?
        private let durationLimit: Double?
        private var cancelled = false

        init(durationLimit: Double?, progress: @escaping @Sendable (Double) -> Void) {
            self.durationLimit = durationLimit
            self.progress = progress
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        func cancel() { lock.lock(); cancelled = true; lock.unlock() }

        /// A readable reason: known failures get a plain sentence, anything else the last meaningful stderr lines
        /// (where ffmpeg puts the actual error) without log prefixes or file paths.
        var errorSummary: String {
            lock.lock(); defer { lock.unlock() }
            if log.contains("matches no streams") || log.contains("does not contain any stream") {
                // ffmpeg 8 says "Failed to set value '0:a:0' for option 'map'"; older versions "Stream map '0:a:0'".
                let audio = log.range(of: #"(Stream map|Failed to set value) '0:a"#, options: .regularExpression) != nil
                return audio ? "This file has no audio." : "This file has no video."
            }
            if log.contains("Invalid data found when processing input") || log.contains("moov atom not found")
                || log.contains("Error opening input: End of file") {
                return "This file is damaged or isn't a supported media file."
            }
            if log.contains("Permission denied") { return "Permission denied." }
            if log.contains("No space left on device") { return "The disk is full." }
            let redundant = ["Stream #", "Input #", "Output #", "frame=", "size=", "Conversion failed!",
                             "Error opening input file ", "Error opening output file ", "Error parsing options for "]
            let lines = log.split(separator: "\n")
                .map { $0.replacingOccurrences(of: #"^\[[^\]]* @ 0x[0-9a-f]+\] *"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces) }
                .filter { line in !line.isEmpty && !redundant.contains { line.hasPrefix($0) } }
            let tail = lines.suffix(2).joined(separator: " ")
            return "ffmpeg: " + (tail.isEmpty ? "conversion failed" : tail)
        }

        func consumeLog(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            log += String(decoding: data, as: UTF8.self)
            if log.count > 64_000 { log = String(log.suffix(32_000)) }
            if duration == nil, let range = log.range(of: #"Duration: (\d+):(\d+):(\d+(?:\.\d+)?)"#, options: .regularExpression) {
                let parts = log[range].dropFirst("Duration: ".count).split(separator: ":")
                if parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) {
                    let total = h * 3600 + m * 60 + s
                    duration = durationLimit.map { min($0, total) } ?? total
                }
            }
        }

        func consumeProgress(_ data: Data) {
            guard !data.isEmpty else { return }
            lock.lock()
            pendingProgress += String(decoding: data, as: UTF8.self)
            var fraction: Double?
            while let newline = pendingProgress.firstIndex(of: "\n") {
                let line = pendingProgress[..<newline]
                pendingProgress.removeSubrange(...newline)
                if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)),
                   let duration, duration > 0 {
                    fraction = min(max(micros / 1_000_000 / duration, 0), 1)
                } else if line == "progress=end" {
                    fraction = 1
                }
            }
            lock.unlock()
            if let fraction { progress(fraction) }
        }
    }
}

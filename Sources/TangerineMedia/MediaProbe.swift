import AVFoundation
import Foundation
import TangerineCore

/// Whether a media file has picture, sound, or both.
public struct MediaStreams: Equatable, Sendable {
    public var video: Bool
    public var audio: Bool

    public init(video: Bool, audio: Bool) {
        self.video = video
        self.audio = audio
    }
}

/// Reads which streams a file holds, so the wheel and the Converter only offer targets it can produce:
/// no MP3 for a clip without sound, no GIF for an MP4 that only holds music.
public enum MediaProbe {
    /// The file's streams, or nil when they can't be read (the conversion then reports what's wrong).
    /// Takes a few milliseconds; results are cached per file version.
    public static func streams(of url: URL) -> MediaStreams? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.standardizedFileURL.path)|\(values?.fileSize ?? -1)|"
            + "\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        lock.lock()
        let cached = cache[key]
        lock.unlock()
        if let cached { return cached }
        let streams = read(url)
        lock.lock()
        if cache.count > 2000 { cache.removeAll() }
        cache[key] = .some(streams)
        lock.unlock()
        return streams
    }

    /// `streams(of:)` for several files at once, read in parallel.
    public static func streams(of urls: [URL]) -> [MediaStreams?] {
        var results = [MediaStreams?](repeating: nil, count: urls.count)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: urls.count) { index in
                buffer[index] = streams(of: urls[index])
            }
        }
        return results
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: MediaStreams?] = [:]
    /// A probe that hasn't answered by then is treated as unknown.
    static let timeout: TimeInterval = 2

    private static func read(_ url: URL) -> MediaStreams? {
        guard let format = FileFormat.detect(url) else { return nil }
        let native = MediaFormats.avVideoInputs.contains(format) || MediaFormats.nativeAudioInputs.contains(format)
        let streams = native && !MediaFormats.hasFFmpegOnlyContainer(url) ? readWithAVFoundation(url) : readWithFFmpeg(url)
        // Nothing playable at all: leave the targets alone so the conversion explains the problem.
        guard let streams, streams.video || streams.audio else { return nil }
        return streams
    }

    private static func readWithAVFoundation(_ url: URL) -> MediaStreams? {
        final class Found: @unchecked Sendable {
            let lock = NSLock()
            var counts: [AVMediaType: Int] = [:]
        }
        let asset = AVURLAsset(url: url)
        let found = Found()
        let group = DispatchGroup()
        for type in [AVMediaType.video, .audio] {
            group.enter()
            asset.loadTracks(withMediaType: type) { tracks, _ in
                if let tracks {
                    found.lock.lock()
                    found.counts[type] = tracks.count
                    found.lock.unlock()
                }
                group.leave()
            }
        }
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        found.lock.lock()
        defer { found.lock.unlock() }
        guard let video = found.counts[.video], let audio = found.counts[.audio] else { return nil }
        return MediaStreams(video: video > 0, audio: audio > 0)
    }

    private static func readWithFFmpeg(_ url: URL) -> MediaStreams? {
        guard let path = FFmpeg.shared.path else { return nil }
        // With only an input, ffmpeg prints the stream list and stops ("At least one output file must be specified").
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-nostdin", "-i", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        // Not waitUntilExit(): it spins the run loop and can add tens of milliseconds per file.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let log = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        exited.wait()
        watchdog.cancel()

        let lines = log.split(separator: "\n").filter { $0.contains("Stream #") }
        guard !lines.isEmpty else { return nil }
        // Cover art shows up as a video stream marked "(attached pic)".
        return MediaStreams(video: lines.contains { $0.contains(": Video:") && !$0.contains("(attached pic)") },
                            audio: lines.contains { $0.contains(": Audio:") })
    }
}

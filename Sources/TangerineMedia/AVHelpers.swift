import AVFoundation
import Foundation
import ImageIO
import TangerineCore
import UniformTypeIdentifiers

/// AVFoundation building blocks shared by the native video and audio backends.
enum AVHelpers {
    static func fileType(for format: FileFormat) -> AVFileType? {
        switch format {
        case .mp4: .mp4
        case .mov: .mov
        case .m4v: .m4v
        case .m4a, .m4r, .alac: .m4a
        case .wav: .wav
        case .aiff: .aiff
        case .caf: .caf
        default: nil
        }
    }

    /// Exports `asset` with an AVAssetExportSession preset, reporting progress and honoring cancellation.
    static func export(_ asset: AVAsset, preset: String, to url: URL, fileType: AVFileType,
                       timeRange: CMTimeRange? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        // Damaged files fail here with "This media may be damaged" instead of an export error code.
        _ = try await asset.load(.tracks)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.failed("This file can't be exported with \(preset).")
        }
        guard session.supportedFileTypes.contains(fileType) else {
            throw ConversionError.failed("\(preset) can't write \(fileType.rawValue).")
        }
        session.outputURL = url
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }

        let box = SessionBox(session)
        let poll = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { poll.cancel() }

        let started = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if !box.start({ continuation.resume(returning: true) }) { continuation.resume(returning: false) }
            }
        } onCancel: {
            box.cancel()
        }
        guard started else { throw ConversionError.cancelled }

        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            removePartial(url)
            throw ConversionError.cancelled
        default:
            removePartial(url)
            throw session.error.map(mediaError) ?? ConversionError.failed("Export failed.")
        }
    }

    /// Decodes every audio track (mixed down to at most stereo) into an uncompressed WAV, AIFF or CAF file.
    static func writePCM(from asset: AVAsset, to url: URL, fileType: AVFileType, bitDepth: Int = 16,
                         sampleRate: Int? = nil, maxDuration: Double? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let first = tracks.first else { throw ConversionError.failed("This file has no audio.") }
        let descriptions = try await first.load(.formatDescriptions)
        let basic = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = sampleRate ?? Int(basic?.mSampleRate ?? 44_100)
        let channels = min(max(Int(basic?.mChannelsPerFrame ?? 2), 1), 2)
        let duration = try await asset.load(.duration).seconds

        // The reader decodes to native little-endian PCM; the writer converts when the container needs
        // big-endian samples (AIFF).
        let readerSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        var writerSettings = readerSettings
        writerSettings[AVLinearPCMIsBigEndianKey] = fileType == .aiff

        let reader = try AVAssetReader(asset: asset)
        if let maxDuration, duration > maxDuration {
            reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: maxDuration, preferredTimescale: 600))
        }
        let readerOutput = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readerSettings)
        guard reader.canAdd(readerOutput) else { throw ConversionError.failed("Couldn't decode the audio.") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: writerSettings)
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else { throw ConversionError.failed("Couldn't write \(fileType.rawValue).") }
        writer.add(writerInput)

        guard reader.startReading() else {
            throw ConversionError.failed(reader.error?.localizedDescription ?? "Couldn't read the audio.")
        }
        guard writer.startWriting() else {
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Couldn't write the audio.")
        }
        writer.startSession(atSourceTime: .zero)

        let total = min(duration, maxDuration ?? duration)
        let pump = Pump(reader: reader, output: readerOutput, input: writerInput, total: total, progress: progress)
        let ok = await withTaskCancellationHandler {
            await pump.run()
        } onCancel: {
            pump.cancel()
        }

        if !ok || Task.isCancelled {
            writer.cancelWriting()
            removePartial(url)
            if Task.isCancelled { throw ConversionError.cancelled }
            throw ConversionError.failed(reader.error?.localizedDescription ?? writer.error?.localizedDescription
                ?? "Audio conversion failed.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            removePartial(url)
            throw ConversionError.failed(writer.error?.localizedDescription ?? "Audio conversion failed.")
        }
        progress(1)
    }

    /// Native GIF fallback when ffmpeg is missing: samples frames with AVAssetImageGenerator.
    static func writeGIF(from asset: AVAsset, to url: URL, fps: Int, width: Int,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw ConversionError.failed("This file has no video.")
        }
        let duration = min(try await asset.load(.duration).seconds, MediaFormats.gifMaxSeconds)
        guard duration > 0 else { throw ConversionError.failed("This video has no frames.") }
        let fps = max(1, min(fps, 30))
        let frameCount = max(1, Int(duration * Double(fps)))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: max(16, width), height: max(16, width) * 4)
        let tolerance = CMTime(seconds: 0.5 / Double(fps), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                                frameCount, nil) else {
            throw ConversionError.failed("Couldn't create the GIF.")
        }
        let fileProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary
        CGImageDestinationSetProperties(destination, fileProperties)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / Double(fps)]] as CFDictionary

        do {
            for index in 0..<frameCount {
                if Task.isCancelled { throw ConversionError.cancelled }
                let time = CMTime(seconds: Double(index) / Double(fps), preferredTimescale: 600)
                let image = try await generator.image(at: time).image
                CGImageDestinationAddImage(destination, image, frameProperties)
                progress(Double(index + 1) / Double(frameCount))
            }
        } catch {
            removePartial(url)
            throw mediaError(error)
        }
        guard CGImageDestinationFinalize(destination) else {
            removePartial(url)
            throw ConversionError.failed("Couldn't write the GIF.")
        }
    }

    /// Lets the non-Sendable session cross into the cancellation handler and polling task.
    ///
    /// Also orders start and cancel: calling `exportAsynchronously` after `cancelExport` raises an
    /// Objective-C exception (crashing the app), which happens when a job is cancelled just before its export starts.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        init(_ session: AVAssetExportSession) { self.session = session }

        /// Starts the export unless it was already cancelled; returns whether it started.
        func start(_ completion: @escaping @Sendable () -> Void) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { return false }
            started = true
            session.exportAsynchronously(completionHandler: completion)
            return true
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if started { session.cancelExport() }
        }
    }

    /// Moves sample buffers from a reader to a writer on a background queue.
    private final class Pump: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderOutput
        private let input: AVAssetWriterInput
        private let total: Double
        private let progress: @Sendable (Double) -> Void
        private let queue = DispatchQueue(label: "tangerine.media.pcm")
        private let lock = NSLock()
        private var cancelled = false

        init(reader: AVAssetReader, output: AVAssetReaderOutput, input: AVAssetWriterInput, total: Double,
             progress: @escaping @Sendable (Double) -> Void) {
            self.reader = reader
            self.output = output
            self.input = input
            self.total = total
            self.progress = progress
        }

        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
        }

        private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

        /// Returns false when reading or appending failed or the job was cancelled.
        func run() async -> Bool {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                var finished = false
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    guard !finished else { return }
                    while input.isReadyForMoreMediaData {
                        if isCancelled {
                            finished = true
                            reader.cancelReading()
                            input.markAsFinished()
                            continuation.resume(returning: false)
                            return
                        }
                        guard let buffer = output.copyNextSampleBuffer() else {
                            finished = true
                            input.markAsFinished()
                            continuation.resume(returning: reader.status == .completed)
                            return
                        }
                        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        if total > 0, time.isFinite { progress(min(time / total, 1)) }
                        if !input.append(buffer) {
                            finished = true
                            reader.cancelReading()
                            continuation.resume(returning: false)
                            return
                        }
                    }
                }
            }
        }
    }
}

import Foundation

/// Runs command-line tools (afconvert, ffmpeg) without blocking threads, with cancellation support.
public enum Shell {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Runs `executable` and throws `ConversionError.failed` with stderr when it exits non-zero.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) async throws -> Result {
        let result = try await execute(executable, arguments)
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            throw ConversionError.failed(detail.isEmpty ? "\(name) failed (\(result.status))." : "\(name): \(detail)")
        }
        return result
    }

    /// Runs `executable` and returns its exit status and output without throwing on failure.
    public static func execute(_ executable: String, _ arguments: [String]) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let outBuffer = Buffer(), errBuffer = Buffer(), cancelled = Flag()
        out.fileHandleForReading.readabilityHandler = { outBuffer.append($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { errBuffer.append($0.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { proc in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    outBuffer.append(out.fileHandleForReading.readDataToEndOfFile())
                    errBuffer.append(err.fileHandleForReading.readDataToEndOfFile())
                    if cancelled.isSet {
                        continuation.resume(throwing: ConversionError.cancelled)
                        return
                    }
                    continuation.resume(returning: Result(status: proc.terminationStatus,
                                                          stdout: outBuffer.string, stderr: errBuffer.string))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ConversionError.failed("Couldn't start \(executable): \(error.localizedDescription)"))
                }
            }
        } onCancel: {
            cancelled.set()
            if process.isRunning { process.terminate() }
        }
    }

    /// Finds an executable in common install locations and `$PATH`.
    public static func which(_ name: String, extraDirectories: [String] = []) -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let candidates = extraDirectories + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + pathDirs
        for dir in candidates {
            let path = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private final class Flag: @unchecked Sendable {
        private var value = false
        private let lock = NSLock()

        func set() { lock.lock(); value = true; lock.unlock() }

        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class Buffer: @unchecked Sendable {
        private var data = Data()
        private let lock = NSLock()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); data.append(chunk); lock.unlock()
        }

        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

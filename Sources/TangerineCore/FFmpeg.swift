import Foundation

/// Locates ffmpeg (bundled in the app, Homebrew, or $PATH) and reports which encoders it has.
public final class FFmpeg: @unchecked Sendable {
    public static let shared = FFmpeg()

    /// Absolute path to the ffmpeg binary, or nil when it isn't installed.
    public let path: String?
    private let lock = NSLock()
    private var cachedEncoders: Set<String>?

    public init(path: String? = FFmpeg.locate()) {
        self.path = path
    }

    public var isAvailable: Bool { path != nil }

    /// Bundled copy first (`Contents/Resources/ffmpeg` or `Contents/MacOS/ffmpeg`), then system installs.
    public static func locate() -> String? {
        var bundled: [String] = []
        if let resources = Bundle.main.resourceURL?.path { bundled.append(resources) }
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent().path { bundled.append(executableDir) }
        if let override = ProcessInfo.processInfo.environment["TANGERINE_FFMPEG"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        return Shell.which("ffmpeg", extraDirectories: bundled)
    }

    /// Encoder names reported by `ffmpeg -encoders` (e.g. "libmp3lame", "libwebp").
    public var encoders: Set<String> {
        lock.lock(); defer { lock.unlock() }
        if let cachedEncoders { return cachedEncoders }
        let list = path.map(Self.readEncoders) ?? []
        cachedEncoders = list
        return list
    }

    public func hasEncoder(_ name: String) -> Bool { encoders.contains(name) }

    /// Runs ffmpeg with quiet, non-interactive defaults; `arguments` should include `-i` and the output.
    public func run(_ arguments: [String]) async throws {
        guard let path else { throw ConversionError.engineMissing("ffmpeg") }
        try await Shell.run(path, ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + arguments)
    }

    private static func readEncoders(at path: String) -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // Lines look like: " V....D libx264              libx264 H.264 / AVC ..."
        var names = Set<String>()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0].count == 6, parts[0] != "------" else { continue }
            names.insert(String(parts[1]))
        }
        return names
    }
}

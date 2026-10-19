import Foundation

// MARK: - Options

public enum VideoResolution: String, CaseIterable, Sendable, Codable {
    case original, p2160, p1080, p720, p480

    public var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "4K"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    /// Maximum height in pixels, or nil to keep the source size.
    public var maxHeight: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
}

public enum VideoCodec: String, CaseIterable, Sendable, Codable {
    case h264, hevc

    public var title: String { self == .h264 ? "H.264" : "HEVC" }
}

/// User-tunable settings shared by every engine. Defaults are what the wheel uses.
public struct ConversionOptions: Sendable, Codable, Equatable {
    /// Lossy image quality, 0...1.
    public var imageQuality: Double = 0.85
    /// Longest edge in pixels for image output, or nil to keep the original size.
    public var imageMaxPixelSize: Int? = nil
    /// Drop EXIF, GPS and other metadata from images.
    public var stripImageMetadata: Bool = false
    /// Background used when flattening transparency (e.g. PNG → JPG), as sRGB 0...1.
    public var flattenBackground: SolidColor = .white

    public var videoResolution: VideoResolution = .original
    public var videoCodec: VideoCodec = .h264
    /// Video quality, 0...1 (higher is better and larger).
    public var videoQuality: Double = 0.65
    public var gifFPS: Int = 12
    public var gifWidth: Int = 480

    public var audioBitrateKbps: Int = 256
    /// Output sample rate in Hz, or nil to keep the source rate.
    public var audioSampleRate: Int? = nil

    /// Resolution for rendering PDF pages to images.
    public var pdfDPI: Int = 300

    public init() {}
}

public struct SolidColor: Sendable, Codable, Equatable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let white = SolidColor(red: 1, green: 1, blue: 1)
    public static let black = SolidColor(red: 0, green: 0, blue: 0)
}

// MARK: - Context and results

public struct ConversionContext: Sendable {
    public var options: ConversionOptions
    /// Reports progress for the current file, 0...1. May be called from any thread.
    public var progress: @Sendable (Double) -> Void

    public init(options: ConversionOptions = ConversionOptions(), progress: @escaping @Sendable (Double) -> Void = { _ in }) {
        self.options = options
        self.progress = progress
    }
}

public struct ToolOutput: Sendable {
    /// Files or folders written.
    public var files: [URL]
    /// Text produced by text tools (e.g. OCR).
    public var text: String?
    /// Short human-readable note such as "Already optimized".
    public var note: String?

    public init(files: [URL] = [], text: String? = nil, note: String? = nil) {
        self.files = files
        self.text = text
        self.note = note
    }
}

// MARK: - Backend protocols

/// Converts single files between formats. Implementations must be safe to call concurrently.
public protocol ConversionBackend: Sendable {
    /// Stable identifier used in logs and tests.
    var id: String { get }
    func supports(from: FileFormat, to: FileFormat) -> Bool
    /// Converts `input` and returns every file or folder written (normally one file).
    func convert(_ input: URL, from: FileFormat, to: FileFormat, output: OutputPlan,
                 context: ConversionContext) async throws -> [URL]
}

/// Runs one-shot tools (compress, rotate, merge…).
public protocol ToolBackend: Sendable {
    var id: String { get }
    func supports(_ tool: ToolID, format: FileFormat) -> Bool
    /// `inputs` holds one file unless `tool.combinesInputs` is true.
    func run(_ tool: ToolID, inputs: [URL], output: OutputPlan, context: ConversionContext) async throws -> ToolOutput
}

// MARK: - Errors

public enum ConversionError: LocalizedError, Sendable {
    case unsupported(from: FileFormat?, to: String)
    case unreadable(URL)
    case engineMissing(String)
    case failed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unsupported(from, to):
            "Can't convert \(from?.displayName ?? "this file") to \(to)."
        case let .unreadable(url):
            "Couldn't read “\(url.lastPathComponent)”."
        case let .engineMissing(name):
            "\(name) is required for this conversion. Install it with “brew install \(name)”."
        case let .failed(message):
            message
        case .cancelled:
            "Cancelled."
        }
    }
}

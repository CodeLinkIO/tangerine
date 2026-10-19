import Foundation
import TangerineKit

/// `tangerine` — command-line front end for the conversion engine.
@main
struct CLI {
    static let usage = """
    Usage:
      tangerine convert <files…> --to <format> [options]
      tangerine tool <tool> <files…> [--out DIR]
      tangerine formats <files…>        List conversions and tools for the files
      tangerine engines                 Show which engines are available

    Options:
      --out DIR              Write results to DIR (default: next to each file)
      --quality 0-100        Image quality for lossy formats (default 85)
      --max-size PX          Limit the longest image edge
      --strip-metadata       Remove EXIF/GPS from images
      --resolution R         Video: original, 2160p, 1080p, 720p, 480p
      --codec C              Video: h264, hevc
      --bitrate KBPS         Audio bitrate (default 256)
      --dpi N                PDF page rendering resolution (default 300)

    Tools: \(ToolID.allCases.filter { !$0.isInteractive }.map(\.rawValue).joined(separator: ", "))
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else { exit(fail(usage)) }
        args.removeFirst()
        do {
            switch command {
            case "convert": try await convert(args)
            case "tool": try await tool(args)
            case "formats": formats(args)
            case "engines": engines()
            case "-h", "--help", "help": print(usage)
            default: exit(fail("Unknown command “\(command)”.\n\n\(usage)"))
            }
        } catch {
            exit(fail(error.localizedDescription))
        }
    }

    // MARK: Commands

    static func convert(_ args: [String]) async throws {
        var parsed = try Arguments(args)
        guard let targetName = parsed.value("--to") else { throw ConversionError.failed("Missing --to <format>.") }
        guard let target = FileFormat.parse(targetName) else { throw ConversionError.failed("Unknown format “\(targetName)”.") }
        let options = try parsed.conversionOptions()
        let files = try parsed.files()
        let report = try await Engine.shared.convert(files, to: target, options: options, outputDirectory: parsed.outputDirectory,
                                                     progress: progressPrinter())
        printReport(report)
    }

    static func tool(_ args: [String]) async throws {
        var parsed = try Arguments(args)
        guard let name = parsed.positional.first, let tool = ToolID(rawValue: name) else {
            throw ConversionError.failed("Unknown tool. Tools: \(ToolID.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        parsed.positional.removeFirst()
        let options = try parsed.conversionOptions()
        let report = try await Engine.shared.run(tool, on: try parsed.files(), options: options,
                                                 outputDirectory: parsed.outputDirectory, progress: progressPrinter())
        printReport(report)
        if let text = report.text { print(text) }
    }

    static func formats(_ args: [String]) {
        let files = args.map { URL(fileURLWithPath: $0) }
        let engine = Engine.shared
        let targets = engine.targets(for: files)
        print("Convert to: \(targets.isEmpty ? "—" : targets.map(\.displayName).joined(separator: ", "))")
        let tools = engine.tools(for: files)
        print("Tools:      \(tools.isEmpty ? "—" : tools.map { "\($0.title) (\($0.rawValue))" }.joined(separator: ", "))")
    }

    static func engines() {
        let ffmpeg = FFmpeg.shared
        print("ffmpeg:   \(ffmpeg.path ?? "not found — brew install ffmpeg")")
        if ffmpeg.isAvailable {
            let interesting = ["h264_videotoolbox", "hevc_videotoolbox", "libx264", "libvpx-vp9", "libmp3lame", "libopus",
                               "libvorbis", "vorbis", "wmav2", "libwebp"]
            print("          encoders: \(interesting.map { "\($0) \(ffmpeg.hasEncoder($0) ? "✓" : "✗")" }.joined(separator: ", "))")
        }
        print("cwebp:    \(WebPTools.cwebp ?? "not found — brew install webp")")
        print("gif2webp: \(WebPTools.gif2webp ?? "not found — brew install webp")")
        print("Images:   writes \(ImageCodec.writableFormats.map(\.displayName).sorted().joined(separator: ", "))")
        print("Background removal: \(RecipeRenderer.canRemoveBackground ? "available" : "needs macOS 14")")
        let total = FileFormat.allCases.reduce(0) { $0 + Engine.shared.targets(from: $1).count }
        print("Conversion options: \(total)")
    }

    // MARK: Output

    static func progressPrinter() -> @Sendable (JobProgress) -> Void {
        let isTTY = isatty(STDERR_FILENO) == 1
        return { progress in
            guard isTTY else { return }
            let percent = Int(progress.fraction * 100)
            let name = progress.currentFile?.lastPathComponent ?? ""
            FileHandle.standardError.write("\r\u{1B}[K\(percent)% \(name)".data(using: .utf8)!)
        }
    }

    static func printReport(_ report: JobReport) {
        if isatty(STDERR_FILENO) == 1 { FileHandle.standardError.write("\r\u{1B}[K".data(using: .utf8)!) }
        for output in report.outputs { print(output.path) }
        for note in report.notes { print("note: \(note)") }
        for failure in report.failures {
            FileHandle.standardError.write("error: \(failure.file.lastPathComponent): \(failure.message)\n".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\(report.summary)\n".data(using: .utf8)!)
        if !report.failures.isEmpty { exit(1) }
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
        return 1
    }
}

extension FileFormat {
    /// Accepts extensions and display names ("jpeg", "JPG", "m4a", "alac", "markdown").
    static func parse(_ name: String) -> FileFormat? {
        let lower = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let format = FileFormat(rawValue: lower) { return format }
        if let format = FileFormat.allCases.first(where: { $0.displayName.lowercased() == lower }) { return format }
        return FileFormat.detect(URL(fileURLWithPath: "x.\(lower)"))
    }
}

/// Minimal flag parser: `--flag value`, `--switch`, and positional arguments.
struct Arguments {
    var positional: [String] = []
    private var values: [String: String] = [:]
    private var switches: Set<String> = []
    private static let valueFlags: Set<String> = ["--to", "--out", "--quality", "--max-size", "--resolution", "--codec",
                                                  "--bitrate", "--dpi"]

    init(_ args: [String]) throws {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if Self.valueFlags.contains(arg) {
                guard let value = iterator.next() else { throw ConversionError.failed("\(arg) needs a value.") }
                values[arg] = value
            } else if arg.hasPrefix("--") {
                switches.insert(arg)
            } else {
                positional.append(arg)
            }
        }
    }

    func value(_ flag: String) -> String? { values[flag] }

    var outputDirectory: URL? {
        values["--out"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }

    func files() throws -> [URL] {
        guard !positional.isEmpty else { throw ConversionError.failed("No input files.") }
        return try positional.map { path in
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ConversionError.failed("No such file: \(path)") }
            return url
        }
    }

    mutating func conversionOptions() throws -> ConversionOptions {
        var options = ConversionOptions()
        if let quality = values["--quality"] {
            guard let q = Double(quality), (1...100).contains(q) else { throw ConversionError.failed("--quality must be 1–100.") }
            options.imageQuality = q / 100
        }
        if let size = values["--max-size"] {
            guard let px = Int(size), px > 0 else { throw ConversionError.failed("--max-size must be a positive number.") }
            options.imageMaxPixelSize = px
        }
        if switches.contains("--strip-metadata") { options.stripImageMetadata = true }
        if let resolution = values["--resolution"] {
            let key = resolution.lowercased()
            guard let value = VideoResolution.allCases.first(where: { $0.rawValue == key || $0.rawValue == "p" + key.dropLast() || $0.title.lowercased() == key })
            else { throw ConversionError.failed("--resolution must be original, 2160p, 1080p, 720p or 480p.") }
            options.videoResolution = value
        }
        if let codec = values["--codec"] {
            guard let value = VideoCodec(rawValue: codec.lowercased()) else { throw ConversionError.failed("--codec must be h264 or hevc.") }
            options.videoCodec = value
        }
        if let bitrate = values["--bitrate"] {
            guard let kbps = Int(bitrate), kbps > 0 else { throw ConversionError.failed("--bitrate must be a positive number.") }
            options.audioBitrateKbps = kbps
        }
        if let dpi = values["--dpi"] {
            guard let n = Int(dpi), (36...1200).contains(n) else { throw ConversionError.failed("--dpi must be 36–1200.") }
            options.pdfDPI = n
        }
        if let out = outputDirectory {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        }
        return options
    }
}

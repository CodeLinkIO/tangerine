import Foundation

/// Decides where results are written and never overwrites existing files.
public struct OutputPlan: Sendable {
    public let directory: URL
    public let baseName: String

    public init(directory: URL, baseName: String) {
        self.directory = directory
        self.baseName = baseName
    }

    /// Plan for writing next to `input`, or into `directory` when given.
    public init(for input: URL, directory: URL? = nil) {
        self.directory = directory ?? input.deletingLastPathComponent()
        self.baseName = FileFormat.baseName(of: input)
    }

    /// A free file URL: `<base>[ <suffix>].<ext>`, adding " 2", " 3"… when taken.
    public func file(extension ext: String, suffix: String? = nil) -> URL {
        let name = suffix.map { "\(baseName) \($0)" } ?? baseName
        return Self.unique(directory.appendingPathComponent(name).appendingPathExtension(ext))
    }

    /// Creates and returns a free folder: `<base>[ <suffix>]`.
    public func makeFolder(suffix: String? = nil) throws -> URL {
        let name = suffix.map { "\(baseName) \($0)" } ?? baseName
        let url = Self.unique(directory.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Returns `url` if nothing exists there, otherwise the first free "name N.ext" variant.
    public static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(stem) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}

/// Scratch directory that is removed when the value is released.
public final class TemporaryDirectory: @unchecked Sendable {
    public let url: URL

    public init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tangerine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func file(_ name: String) -> URL { url.appendingPathComponent(name) }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public extension URL {
    /// File size in bytes, or 0 when unknown. Folders report the sum of their contents.
    var fileSize: Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return 0 }
        if !isDirectory.boolValue {
            return Int64((try? resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        var total: Int64 = 0
        let enumerator = fm.enumerator(at: self, includingPropertiesForKeys: [.fileSizeKey])
        while let item = enumerator?.nextObject() as? URL {
            total += Int64((try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
